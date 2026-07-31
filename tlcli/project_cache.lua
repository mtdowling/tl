local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local os = _tl_compat and _tl_compat.os or os; local package = _tl_compat and _tl_compat.package or package; local pcall = _tl_compat and _tl_compat.pcall or pcall; local table = _tl_compat and _tl_compat.table or table; local ipairs = ipairs
local os = os
local package = package
local pcall = pcall
local require = require
local setmetatable = setmetatable
local table = table

local lfs = require("lfs")
local generated_cache =
require("tlcli.project_cache.generated")
local snapshot_cache =
require("tlcli.project_cache.snapshot")
local storage =
require("tlcli.project_cache.storage")












local project_cache = { Cache = {}, Options = {} }
























































































local ProjectCache = project_cache.Cache
local ProjectCache_mt = {
   __index = ProjectCache,
}

function ProjectCache:_source_id(
   filename,
   source)

   local previous = self.source_ids[filename]
   if previous and previous.source == source then
      return previous.id
   end
   local id = storage.source_id(filename, source)
   self.source_ids[filename] = {
      id = id,
      source = source,
   }
   return id
end

function ProjectCache:get_parse(
   _filename,
   _source,
   _flavor)

   return nil
end

function ProjectCache:put_parse(
   filename,
   source,
   _flavor,
   _ast,
   syntax_errors,
   _required_modules)

   if not self.enabled or #syntax_errors > 0 then
      return
   end

   local previous_record = self.manifest.files[filename]
   local record = previous_record or {
      dependencies = {},
   }
   local current_source_id = self:_source_id(filename, source)
   local source_changed = not previous_record or
   record.source_id ~= current_source_id
   if source_changed then
      self.manifest.project = nil
   end
   record.source_id = current_source_id
   self.manifest.files[filename] = record
   self.dirty = self.dirty or source_changed
end

function ProjectCache:record_result(
   filename,
   dependencies)

   if not self.enabled then
      return
   end
   local previous_record = self.manifest.files[filename]
   local record = previous_record or {}
   local copied_dependencies = storage.copy_map(dependencies)

   local changed = not previous_record or
   not storage.maps_equal(
   record.dependencies,
   copied_dependencies)

   if changed then
      self.manifest.project = nil
      record.dependencies = copied_dependencies
      self.manifest.files[filename] = record
      self.dirty = true
   end
end

function ProjectCache:put_checked(
   _filename,
   _source,
   _result,
   _typeid_ctr,
   _typevar_ctr)

end

function ProjectCache:bind_environment(filenames)
   local sources = {}
   local parts = {}
   table.sort(filenames)
   for _, filename in ipairs(filenames) do
      local source = storage.read_file(filename)
      if source then
         sources[filename] = source
         parts[#parts + 1] = filename
         parts[#parts + 1] = source
      end
   end
   self.environment_sources = sources
   self.options_key = self.base_options_key ..
   "\0" ..
   storage.digest(table.concat(parts, "\0"))
end

function ProjectCache:load_checked(
   _filename,
   _module_name,
   _source,
   _resolve_module)

   return nil
end

function ProjectCache:put_project(
   compiler,
   roots)

   return snapshot_cache.put(self, compiler, roots)
end

function ProjectCache:restore_project(
   compiler,
   roots)

   return snapshot_cache.restore(self, compiler, roots)
end

function ProjectCache:load_generated(
   compiler,
   roots)

   return generated_cache.load(self, compiler, roots)
end

function ProjectCache:load_partial_generated(
   compiler,
   roots)

   return generated_cache.load_partial(
   self,
   compiler,
   roots)

end

function ProjectCache:generation_requires_full_rebuild(
   compiler)

   return generated_cache.requires_full_rebuild(
   self,
   compiler)

end

function ProjectCache:put_generated(
   compiler,
   roots,
   outputs)

   return generated_cache.put(
   self,
   compiler,
   roots,
   outputs)

end

function ProjectCache:invalidate(
   _filename,
   affected)

   self.project_restored = false
   if self.manifest.project then
      self.manifest.project = nil
      self.dirty = true
   end
   return affected
end

function ProjectCache:flush()
   if not self.enabled then
      return true
   end
   if not self.did_prune then
      self.did_prune = true
      pcall(self.prune, self)
   end
   return storage.flush_manifest(self)
end

function ProjectCache:prune(minimum_age)
   return storage.prune(self, minimum_age)
end

function ProjectCache:stats()
   return storage.copy_map(self.statistics)

end

function ProjectCache:cache_directory()
   return self.directory
end

function ProjectCache:is_enabled()
   return self.enabled
end

function project_cache.open(
   options)

   options = options or {}
   local project_root = options.project_root or
   lfs.currentdir()
   local resolution_text =
   package.path .. "\0" .. (os.getenv("TL_PATH") or "")
   local resolution_key = storage.digest(resolution_text)
   local statistics = {
      generation_hits = 0,
      generation_file_hits = 0,
      generation_file_misses = 0,
      generation_file_writes = 0,
      generation_misses = 0,
      generation_partial_hits = 0,
      generation_writes = 0,
      manifest_hits = 0,
      manifest_misses = 0,
      pruned = 0,
      project_bypasses = 0,
      project_hits = 0,
      project_invalidated = 0,
      project_misses = 0,
      project_partial_hits = 0,
      project_writes = 0,
   }

   local self = setmetatable({
      did_prune = false,
      dirty = false,
      enabled = false,
      source_ids = {},
      environment_sources = {},
      mode = options.mode,
      project_restored = false,
      project_restore_succeeded = false,
      project_snapshot_enabled = true,
      project_root = project_root,
      resolution_key = resolution_key,
      resolution_text = resolution_text,
      base_options_key = options.options_key or "",
      options_key = options.options_key or "",
      statistics = statistics,
      typeid_namespace = options.typeid_namespace or
      storage.process_identity,
      max_bytes = options.max_bytes or
      storage.default_max_bytes,
   }, ProjectCache_mt)

   return storage.open(
   self,
   options)

end

project_cache.version = storage.version

return project_cache
