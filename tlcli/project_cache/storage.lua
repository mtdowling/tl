local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local io = _tl_compat and _tl_compat.io or io; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local math = _tl_compat and _tl_compat.math or math; local os = _tl_compat and _tl_compat.os or os; local package = _tl_compat and _tl_compat.package or package; local pairs = _tl_compat and _tl_compat.pairs or pairs; local pcall = _tl_compat and _tl_compat.pcall or pcall; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local io = io
local ipairs = ipairs
local math = math
local os = os
local package = package
local pairs = pairs
local pcall = pcall
local select = select
local string = string
local table = table
local tostring = tostring
local type = type

local cache_format = require("tlcli.cache_format")
local lfs = require("lfs")































































































































local storage = {}

local MANIFEST_VERSION = 8
local SOURCE_VERSION = 1
local DEFAULT_MAX_BYTES = 256 * 1024 * 1024
local DEFAULT_PRUNE_AGE = 10 * 60
local PROJECT_PRUNE_AGE = 30 * 24 * 60 * 60
local PATH_SEPARATOR = package.config:sub(1, 1)

local temporary_counter = 0
local process_temporary = os.tmpname()
if process_temporary then
   os.remove(process_temporary)
end
local process_identity = (process_temporary or tostring({})):
gsub("[^%w]", "") ..
"." ..
tostring(os.time()) ..
"." ..
tostring(math.floor(os.clock() * 1000000))

function storage.copy_array(values)
   local result = {}
   for i, value in ipairs(values or {}) do
      result[i] = value
   end
   return result
end

function storage.copy_map(values)
   local result = {}
   for key, value in pairs(values or {}) do
      result[key] = value
   end
   return result
end

function storage.maps_equal(
   left,
   right)

   for key, value in pairs(left or {}) do
      if not right or right[key] ~= value then
         return false
      end
   end
   for key, value in pairs(right or {}) do
      if not left or left[key] ~= value then
         return false
      end
   end
   return true
end

function storage.arrays_equal(
   left,
   right)

   if #left ~= #right then
      return false
   end
   for i = 1, #left do
      local left_item = left[i]
      local right_item = right[i]
      if type(left_item) ~= "table" or
         type(right_item) ~= "table" or
         left_item.filename ~= right_item.filename or
         left_item.module_name ~= right_item.module_name then

         return false
      end
   end
   return true
end

