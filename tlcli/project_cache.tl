local ipairs = ipairs
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

local type teal = require("teal.init")
local type errors = require("teal.errors")
local type incremental_contract =
   require("teal.internal.incremental_contract")
local type parser = require("teal.parser")
local type Compiler = teal.Compiler
local type Error = errors.Error
local type CachedResult = incremental_contract.CachedResult
local type Node = parser.Node
local type Root = storage.Root

local record project_cache
   record Cache is storage.Cache
      get_parse: function(
         self: Cache,
         filename: string,
         source: string,
         flavor: string
      ): Node, {Error}, {string}
      put_parse: function(
         self: Cache,
         filename: string,
         source: string,
         flavor: string,
         ast: Node,
         syntax_errors: {Error},
         required_modules: {string}
      )
      record_result: function(
         self: Cache,
         filename: string,
         dependencies: {string:string}
      )
      put_checked: function(
         self: Cache,
         filename: string,
         source: string,
         result: any,
         typeid_ctr: integer,
         typevar_ctr: integer
      )
      load_checked: function(
         self: Cache,
         filename: string,
         module_name: string,
         source: string,
         resolve_module: function(string): string, string
      ): {CachedResult}
      bind_environment: function(self: Cache, filenames: {string})
      put_project: function(self: Cache, Compiler, {Root}): boolean
      restore_project: function(self: Cache, Compiler, {Root}): boolean
      load_generated: function(
         self: Cache,
         Compiler,
         {Root}
      ): {string}, boolean
      load_partial_generated: function(
         self: Cache,
         Compiler,
         {Root}
      ): {string}
      generation_requires_full_rebuild: function(
         self: Cache,
         Compiler
      ): boolean
      put_generated: function(
         self: Cache,
         Compiler,
         {Root},
         {string}
      ): boolean
      invalidate: function(
         self: Cache,
         filename: string,
         affected: {string}
      ): {string}
      flush: function(self: Cache): boolean, string
      prune: function(self: Cache, minimum_age?: integer): integer
      stats: function(self: Cache): {string:integer}
      cache_directory: function(self: Cache): string
      is_enabled: function(self: Cache): boolean

      did_prune: boolean
      generation_roots: {Root}
      project_roots: {Root}
   end

   record Options
      directory: string
      project_root: string
      mode: string
      options_key: string
      typeid_namespace: string
      max_bytes: integer
   end

   open: function(options?: Options): Cache
   version: integer
end

local ProjectCache = project_cache.Cache
local ProjectCache_mt: metatable<ProjectCache> = {
   __index = ProjectCache,
}

function ProjectCache:_source_id(
   filename: string,
   source: string
): string
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
   _filename: string,
   _source: string,
   _flavor: string
): Node, {Error}, {string}
   return nil
end

function ProjectCache:put_parse(
   filename: string,
   source: string,
   _flavor: string,
   _ast: Node,
   syntax_errors: {Error},
   _required_modules: {string}
)
   if not self.enabled or #syntax_errors > 0 then
      return
   end

   local previous_record = self.manifest.files[filename]
   local record = previous_record or {
      dependencies = {},
   }
   local current_source_id = self:_source_id(filename, source)
   local source_changed = not previous_record
      or record.source_id ~= current_source_id
   if source_changed then
      self.manifest.project = nil
   end
   record.source_id = current_source_id
   self.manifest.files[filename] = record
   self.dirty = self.dirty or source_changed
end

function ProjectCache:record_result(
   filename: string,
   dependencies: {string:string}
)
   if not self.enabled then
      return
   end
   local previous_record = self.manifest.files[filename]
   local record = previous_record or {}
   local copied_dependencies = storage.copy_map(dependencies)
      as {string:string}
   local changed = not previous_record
      or not storage.maps_equal(
         record.dependencies,
         copied_dependencies
      )
   if changed then
      self.manifest.project = nil
      record.dependencies = copied_dependencies
      self.manifest.files[filename] = record
      self.dirty = true
   end
end

function ProjectCache:put_checked(
   _filename: string,
   _source: string,
   _result: any,
   _typeid_ctr: integer,
   _typevar_ctr: integer
)
end

function ProjectCache:bind_environment(filenames: {string})
   local sources: {string:string} = {}
   local parts: {string} = {}
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
   self.options_key = self.base_options_key
      .. "\0"
      .. storage.digest(table.concat(parts, "\0"))
end

function ProjectCache:load_checked(
   _filename: string,
   _module_name: string,
   _source: string,
   _resolve_module: function(string): string, string
): {CachedResult}
   return nil
end

function ProjectCache:put_project(
   compiler: Compiler,
   roots: {Root}
): boolean
   return snapshot_cache.put(self, compiler, roots)
end

function ProjectCache:restore_project(
   compiler: Compiler,
   roots: {Root}
): boolean
   return snapshot_cache.restore(self, compiler, roots)
end

function ProjectCache:load_generated(
   compiler: Compiler,
   roots: {Root}
): {string}, boolean
   return generated_cache.load(self, compiler, roots)
end

function ProjectCache:load_partial_generated(
   compiler: Compiler,
   roots: {Root}
): {string}
   return generated_cache.load_partial(
      self,
      compiler,
      roots
   )
end

function ProjectCache:generation_requires_full_rebuild(
   compiler: Compiler
): boolean
   return generated_cache.requires_full_rebuild(
      self,
      compiler
   )
end

function ProjectCache:put_generated(
   compiler: Compiler,
   roots: {Root},
   outputs: {string}
): boolean
   return generated_cache.put(
      self,
      compiler,
      roots,
      outputs
   )
end

function ProjectCache:invalidate(
   _filename: string,
   affected: {string}
): {string}
   self.project_restored = false
   if self.manifest.project then
      self.manifest.project = nil
      self.dirty = true
   end
   return affected
end

function ProjectCache:flush(): boolean, string
   if not self.enabled then
      return true
   end
   if not self.did_prune then
      self.did_prune = true
      pcall(self.prune, self)
   end
   return storage.flush_manifest(self)
end

function ProjectCache:prune(minimum_age?: integer): integer
   return storage.prune(self, minimum_age)
end

function ProjectCache:stats(): {string:integer}
   return storage.copy_map(self.statistics)
      as {string:integer}
end

function ProjectCache:cache_directory(): string
   return self.directory
end

function ProjectCache:is_enabled(): boolean
   return self.enabled
end

function project_cache.open(
   options?: project_cache.Options
): ProjectCache
   options = options or {}
   local project_root = options.project_root
      or lfs.currentdir()
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
      typeid_namespace = options.typeid_namespace
         or storage.process_identity,
      max_bytes = options.max_bytes
         or storage.default_max_bytes,
   } as ProjectCache, ProjectCache_mt)

   return storage.open(
      self,
      options as storage.OpenOptions
   ) as ProjectCache
end

project_cache.version = storage.version

return project_cache
