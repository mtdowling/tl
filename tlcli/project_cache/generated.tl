local ipairs = ipairs
local next = next
local os = os
local pairs = pairs
local table = table
local type = type

local cache_format = require("tlcli.cache_format")
local compiler_artifacts =
   require("teal.internal.compiler_artifacts")
local storage = require("tlcli.project_cache.storage")

local type teal = require("teal.init")
local type incremental_contract =
   require("teal.internal.incremental_contract")
local type Compiler = teal.Compiler
local type Session = incremental_contract.Session
local type Cache = storage.Cache
local type Root = storage.Root
local type Generation = storage.Generation
local type GenerationMember = storage.GenerationMember

local record GeneratedObject
   context_id: string
   filename: string
   generation_version: integer
   module_name: string
   options_key: string
   output: string
   resolution_text: string
   source_id: string
end

local record GenerationEntry
   id: string
   stored_at: integer
end

local record GeneratedCache
   load: function(Cache, Compiler, {Root}): {string}, boolean
   load_partial: function(Cache, Compiler, {Root}): {string}
   requires_full_rebuild: function(Cache, Compiler): boolean
   put: function(Cache, Compiler, {Root}, {string}): boolean
end

local generated_cache = {} as GeneratedCache

local GENERATION_VERSION = 2
local MAX_GENERATIONS = 16