function storage.sorted_keys(values)
   local result = {}
   for key in pairs(values or {}) do
      result[#result + 1] = key
   end
   table.sort(result)
   return result
end

function storage.digest(...)
   local parts = {}
   for argument = 1, select("#", ...) do
      parts[#parts + 1] = tostring(select(argument, ...))
      parts[#parts + 1] = "\255" .. tostring(argument) .. "\0"
   end
   local digest = cache_format.digest(table.concat(parts))
   return digest
end

function storage.file_exists(path)
   local fd = io.open(path, "rb")
   if not fd then
      return false
   end
   fd:close()
   return true
end

function storage.read_file(path)
   local fd, open_err = io.open(path, "rb")
   if not fd then
      return nil, open_err
   end
   local data, read_err = fd:read("*a")
   fd:close()
   if not data then
      return nil, read_err
   end
   return data
end

function storage.ensure_directory(path)
   local attributes = lfs.symlinkattributes(path)
   if attributes then
      if attributes.mode == "link" then
         return nil, "cache directory is a symbolic link: " .. path
      elseif attributes.mode ~= "directory" then
         return nil, "cache path is not a directory: " .. path
      end
      return true
   end

   local parent = path:match("^(.*)[/\\][^/\\]+$")
   if parent and parent ~= "" and parent ~= path then
      local ok, parent_err = storage.ensure_directory(parent)
      if not ok then
         return nil, parent_err
      end
   end

   local ok, mkdir_err = lfs.mkdir(path)
   if not ok and not lfs.attributes(path, "mode") then
      return nil, mkdir_err
   end
   return true
end

local function remove_tree(path)
   local attributes = lfs.symlinkattributes(path)
   if not attributes then
      return true
   elseif attributes.mode ~= "directory" then
      local ok = os.remove(path)
      return ok
   end
   for basename in lfs.dir(path) do
      if basename ~= "." and basename ~= ".." then
         local ok = remove_tree(
         path .. PATH_SEPARATOR .. basename)

         if not ok then
            return nil
         end
      end
   end
   local ok = lfs.rmdir(path)
   return ok
end

local function prune_project_directories(
   projects_directory,
   current_directory)

   local now = os.time()
   for basename in lfs.dir(projects_directory) do
      if basename:match("^[0-9a-f]+$") then
         local path = projects_directory ..
         PATH_SEPARATOR ..
         basename
         if path ~= current_directory then
            local attributes = lfs.symlinkattributes(path)
            local manifest_attributes = lfs.attributes(
            path .. PATH_SEPARATOR .. "manifest.cache")

            local modified = manifest_attributes and
            manifest_attributes.modification or
            attributes and attributes.modification or
            now
            if attributes and
               attributes.mode == "directory" and
               now - modified >= PROJECT_PRUNE_AGE then

               remove_tree(path)
            end
         end
      end
   end
end

function storage.atomic_write(
   path,
   data)

   temporary_counter = temporary_counter + 1
   local temporary = path ..
   ".tmp." ..
   process_identity ..
   "." ..
   tostring(temporary_counter)
   local fd, open_err = io.open(temporary, "wb")
   if not fd then
      return nil, open_err
   end

   local ok, write_err = fd:write(data)
   if not ok then
      fd:close()
      os.remove(temporary)
      return nil, write_err
   end
   local close_ok, close_err = fd:close()
   if not close_ok then
      os.remove(temporary)
      return nil, close_err
   end

   local renamed, rename_err = os.rename(temporary, path)
   if not renamed and PATH_SEPARATOR == "\\" then
      os.remove(path)
      renamed, rename_err = os.rename(temporary, path)
   end
   if not renamed then
      os.remove(temporary)
      return nil, rename_err
   end
   return true
end

local function default_cache_base()
   local configured = os.getenv("TL_CACHE_DIR")
   if configured == "off" or configured == "0" then
      return nil
   elseif configured == "auto" then
      configured = nil
   elseif configured and configured ~= "" then
      return configured
   else
      return nil
   end

   local xdg = os.getenv("XDG_CACHE_HOME")
   if xdg and xdg ~= "" then
      return xdg
   end

   if PATH_SEPARATOR == "\\" then
      local local_app_data = os.getenv("LOCALAPPDATA")
      if local_app_data and local_app_data ~= "" then
         return local_app_data
      end
   end

   local user_home = os.getenv("HOME") or os.getenv("USERPROFILE")
   if user_home and user_home ~= "" then
      return user_home .. PATH_SEPARATOR .. ".cache"
   end
end

function storage.source_id(
   filename,
   source)

   return storage.digest(
   "source",
   SOURCE_VERSION,
   filename,
   source)

end

function storage.fresh_manifest(
   project_root,
   resolution_key)

   return {
      version = MANIFEST_VERSION,
      project_root = project_root,
      resolution_key = resolution_key,
      files = {},
   }
end

function storage.object_path(
   cache,
   object_id,
   extension)

   local shard = string.sub(object_id, 1, 2)
   local basename = string.sub(object_id, 3) ..
   "." ..
   (extension or "check")
   return cache.objects_directory ..
   PATH_SEPARATOR ..
   shard ..
   PATH_SEPARATOR ..
   basename
end

local function load_manifest(cache)
   local bytes = storage.read_file(cache.manifest_path)
   if not bytes then
      return storage.fresh_manifest(
      cache.project_root,
      cache.resolution_key)

   end

   local decoded = cache_format.decode(bytes)
   if type(decoded) ~= "table" then
      cache.statistics.manifest_misses =
      cache.statistics.manifest_misses + 1
      return storage.fresh_manifest(
      cache.project_root,
      cache.resolution_key)

   end
   local manifest = decoded
   if manifest.version ~= MANIFEST_VERSION or
      manifest.project_root ~= cache.project_root or
      manifest.resolution_key ~= cache.resolution_key or
      type(manifest.files) ~= "table" then

      cache.statistics.manifest_misses =
      cache.statistics.manifest_misses + 1
      return storage.fresh_manifest(
      cache.project_root,
      cache.resolution_key)

   end
   cache.statistics.manifest_hits =
   cache.statistics.manifest_hits + 1
   return manifest
end

function storage.open(cache, options)
   local directory = options.directory
   if not directory then
      local base = default_cache_base()
      if not base then
         cache.manifest = storage.fresh_manifest(
         cache.project_root,
         cache.resolution_key)

         cache.last_error =
         "no user cache directory is available"
         return cache
      end
      directory = base ..
      PATH_SEPARATOR ..
      "tl" ..
      PATH_SEPARATOR ..
      "projects" ..
      PATH_SEPARATOR ..
      storage.digest(cache.project_root)
      cache.projects_directory = base ..
      PATH_SEPARATOR ..
      "tl" ..
      PATH_SEPARATOR ..
      "projects"
   end

   local ok, directory_err =
   storage.ensure_directory(directory)
   if not ok then
      cache.manifest = storage.fresh_manifest(
      cache.project_root,
      cache.resolution_key)

      cache.last_error = directory_err
      return cache
   end
   local objects_directory = directory ..
   PATH_SEPARATOR ..
   "objects"
   ok, directory_err =
   storage.ensure_directory(objects_directory)
   if not ok then
      cache.manifest = storage.fresh_manifest(
      cache.project_root,
      cache.resolution_key)

      cache.last_error = directory_err
      return cache
   end

   cache.directory = directory
   cache.objects_directory = objects_directory
   cache.manifest_path = directory ..
   PATH_SEPARATOR ..
   "manifest.cache"
   cache.enabled = true
   cache.manifest = load_manifest(cache)
   if storage.file_exists(cache.manifest_path) then
      lfs.touch(cache.manifest_path)
   end
   if cache.projects_directory then
      pcall(
      prune_project_directories,
      cache.projects_directory,
      directory)

   end
   return cache
end

function storage.flush_manifest(cache)
   if not cache.dirty then
      return true
   end
   local bytes, encode_err = cache_format.encode(
   cache.manifest)

   if not bytes then
      cache.last_error = encode_err
      return nil, encode_err
   end
   local ok, write_err =
   storage.atomic_write(cache.manifest_path, bytes)
   if not ok then
      cache.last_error = write_err
      return nil, write_err
   end
   cache.dirty = false
   return true
end

function storage.prune(cache, minimum_age)
   if not cache.enabled then
      return 0
   end
   minimum_age = minimum_age or DEFAULT_PRUNE_AGE

   local referenced = {}
   if cache.manifest.project then
      referenced[cache.manifest.project.object_id] = true
   end
   for _, generation in pairs(
      cache.manifest.generations or {}) do

      if type(generation) == "table" then
         for _, member in ipairs(
            generation.members or {}) do

            if type(member) == "table" and
               member.object_id then

               referenced[member.object_id] = true
            end
         end
      end
   end

   local candidates = {}
   local total_bytes = 0
   local now = os.time()
   for shard in lfs.dir(cache.objects_directory) do
      if shard ~= "." and shard ~= ".." then
         local shard_path = cache.objects_directory ..
         PATH_SEPARATOR ..
         shard
         local attributes = lfs.symlinkattributes(shard_path)
         if attributes and attributes.mode == "directory" then
            for basename in lfs.dir(shard_path) do
               local stem = basename:match(
               "^([0-9a-f]+)%.ast$") or
               basename:match(
               "^([0-9a-f]+)%.check$") or
               basename:match("^([0-9a-f]+)%.gen$")
               local is_temporary =
               basename:match("%.tmp%.") ~= nil
               local object_id = stem and shard .. stem
               local path = shard_path ..
               PATH_SEPARATOR ..
               basename
               local file_attributes = lfs.attributes(path)
               if (is_temporary or object_id ~= nil) and
                  file_attributes then

                  total_bytes = total_bytes +
                  (file_attributes.size or 0)
                  candidates[#candidates + 1] = {
                     modified =
file_attributes.modification or now,
                     object_id = object_id,
                     path = path,
                     referenced = object_id and
                     referenced[object_id] or
                     false,
                     size = file_attributes.size or 0,
                  }
               end
            end
         end
      end
   end
   local removed = 0
   table.sort(candidates, function(
      left,
      right)

      return left.modified < right.modified
   end)
   for _, candidate in ipairs(candidates) do
      local age = now - candidate.modified
      local over_budget = total_bytes > cache.max_bytes and
      age >= math.min(minimum_age, 60)
      if not candidate.referenced and
         (age >= minimum_age or over_budget) then

         local did_remove = os.remove(candidate.path)
         if did_remove then
            total_bytes = total_bytes - candidate.size
            removed = removed + 1
         end
      end
   end

   if total_bytes > cache.max_bytes then
      for _, candidate in ipairs(candidates) do
         if total_bytes <= cache.max_bytes then
            break
         end
         if candidate.referenced and
            now - candidate.modified >= 60 and
            os.remove(candidate.path) then

            local object_id = candidate.object_id
            if cache.manifest.project and
               cache.manifest.project.object_id == object_id then

               cache.manifest.project = nil
            end
            for id, generation in pairs(
               cache.manifest.generations or {}) do

               if type(generation) == "table" then
                  for _, member in ipairs(
                     generation.members or {}) do

                     if type(member) == "table" and
                        member.object_id == object_id then

                        cache.manifest.generations[id] = nil
                        break
                     end
                  end
               end
            end
            total_bytes = total_bytes - candidate.size
            removed = removed + 1
            cache.dirty = true
         end
      end
   end
   for basename in lfs.dir(cache.directory) do
      if basename:match("^manifest%.cache%.tmp%.") then
         local path = cache.directory ..
         PATH_SEPARATOR ..
         basename
         local modified =
         lfs.attributes(path, "modification") or now
         if now - modified >= minimum_age and
            os.remove(path) then

            removed = removed + 1
         end
      end
   end
   cache.statistics.pruned =
   cache.statistics.pruned + removed
   return removed
end

storage.default_max_bytes = DEFAULT_MAX_BYTES
storage.process_identity = process_identity
storage.version = MANIFEST_VERSION

return storage
