local ipairs = ipairs
local math = math
local next = next
local pairs = pairs
local table = table
local type = type

local cache_format = require("tlcli.cache_format")
local compiler_artifacts =
   require("teal.internal.compiler_artifacts")
local lfs = require("lfs")
local storage = require("tlcli.project_cache.storage")
local types = require("teal.types")

local type teal = require("teal.init")
local type environment = require("teal.environment")
local type errors = require("teal.errors")
local type variables = require("teal.variables")
local type incremental_contract =
   require("teal.internal.incremental_contract")
local type Compiler = teal.Compiler
local type Env = environment.Env
local type Result = environment.Result
local type Error = errors.Error
local type Variable = variables.Variable
local type Session = incremental_contract.Session
local type Cache = storage.Cache
local type Root = storage.Root
local type ProjectEntry = storage.ProjectEntry

local record SnapshotMember
   global_after: {string:(Variable | boolean)}
   result: Result
end

local record Snapshot
   snapshot_version: integer
   loaded_order: {string}
   module_names: {string:{string}}
   options_key: string
   resolution_text: string
   results: {string:SnapshotMember}
   roots: {Root}
   typeid_ctr: integer
   typeid_namespace: string
   typevar_ctr: integer
end

local record SnapshotCache
   put: function(Cache, Compiler, {Root}): boolean
   restore: function(Cache, Compiler, {Root}): boolean
end

local snapshot_cache = {} as SnapshotCache

local SNAPSHOT_VERSION = 4
local MAX_RESTORE_BYTES = 1024 * 1024
local MIN_REBUILD_INVALIDATED = 20
local REBUILD_INVALIDATION_RATIO = 0.25

