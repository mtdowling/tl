local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local io = _tl_compat and _tl_compat.io or io; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local math = _tl_compat and _tl_compat.math or math; local package = _tl_compat and _tl_compat.package or package; local pairs = _tl_compat and _tl_compat.pairs or pairs; local pcall = _tl_compat and _tl_compat.pcall or pcall; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local type = type; local environment = require("teal.environment")









local contract = require("teal.internal.incremental_contract")
local types = require("teal.types")

local incremental = {}












local Session = contract.Session
local Session_mt = {
   __index = Session,
}

local PATH_SEPARATOR = package.config:sub(1, 1)

local function normalize_filename(filename)
   local drive = ""
   if PATH_SEPARATOR == "\\" then
      filename = filename:gsub("\\", "/")
      drive, filename = filename:match("^(.:)(.*)$")
      drive = drive or ""
   end
   local absolute = filename:sub(1, 1) == "/"
   local pieces = {}
   for piece in filename:gmatch("[^/]+") do
      if piece == ".." then
         local previous = pieces[#pieces]
         if previous and previous ~= ".." then
            table.remove(pieces)
         elseif not absolute then
            table.insert(pieces, piece)
         end
      elseif piece ~= "." then
         table.insert(pieces, piece)
      end
   end
   filename = drive ..
   (absolute and "/" or "") ..
   table.concat(pieces, "/")
   if PATH_SEPARATOR == "\\" then
      filename = filename:gsub("/", "\\")
   end
   return filename
end

local function read_file(filename)
   local fd, open_err = io.open(filename, "rb")
   if not fd then
      return nil, open_err
   end
   local source, read_err = fd:read("*a")
   fd:close()
   return source, read_err
end

local function module_names_for(
   env,
   filename)

   local names = {}
   for module_name, module_filename in pairs(
      env.module_filenames) do

      if module_filename == filename then
         table.insert(names, module_name)
      end
   end
   table.sort(names)
   return names
end

function Session:set_artifact_store(store)
   self.store = store
end

function Session:set_source_provider(provider)
   self.source_provider = provider
end

function Session:normalize_filename(filename)
   return normalize_filename(filename)
end

function Session:read_source(filename)
   local requested_filename = filename
   filename = normalize_filename(filename)
   local override = self.source_overrides[filename]
   if override ~= nil then
      return override
   end
   if self.source_provider then
      local ok, source, err = pcall(
      self.source_provider.read,
      self.source_provider,
      requested_filename)

      if ok then
         if source then
            return source, err
         end
         return read_file(filename)
      end
      return nil, tostring(source)
   end
   return read_file(filename)
end

function Session:parse(
   filename,
   source,
   flavor,
   parse_source)

   filename = normalize_filename(filename)
   self.source_inputs[filename] = source
   local store = self.store
   if store then
      local ok, ast, syntax_errors, required_modules = pcall(
      store.get_parse,
      store,
      filename,
      source,
      flavor)

      if ok and ast then
         return ast,
         syntax_errors or {},
         required_modules or {},
         true
      end
   end

   local ast, syntax_errors, required_modules = parse_source()
   if store and #syntax_errors == 0 then
      pcall(
      store.put_parse,
      store,
      filename,
      source,
      flavor,
      ast,
      syntax_errors,
      required_modules)

   end
   return ast, syntax_errors, required_modules, false
end

function Session:remember_root(
   filename,
   module_name)

   filename = normalize_filename(filename)
   local key = filename .. "\0" .. (module_name or "\1")
   if not self.roots[key] then
      table.insert(self.root_order, key)
   end
   self.roots[key] = {
      filename = filename,
      module_name = module_name,
   }
end

local function forget_roots(session, filename)
   for i = #session.root_order, 1, -1 do
      local key = session.root_order[i]
      if session.roots[key].filename == filename then
         session.roots[key] = nil
         table.remove(session.root_order, i)
      end
   end
end

function Session:bind_module(
   filename,
   module_name,
   result)

   local env = self.env
   local checked = result
   filename = normalize_filename(filename)
   env.module_filenames[module_name] = filename
   env.modules[module_name] = checked.type
   if module_name:match("%.init$") then
      local base = module_name:sub(1, -6)
      env.modules[base] = checked.type
      env.module_filenames[base] = filename
   end
end

function Session:record_result(
   filename,
   result_dependencies)

   filename = normalize_filename(filename)
   local previous = self.dependencies[filename] or {}
   for _, dependency in pairs(previous) do
      local dependents = self.reverse_dependencies[dependency]
      if dependents then
         dependents[filename] = nil
      end
   end

   local dependencies = {}
   for module_name, dependency in pairs(
      result_dependencies or {}) do

      dependency = normalize_filename(dependency)
      result_dependencies[module_name] = dependency
      dependencies[module_name] = dependency
      local dependents = self.reverse_dependencies[dependency]
      if not dependents then
         dependents = {}
         self.reverse_dependencies[dependency] = dependents
      end
      dependents[filename] = true
   end
   self.dependencies[filename] = dependencies

   if self.store then
      pcall(
      self.store.record_result,
      self.store,
      filename,
      dependencies)

   end
end

function Session:restore_checked(
   filename,
   module_name,
   source)

   local env = self.env
   local store = self.store
   filename = normalize_filename(filename)
   self.source_inputs[filename] = source
   if not store or env.report_types then
      return nil
   end
   for _, result in pairs(env.loaded) do
      if not self.restored_results[result] then
         return nil
      end
   end

   local function resolve(name)
      local found, resolved_source = env.resolve_module(env, name)
      return found and normalize_filename(found), resolved_source
   end

   local ok, plan = pcall(
   store.load_checked,
   store,
   filename,
   module_name,
   source,
   resolve)

   if not ok or type(plan) ~= "table" or #plan == 0 then
      return nil
   end

   local root
   local namespace
   local max_typeid, max_typevar = types.internal_get_state()
   for _, item in ipairs(plan) do
      if type(item) ~= "table" then
         return nil
      end
      local cached = item
      local result = cached.result
      if type(cached.filename) ~= "string" or
         type(cached.module_name) ~= "string" or
         type(cached.typeid_namespace) ~= "string" or
         type(cached.typeid_ctr) ~= "number" or
         type(cached.typevar_ctr) ~= "number" or
         type(result) ~= "table" or
         normalize_filename(result.filename) ~= cached.filename or
         type(result.ast) ~= "table" or
         type(result.type) ~= "table" or
         type(result.dependencies) ~= "table" or
         next(result.global_previous or {}) ~= nil then

         return nil
      end
      if (namespace and namespace ~= cached.typeid_namespace) or
         (self.restored_namespace and
         self.restored_namespace ~= cached.typeid_namespace) then

         return nil
      end
      namespace = cached.typeid_namespace
      max_typeid = math.max(max_typeid, cached.typeid_ctr)
      max_typevar = math.max(max_typevar, cached.typevar_ctr)
      if cached.filename == filename and
         cached.module_name == module_name then

         root = result
      end
   end
   if not root then
      return nil
   end

   types.internal_force_state(max_typeid, max_typevar)
   for _, item in ipairs(plan) do
      local cached = item
      local result = cached.result
      local existing = env.loaded[cached.filename]
      if existing then
         if not self.restored_results[existing] then
            return nil
         end
         result = existing
      else
         result.env = env
         environment.register(
         env,
         cached.filename,
         result)

         self.restored_results[result] = true
      end
      self:bind_module(
      cached.filename,
      cached.module_name,
      result)

      if cached.filename == filename and
         cached.module_name == module_name then

         root = result
      end
   end
   self.restored_namespace = namespace
   return root
end

function Session:affected(filename)
   filename = normalize_filename(filename)
   local affected = {}
   local queued = { [filename] = true }
   local queue = { filename }
   local env = self.env
   for dependent, dependencies in pairs(self.dependencies) do
      for module_name, expected in pairs(dependencies) do
         local found = env.resolve_module(env, module_name)
         if (found and normalize_filename(found) or nil) ~= expected then
            if not queued[expected] then
               queued[expected] = true
               table.insert(queue, expected)
            end
            if not queued[dependent] then
               queued[dependent] = true
               table.insert(queue, dependent)
            end
         end
      end
   end
   local scan = 1
   while scan <= #queue do
      local current = queue[scan]
      table.insert(affected, current)
      for dependent in pairs(
         self.reverse_dependencies[current] or {}) do

         if not queued[dependent] then
            queued[dependent] = true
            table.insert(queue, dependent)
         end
      end
      scan = scan + 1
   end
   table.sort(affected)
   return affected
end

function Session:update(
   filename,
   source)

   filename = normalize_filename(filename)
   self.source_inputs[filename] = source
   local env = self.env
   local known = env.loaded[filename] ~= nil or
   self.dependencies[filename] ~= nil or
   self.reverse_dependencies[filename] ~= nil
   self.source_overrides[filename] = source
   local change = self:invalidate(filename)
   if not known then
      table.insert(change.roots, {
         filename = filename,
      })
   end
   return change
end

function Session:invalidate(
   filename)

   filename = normalize_filename(filename)
   local env = self.env
   local affected = self:affected(filename)
   local aliases = {}
   for module_name, module_filename in pairs(
      env.module_filenames) do

      local names = aliases[module_filename]
      if not names then
         names = {}
         aliases[module_filename] = names
      end
      table.insert(names, module_name)
   end

   local remembered_roots = {}
   for _, key in ipairs(self.root_order) do
      local root = self.roots[key]
      table.insert(remembered_roots, {
         filename = root.filename,
         module_name = root.module_name,
      })
   end

   local invalidated_set = {}
   for _, current in ipairs(affected) do
      invalidated_set[current] = true
   end
   for current in pairs(invalidated_set) do
      local result = env.loaded[current]
      if result and next(result.global_previous or {}) then
         for _, loaded in ipairs(env.loaded_order) do
            invalidated_set[loaded] = true
         end
         break
      end
   end

   local invalidated = {}
   local report_filenames = {}
   local reset_reporter = false
   for i = #env.loaded_order, 1, -1 do
      local current = env.loaded_order[i]
      if invalidated_set[current] then
         local result = env.loaded[current]
         if result then
            table.insert(report_filenames, result.filename)
            if next(result.global_previous or {}) then
               reset_reporter = true
            end
            for name, previous in pairs(
               result.global_previous or {}) do

               if type(previous) == "boolean" then
                  env.globals[name] = nil
               else
                  env.globals[name] = previous
               end
            end
         end
         env.loaded[current] = nil
         self.cached_results[current] = nil
         table.remove(env.loaded_order, i)
         table.insert(invalidated, current)
      end
   end

   for module_name, module_filename in pairs(
      env.module_filenames) do

      if invalidated_set[module_filename] then
         env.module_filenames[module_name] = nil
         env.modules[module_name] = nil
      end
   end
   if env.reporter and reset_reporter then
      env.reporter = nil
   elseif env.reporter then
      env.reporter:remove_files(report_filenames)
   end
   table.sort(invalidated)

   for _, current in ipairs(invalidated) do
      for _, dependency in pairs(
         self.dependencies[current] or {}) do

         local dependents = self.reverse_dependencies[dependency]
         if dependents then
            dependents[current] = nil
            if next(dependents) == nil then
               self.reverse_dependencies[dependency] = nil
            end
         end
      end
      self.dependencies[current] = nil
   end

   if self.store then
      local persisted = {}
      local present = {}
      for _, current in ipairs(affected) do
         present[current] = true
         table.insert(persisted, current)
      end
      for _, current in ipairs(invalidated) do
         if not present[current] then
            table.insert(persisted, current)
         end
      end
      table.sort(persisted)
      pcall(
      self.store.invalidate,
      self.store,
      filename,
      persisted)

   end

   local evicted = {}
   for _, current in ipairs(invalidated) do
      local module_names = aliases[current] or {}
      table.sort(module_names)
      table.insert(evicted, {
         filename = current,
         module_names = module_names,
      })
   end

   local roots = {}
   for _, root in ipairs(remembered_roots) do
      if invalidated_set[root.filename] then
         table.insert(roots, root)
      end
   end

   return {
      changed = filename,
      evicted = evicted,
      roots = roots,
   }
end

function Session:recheck(
   change,
   compiler)

   local env = self.env
   local batch = {
      files = {},
      roots = change.roots,
   }
   local previously_loaded = {}
   for _, filename in ipairs(env.loaded_order) do
      previously_loaded[filename] = true
   end

   for _, root in ipairs(change.roots) do
      local module
      local check_error
      local result = env.loaded[root.filename]
      if result then
         if root.module_name then
            self:bind_module(
            root.filename,
            root.module_name,
            result)

         end
         module, check_error = compiler:recall(root.filename)
      else
         local input, open_error = compiler:open(root.filename)
         if not input then
            batch.files[root.filename] = {
               filename = root.filename,
               module_names = {},
               open_error = open_error,
            }
            forget_roots(self, root.filename)
         else
            module, check_error = input:check(root.module_name)
         end
      end

      if module or check_error then
         batch.files[root.filename] = {
            filename = root.filename,
            module_names = {},
            module = module,
            errors = check_error,
         }
      end
   end

   local changed_result = env.loaded[change.changed]
   if changed_result and
      next(changed_result.global_previous or {}) and
      next(previously_loaded) then

      return self:recheck(
      self:invalidate(change.changed),
      compiler)

   end

   for _, filename in ipairs(env.loaded_order) do
      if not previously_loaded[filename] and
         not batch.files[filename] then

         local module, check_error = compiler:recall(filename)
         batch.files[filename] = {
            filename = filename,
            module_names = module_names_for(
            env,
            filename),

            module = module,
            errors = check_error,
         }
      end
   end

   for _, item in ipairs(change.evicted) do
      local file_result = batch.files[item.filename]
      if not file_result or not file_result.module then
         local module, check_error =
         compiler:recall(item.filename)
         if module then
            file_result = {
               filename = item.filename,
               module = module,
               errors = check_error,
               module_names = module_names_for(
               env,
               item.filename),

            }
            batch.files[item.filename] = file_result
         elseif not file_result then
            file_result = {
               filename = item.filename,
               module_names = item.module_names,
            }
            batch.files[item.filename] = file_result
         end
      end
      if file_result.module then
         file_result.module_names = module_names_for(
         env,
         item.filename)

      else
         file_result.module_names = item.module_names
      end
   end

   return batch
end

function Session:cache_results()
   local env = self.env
   local store = self.store
   if not store or env.report_types then
      return
   end
   local typeid_ctr, typevar_ctr = types.internal_get_state()
   for _, filename in ipairs(env.loaded_order) do
      local result = env.loaded[filename]
      if result and self.restored_results[result] then
         self.cached_results[filename] = result
      elseif result and
         not self.cached_results[filename] and
         not self.restored_namespace then

         local source = self.source_inputs[filename] or
         self:read_source(filename)
         if source then
            pcall(
            store.put_checked,
            store,
            filename,
            source,
            result,
            typeid_ctr,
            typevar_ctr)

         end
         self.cached_results[filename] = result
      end
   end
end

function incremental.new(
   env,
   store)

   return setmetatable({
      env = env,
      store = store,
      source_overrides = {},
      source_inputs = {},
      dependencies = {},
      reverse_dependencies = {},
      roots = {},
      root_order = {},
      cached_results = {},
      restored_results = {},
   }, Session_mt)
end

return incremental