local function request_id(cache: Cache, roots: {Root}): string
   local parts: {string | number} = {
      "generation-request",
      GENERATION_VERSION,
      cache.options_key,
   }
   for _, root in ipairs(roots) do
      parts[#parts + 1] = root.filename
      parts[#parts + 1] = root.module_name or ""
   end
   return storage.digest(table.concat(parts, "\0"))
end

local function member_object_id(
   cache: Cache,
   root: Root,
   context_id: string
): string
   return storage.digest(
      "generated-file",
      GENERATION_VERSION,
      cache_format.runtime_fingerprint,
      cache.options_key,
      root.filename,
      root.module_name or "",
      context_id
   )
end

local function member_context_id(
   cache: Cache,
   filename: string,
   source_ids: {string:string},
   dependencies: {string:{string:string}},
   global_order: {string}
): string
   local present: {string:boolean} = {
      [filename] = true,
   }
   local queue: {string} = {
      filename,
   }
   local scan = 1
   while scan <= #queue do
      local current = queue[scan]
      for _, dependency in pairs(
         dependencies[current] or {}
      ) do
         if source_ids[dependency] and not present[dependency] then
            present[dependency] = true
            queue[#queue + 1] = dependency
         end
      end
      scan = scan + 1
   end
   local parts: {string | number} = {
      "generation-context",
      GENERATION_VERSION,
      cache.options_key,
   }
   for _, current in ipairs(storage.sorted_keys(present)) do
      parts[#parts + 1] = current
      parts[#parts + 1] = source_ids[current]
   end
   parts[#parts + 1] = "ordered-globals"
   for _, current in ipairs(global_order) do
      parts[#parts + 1] = current
      parts[#parts + 1] = source_ids[current]
   end
   return storage.digest(table.concat(parts, "\0"))
end

local function affected_files(
   cache: Cache,
   compiler: Compiler,
   generation: Generation
): {string:boolean}
   local env = compiler_artifacts.environment(compiler)
   local session = env and env.session
   if not session then
      return nil
   end

   local changed: {string:boolean} = {}
   for filename, expected in pairs(generation.source_ids) do
      local source = storage.read_file(filename)
      if not source
         or cache:_source_id(filename, source) ~= expected
      then
         changed[filename] = true
      end
   end

   local reverse_dependencies: {string:{string:boolean}} = {}
   for dependent, required in pairs(
      generation.dependencies
   ) do
      for module_name, expected_filename in pairs(required) do
         local dependents =
            reverse_dependencies[expected_filename]
         if not dependents then
            dependents = {}
            reverse_dependencies[expected_filename] =
               dependents
         end
         dependents[dependent] = true

         local found, source =
            env.resolve_module(env, module_name)
         if found then
            found = session:normalize_filename(found)
         end
         if found ~= expected_filename or not source then
            changed[dependent] = true
            changed[expected_filename] = true
         end
      end
   end

   for filename in pairs(changed) do
      if generation.global_files[filename] then
         for loaded in pairs(generation.source_ids) do
            changed[loaded] = true
         end
         break
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
   return affected
end

local function generation_for(
   cache: Cache,
   roots: {Root}
): Generation
   local generations = cache.manifest.generations
   local generation = type(generations) == "table"
      and generations[request_id(cache, roots)]
   if type(generation) ~= "table"
      or generation.options_key ~= cache.options_key
      or not storage.arrays_equal(
         generation.roots or {},
         roots
      )
      or type(generation.source_ids) ~= "table"
      or type(generation.dependencies) ~= "table"
      or type(generation.diagnostics) ~= "table"
      or type(generation.global_files) ~= "table"
      or type(generation.global_order) ~= "table"
      or type(generation.has_diagnostics) ~= "boolean"
      or type(generation.members) ~= "table"
      or #generation.members ~= #roots
   then
      return nil
   end
   return generation
end

local function load_member(
   cache: Cache,
   root: Root,
   member: GenerationMember
): string
   if type(member) ~= "table"
      or member.filename ~= root.filename
      or member.module_name ~= root.module_name
      or type(member.context_id) ~= "string"
      or type(member.object_id) ~= "string"
      or type(member.source_id) ~= "string"
   then
      return nil
   end

   local path = storage.object_path(
      cache,
      member.object_id,
      "gen"
   )
   local bytes = storage.read_file(path)
   local decoded: any
   local decode_err: string
   if bytes then
      decoded, decode_err = cache_format.decode(bytes)
   end
   if type(decoded) ~= "table" then
      cache.last_error =
         decode_err or "invalid generated object"
      if bytes then
         os.remove(path)
      end
      return nil
   end
   local object = decoded as GeneratedObject
   if object.generation_version ~= GENERATION_VERSION
      or object.options_key ~= cache.options_key
      or object.resolution_text ~= cache.resolution_text
      or object.filename ~= member.filename
      or object.module_name ~= member.module_name
      or object.context_id ~= member.context_id
      or object.source_id ~= member.source_id
      or type(object.output) ~= "string"
   then
      cache.last_error =
         decode_err or "invalid generated object"
      if bytes then
         os.remove(path)
      end
      return nil
   end
   return object.output
end

local function trim_generations(cache: Cache)
   local generations = cache.manifest.generations
   local entries: {GenerationEntry} = {}
   for id, generation in pairs(generations) do
      entries[#entries + 1] = {
         id = id,
         stored_at = type(generation) == "table"
            and generation.stored_at
            or 0,
      }
   end
   table.sort(entries, function(
      left: GenerationEntry,
      right: GenerationEntry
   ): boolean
      return left.stored_at > right.stored_at
   end)
   for i = MAX_GENERATIONS + 1, #entries do
      generations[entries[i].id] = nil
   end
end

function generated_cache.load(
   cache: Cache,
   compiler: Compiler,
   roots: {Root}
): {string}, boolean
   if not cache.enabled or cache.mode ~= "gen" then
      return nil
   end
   local generation = generation_for(cache, roots)
   cache.generation_record = generation
   local affected = generation
      and affected_files(cache, compiler, generation)
   cache.generation_affected = affected
   if not affected or next(affected) ~= nil then
      cache.statistics.generation_misses =
         cache.statistics.generation_misses + 1
      return nil, generation
         and generation.has_diagnostics
   end

   local outputs: {string} = {}
   for i, root in ipairs(roots) do
      local member = generation.members[i]
      local output = load_member(cache, root, member)
      if not output then
         cache.statistics.generation_misses =
            cache.statistics.generation_misses + 1
         cache.statistics.generation_file_misses =
            cache.statistics.generation_file_misses + 1
         return nil, generation.has_diagnostics
      end
      outputs[i] = output
   end

   cache.statistics.generation_hits =
      cache.statistics.generation_hits + 1
   cache.statistics.generation_file_hits =
      cache.statistics.generation_file_hits + #outputs
   return outputs, generation.has_diagnostics
end

function generated_cache.load_partial(
   cache: Cache,
   compiler: Compiler,
   roots: {Root}
): {string}
   if not cache.enabled
      or cache.mode ~= "gen"
   then
      return {}
   end

   local generation = generation_for(cache, roots)
   cache.generation_record = generation
   if not generation then
      if cache.project_restore_succeeded then
         for _, root in ipairs(roots) do
            compiler:invalidate(root.filename)
         end
      end
      return {}
   end
   local affected = cache.generation_affected
      or affected_files(cache, compiler, generation)
   if not affected then
      return {}
   end

   local outputs: {string} = {}
   local env = compiler_artifacts.environment(compiler)
   local session = env.session
   for i, root in ipairs(roots) do
      local filename =
         session:normalize_filename(root.filename)
      if not affected[filename] then
         local member = generation.members[i]
         outputs[i] = load_member(
            cache,
            root,
            member
         )
         if not outputs[i] then
            affected[filename] = true
         end
      end
   end

   if cache.project_restore_succeeded then
      for _, root in ipairs(roots) do
         local filename =
            session:normalize_filename(root.filename)
         if affected[filename]
            and env.loaded[filename]
         then
            local change = compiler:invalidate(
               root.filename
            )
            for _, evicted in ipairs(change.evicted) do
               affected[evicted.filename] = true
            end
         end
      end
      for i, root in ipairs(roots) do
         local filename =
            session:normalize_filename(root.filename)
         if affected[filename] then
            outputs[i] = nil
         end
      end
   end

   local hits = 0
   local misses = 0
   for i = 1, #roots do
      if outputs[i] then
         hits = hits + 1
      else
         misses = misses + 1
      end
   end
   if hits > 0 then
      cache.statistics.generation_partial_hits =
         cache.statistics.generation_partial_hits + 1
   end
   cache.statistics.generation_file_hits =
      cache.statistics.generation_file_hits + hits
   cache.statistics.generation_file_misses =
      cache.statistics.generation_file_misses + misses
   return outputs
end

function generated_cache.requires_full_rebuild(
   cache: Cache,
   compiler: Compiler
): boolean
   if cache.generation_full_rebuild_required then
      return true
   end
   local generation = cache.generation_record
   local env = compiler_artifacts.environment(compiler)
   if not generation or not env then
      return false
   end
   for filename, result in pairs(env.loaded or {}) do
      if next(result.global_previous or {})
         and not generation.global_files[filename]
      then
         cache.generation_full_rebuild_required = true
         cache.project_snapshot_enabled = false
         return true
      end
   end
   return false
end

local function write_member(
   cache: Cache,
   root: Root,
   source_id: string,
   context_id: string,
   output: string
): string
   local object_id = member_object_id(
      cache,
      root,
      context_id
   )
   local object = {
      context_id = context_id,
      filename = root.filename,
      generation_version = GENERATION_VERSION,
      module_name = root.module_name,
      options_key = cache.options_key,
      output = output,
      resolution_text = cache.resolution_text,
      source_id = source_id,
   }
   local bytes, encode_err = cache_format.encode(
      object as {any:any}
   )
   if not bytes then
      cache.last_error = encode_err
      return nil
   end

   local path = storage.object_path(cache, object_id, "gen")
   if not storage.file_exists(path) then
      local directory = path:match("^(.*)[/\\][^/\\]+$")
      local ok, directory_err =
         storage.ensure_directory(directory)
      if not ok then
         cache.last_error = directory_err
         return nil
      end
      local write_ok, write_err =
         storage.atomic_write(path, bytes)
      if not write_ok and not storage.file_exists(path) then
         cache.last_error = write_err
         return nil
      end
      cache.statistics.generation_writes =
         cache.statistics.generation_writes + 1
      cache.statistics.generation_file_writes =
         cache.statistics.generation_file_writes + 1
   end
   return object_id
end

local function copy_nested_maps(
   values: {string:{string:string}}
): {string:{string:string}}
   local result: {string:{string:string}} = {}
   for key, nested in pairs(values or {}) do
      result[key] = storage.copy_map(nested)
         as {string:string}
   end
   return result
end

local function retain_reachable(
   roots: {Root},
   session: Session,
   source_ids: {string:string},
   dependencies: {string:{string:string}},
   global_files: {string:boolean},
   diagnostics: {string:boolean}
)
   local retained: {string:boolean} = {}
   local queue: {string} = {}
   for _, root in ipairs(roots) do
      local filename =
         session:normalize_filename(root.filename)
      if not retained[filename] then
         retained[filename] = true
         queue[#queue + 1] = filename
      end
   end
   for filename in pairs(global_files) do
      if not retained[filename] then
         retained[filename] = true
         queue[#queue + 1] = filename
      end
   end

   local scan = 1
   while scan <= #queue do
      local filename = queue[scan]
      for _, dependency in pairs(
         dependencies[filename] or {}
      ) do
         if not retained[dependency] then
            retained[dependency] = true
            queue[#queue + 1] = dependency
         end
      end
      scan = scan + 1
   end

   for filename in pairs(source_ids) do
      if not retained[filename] then
         source_ids[filename] = nil
         dependencies[filename] = nil
         global_files[filename] = nil
         diagnostics[filename] = nil
      end
   end
end

function generated_cache.put(
   cache: Cache,
   compiler: Compiler,
   roots: {Root},
   outputs: {string}
): boolean
   if not cache.enabled
      or cache.mode ~= "gen"
      or cache.generation_full_rebuild_required
      or #roots == 0
      or type(outputs) ~= "table"
      or #outputs ~= #roots
   then
      return false
   end
   for i, root in ipairs(roots) do
      if root.filename == "-"
         or type(outputs[i]) ~= "string"
      then
         return false
      end
   end

   local env = compiler_artifacts.environment(compiler)
   local session = env and env.session
   if not session then
      return false
   end
   local previous = generation_for(cache, roots)
   local loaded_order = storage.copy_array(env.loaded_order)
      as {string}
   local source_ids = storage.copy_map(
      previous and previous.source_ids
   ) as {string:string}
   local dependencies = copy_nested_maps(
      previous and previous.dependencies
   )
   local diagnostics = storage.copy_map(
      previous and previous.diagnostics
   ) as {string:boolean}
   local global_files = storage.copy_map(
      previous and previous.global_files
   ) as {string:boolean}
   local global_order = storage.copy_array(
      previous and previous.global_order
   ) as {string}
   for _, filename in ipairs(loaded_order) do
      local result = env.loaded[filename]
      local source = session.source_inputs[filename]
         or storage.read_file(filename)
      if type(result) ~= "table" or not source then
         return false
      end
      if #(result.syntax_errors or {}) > 0
         or #(result.type_errors or {}) > 0
         or #(result.warnings or {}) > 0
      then
         diagnostics[filename] = true
      else
         diagnostics[filename] = nil
      end
      source_ids[filename] =
         cache:_source_id(filename, source)
      dependencies[filename] =
         storage.copy_map(result.dependencies)
            as {string:string}
      if next(result.global_previous or {}) then
         global_files[filename] = true
      else
         global_files[filename] = nil
      end
   end

   local all_roots_loaded = true
   for _, root in ipairs(roots) do
      local filename =
         session:normalize_filename(root.filename)
      if not env.loaded[filename] then
         all_roots_loaded = false
         break
      end
   end
   if not previous or all_roots_loaded then
      global_order = {}
      for _, filename in ipairs(loaded_order) do
         if global_files[filename] then
            global_order[#global_order + 1] = filename
         end
      end
   end

   retain_reachable(
      roots,
      session,
      source_ids,
      dependencies,
      global_files,
      diagnostics
   )
   local retained_global_order: {string} = {}
   for _, filename in ipairs(global_order) do
      if global_files[filename] and source_ids[filename] then
         retained_global_order[#retained_global_order + 1] =
            filename
      end
   end
   global_order = retained_global_order

   local members: {GenerationMember} = {}
   for i, root in ipairs(roots) do
      local filename =
         session:normalize_filename(root.filename)
      local source_id = source_ids[filename]
      if not source_id then
         return false
      end
      local context_id = member_context_id(
         cache,
         filename,
         source_ids,
         dependencies,
         global_order
      )
      local object_id = write_member(
         cache,
         root,
         source_id,
         context_id,
         outputs[i]
      )
      if not object_id then
         return false
      end
      members[i] = {
         context_id = context_id,
         filename = root.filename,
         module_name = root.module_name,
         object_id = object_id,
         source_id = source_id,
      }
   end

   cache.manifest.generations =
      cache.manifest.generations or {}
   cache.manifest.generations[request_id(cache, roots)] = {
      dependencies = dependencies,
      diagnostics = diagnostics,
      global_files = global_files,
      global_order = global_order,
      has_diagnostics = next(diagnostics) ~= nil,
      members = members,
      options_key = cache.options_key,
      roots = storage.copy_array(roots) as {Root},
      source_ids = source_ids,
      stored_at = os.time(),
   }
   trim_generations(cache)
   cache.dirty = true
   return true
end

return generated_cache