local function project_affected_count(
   project: ProjectEntry,
   changed: {string:boolean},
   env: Env,
   session: Session
): integer, integer
   if type(project.dependencies) ~= "table" then
      return
   end

   local reverse_dependencies: {string:{string:boolean}} = {}
   for dependent, dependencies in pairs(
      project.dependencies
   ) do
      if type(dependent) ~= "string"
         or type(dependencies) ~= "table"
      then
         return
      end
      for module_name, expected_filename in pairs(
         dependencies
      ) do
         if type(module_name) ~= "string"
            or type(expected_filename) ~= "string"
         then
            return
         end
         local dependents =
            reverse_dependencies[expected_filename]
         if not dependents then
            dependents = {}
            reverse_dependencies[expected_filename] =
               dependents
         end
         dependents[dependent] = true

         local found, dependency_source =
            env.resolve_module(env, module_name)
         if found then
            found = session:normalize_filename(found)
         end
         if found ~= expected_filename
            or not dependency_source
         then
            changed[dependent] = true
            changed[expected_filename] = true
         end
      end
   end

   local affected = storage.copy_map(changed)
      as {string:boolean}
   local queue = storage.sorted_keys(changed)
   local scan = 1
   while scan <= #queue do
      local filename = queue[scan]
      for dependent in pairs(
         reverse_dependencies[filename] or {}
      ) do
         if not affected[dependent] then
            affected[dependent] = true
            queue[#queue + 1] = dependent
         end
      end
      scan = scan + 1
   end

   local loaded_count = 0
   for _ in pairs(project.source_ids) do
      loaded_count = loaded_count + 1
   end
   local affected_count = 0
   local changed_global = false
   for filename in pairs(affected) do
      if project.source_ids[filename] then
         affected_count = affected_count + 1
         if type(project.global_files) == "table"
            and project.global_files[filename]
         then
            changed_global = true
         end
      end
   end
   if changed_global then
      affected_count = loaded_count
   end
   return affected_count, loaded_count
end

local function project_object_id(
   options_key: string,
   roots: {Root},
   source_ids: {string:string},
   loaded_order: {string}
): string
   local parts: {string | number} = {
      "project",
      SNAPSHOT_VERSION,
      cache_format.runtime_fingerprint,
      options_key,
   }
   for _, root in ipairs(roots) do
      parts[#parts + 1] = root.filename
      parts[#parts + 1] = root.module_name or ""
   end
   for _, filename in ipairs(loaded_order) do
      parts[#parts + 1] = filename
      parts[#parts + 1] = source_ids[filename]
   end
   return storage.digest(table.concat(parts, "\0"))
end

function snapshot_cache.put(
   cache: Cache,
   compiler: Compiler,
   roots: {Root}
): boolean
   if not cache.enabled
      or (cache.mode ~= "check" and cache.mode ~= "gen")
      or cache.project_snapshot_enabled == false
      or cache.project_restored
      or #roots == 0
      or next(cache.environment_sources) ~= nil
   then
      return false
   end
   for _, root in ipairs(roots) do
      if root.filename == "-" then
         return false
      end
   end

   local env = compiler_artifacts.environment(compiler)
   local session = env and env.session
   if not session or env.report_types then
      return false
   end

   local loaded_order = storage.copy_array(env.loaded_order)
      as {string}
   local dependencies: {string:{string:string}} = {}
   local global_files: {string:boolean} = {}
   local source_ids: {string:string} = {}
   local results: {string:SnapshotMember} = {}
   for _, filename in ipairs(loaded_order) do
      local result = env.loaded[filename]
      local source = session.source_inputs[filename]
         or storage.read_file(filename)
      if type(result) ~= "table"
         or type(result.type) ~= "table"
         or not source
      then
         return false
      end
      dependencies[filename] =
         storage.copy_map(result.dependencies)
            as {string:string}
      if next(result.global_previous or {}) then
         global_files[filename] = true
      end
      source_ids[filename] =
         cache:_source_id(filename, source)
      local previous_names: {string:(Variable | boolean)} = {}
      for name in pairs(result.global_previous or {}) do
         previous_names[name] = false
      end
      results[filename] = {
         global_after = {},
         result = {
            ast = {
               f = result.filename,
               kind = "statements",
               x = 1,
               xend = 1,
               y = 1,
               yend = 1,
            },
            compat_applied = result.compat_applied,
            dependencies =
               storage.copy_map(result.dependencies)
                  as {string:string},
            filename = result.filename,
            gen_error = result.gen_error,
            global_previous = previous_names,
            needs_compat =
               storage.copy_map(result.needs_compat)
                  as {string:boolean},
            syntax_errors =
               storage.copy_array(result.syntax_errors)
                  as {Error},
            type = result.type,
            type_errors =
               storage.copy_array(result.type_errors)
                  as {Error},
            warnings = storage.copy_array(result.warnings)
               as {Error},
         },
      }
   end

   local current_globals = storage.copy_map(env.globals)
      as {string:Variable}
   for i = #loaded_order, 1, -1 do
      local filename = loaded_order[i]
      local source_result = env.loaded[filename]
      local member = results[filename]
      for name, previous in pairs(
         source_result.global_previous or {}
      ) do
         member.global_after[name] =
            current_globals[name] or false
         if previous == false then
            current_globals[name] = nil
         else
            current_globals[name] = previous as Variable
         end
      end
   end

   local module_names: {string:{string}} = {}
   for module_name, filename in pairs(env.module_filenames) do
      if results[filename] then
         local names = module_names[filename]
         if not names then
            names = {}
            module_names[filename] = names
         end
         names[#names + 1] = module_name
      end
   end
   for _, names in pairs(module_names) do
      table.sort(names)
   end

   local object_id = project_object_id(
      cache.options_key,
      roots,
      source_ids,
      loaded_order
   )
   local typeid_ctr, typevar_ctr = types.internal_get_state()
   local snapshot = {
      snapshot_version = SNAPSHOT_VERSION,
      loaded_order = loaded_order,
      module_names = module_names,
      options_key = cache.options_key,
      resolution_text = cache.resolution_text,
      results = results,
      roots = storage.copy_array(roots) as {Root},
      typeid_ctr = typeid_ctr,
      typeid_namespace = cache.typeid_namespace,
      typevar_ctr = typevar_ctr,
   }
   local bytes, encode_err =
      cache_format.encode_compiler_graph(
         snapshot as {any:any}
      )
   if not bytes then
      cache.last_error = encode_err
      return false
   end

   local object_path = storage.object_path(cache, object_id)
   if not storage.file_exists(object_path) then
      local object_directory =
         object_path:match("^(.*)[/\\][^/\\]+$")
      local ok, directory_err =
         storage.ensure_directory(object_directory)
      if not ok then
         cache.last_error = directory_err
         return false
      end
      local write_ok, write_err =
         storage.atomic_write(object_path, bytes)
      if not write_ok
         and not storage.file_exists(object_path)
      then
         cache.last_error = write_err
         return false
      end
      cache.statistics.project_writes =
         cache.statistics.project_writes + 1
   end

   cache.manifest.project = {
      dependencies = dependencies,
      global_files = global_files,
      object_id = object_id,
      options_key = cache.options_key,
      roots = storage.copy_array(roots) as {Root},
      source_ids = source_ids,
   }
   cache.dirty = true
   return true
end

function snapshot_cache.restore(
   cache: Cache,
   compiler: Compiler,
   roots: {Root}
): boolean
   cache.project_restore_succeeded = false
   cache.project_snapshot_enabled = true
   if not cache.enabled
      or (cache.mode ~= "check" and cache.mode ~= "gen")
      or next(cache.environment_sources) ~= nil
   then
      return false
   end
   local project = cache.manifest.project
   if type(project) ~= "table"
      or project.options_key ~= cache.options_key
      or type(project.roots) ~= "table"
      or not storage.arrays_equal(project.roots, roots)
      or type(project.source_ids) ~= "table"
   then
      cache.statistics.project_misses =
         cache.statistics.project_misses + 1
      return false
   end

   local changed: {string:boolean} = {}
   for filename, expected in pairs(project.source_ids) do
      local source = storage.read_file(filename)
      if not source
         or cache:_source_id(filename, source) ~= expected
      then
         changed[filename] = true
      end
   end

   local env = compiler_artifacts.environment(compiler)
   local session = env and env.session
   if not session then
      cache.statistics.project_misses =
         cache.statistics.project_misses + 1
      return false
   end
   local affected_count, loaded_count =
      project_affected_count(
         project,
         changed,
         env,
         session
      )
   local manifest_dependencies_checked =
      affected_count ~= nil
   if affected_count
      and affected_count >= MIN_REBUILD_INVALIDATED
      and affected_count
         >= loaded_count * REBUILD_INVALIDATION_RATIO
   then
      cache.project_snapshot_enabled = false
      cache.statistics.project_bypasses =
         cache.statistics.project_bypasses + 1
      return false
   end

   local object_path =
      storage.object_path(cache, project.object_id)
   local object_size = lfs.attributes(object_path, "size")
   if object_size and object_size > MAX_RESTORE_BYTES then
      cache.project_snapshot_enabled = false
      cache.statistics.project_bypasses =
         cache.statistics.project_bypasses + 1
      return false
   end
   local bytes = storage.read_file(object_path)
   local decoded: any
   local decode_err: string
   if bytes then
      decoded, decode_err = cache_format.decode(bytes)
   end
   if type(decoded) ~= "table" then
      cache.last_error = decode_err or "invalid project object"
      cache.statistics.project_misses =
         cache.statistics.project_misses + 1
      return false
   end
   local snapshot = decoded as Snapshot
   if snapshot.snapshot_version ~= SNAPSHOT_VERSION
      or snapshot.options_key ~= cache.options_key
      or snapshot.resolution_text ~= cache.resolution_text
      or type(snapshot.loaded_order) ~= "table"
      or type(snapshot.module_names) ~= "table"
      or type(snapshot.results) ~= "table"
      or type(snapshot.typeid_namespace) ~= "string"
      or type(snapshot.typeid_ctr) ~= "number"
      or type(snapshot.typevar_ctr) ~= "number"
      or not storage.arrays_equal(
         snapshot.roots or {},
         roots
      )
      or not session
      or #env.loaded_order ~= 0
   then
      cache.last_error = decode_err or "invalid project object"
      cache.statistics.project_misses =
         cache.statistics.project_misses + 1
      return false
   end

   for _, filename in ipairs(snapshot.loaded_order) do
      local member = snapshot.results[filename]
      local result = member and member.result
      if type(member) ~= "table"
         or type(member.global_after) ~= "table"
         or type(result) ~= "table"
         or type(result.ast) ~= "table"
         or type(result.type) ~= "table"
         or type(result.dependencies) ~= "table"
      then
         cache.last_error = "invalid project result"
         cache.statistics.project_misses =
            cache.statistics.project_misses + 1
         return false
      end
      if manifest_dependencies_checked then
         if not storage.maps_equal(
            result.dependencies,
            project.dependencies[filename] or {}
         ) then
            cache.last_error =
               "project dependency metadata changed"
            cache.statistics.project_misses =
               cache.statistics.project_misses + 1
            return false
         end
      else
         for module_name, expected_filename in pairs(
            result.dependencies
         ) do
            local found, dependency_source =
               env.resolve_module(env, module_name)
            if found then
               found = session:normalize_filename(found)
            end
            if found ~= expected_filename
               or not dependency_source
            then
               changed[filename] = true
            end
         end
      end
   end

   local current_typeid, current_typevar =
      types.internal_get_state()
   types.internal_force_state(
      math.max(current_typeid, snapshot.typeid_ctr),
      math.max(current_typevar, snapshot.typevar_ctr)
   )
   for _, filename in ipairs(snapshot.loaded_order) do
      local member = snapshot.results[filename]
      local result = member.result
      result.env = env
      for name in pairs(result.global_previous or {}) do
         result.global_previous[name] =
            env.globals[name] or false
         local after = member.global_after[name]
         if after == false then
            env.globals[name] = nil
         else
            env.globals[name] = after as Variable
         end
      end
      env.loaded[filename] = result
      env.loaded_order[#env.loaded_order + 1] = filename
      session.restored_results[result] = true
      session:record_result(filename, result.dependencies)
   end
   for filename, names in pairs(snapshot.module_names) do
      local result = env.loaded[filename]
      for _, module_name in ipairs(names) do
         session:bind_module(filename, module_name, result)
      end
   end
   for _, root in ipairs(roots) do
      session:remember_root(root.filename, root.module_name)
   end
   session.restored_namespace = snapshot.typeid_namespace
   local changed_filenames = storage.sorted_keys(changed)
   local invalidated: {string:boolean} = {}
   for _, filename in ipairs(changed_filenames) do
      local change = compiler:invalidate(filename)
      for _, item in ipairs(change.evicted) do
         invalidated[item.filename] = true
      end
   end
   cache.project_restored = #changed_filenames == 0
   cache.project_restore_succeeded = true
   cache.statistics.project_hits =
      cache.statistics.project_hits + 1
   if not cache.project_restored then
      cache.statistics.project_partial_hits =
         cache.statistics.project_partial_hits + 1
      for _ in pairs(invalidated) do
         cache.statistics.project_invalidated =
            cache.statistics.project_invalidated + 1
      end
   end
   return true
end

return snapshot_cache
