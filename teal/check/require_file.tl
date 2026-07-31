local input = require("teal.input")

local type errors = require("teal.errors")
local type Where = errors.Where

local types = require("teal.types")
local type Type = types.Type
local type TypeDeclType = types.TypeDeclType
local a_type = types.a_type

local type environment = require("teal.environment")
local type Env = environment.Env
local type Result = environment.Result

local record require_file
   enum Extension
      ".d.tl"
      ".tl"
      ".lua"
   end

   all_extensions: {Extension:boolean}
end

local type Extension = require_file.Extension
local type ReadSourceFn = function(filename: string): string, string

require_file.all_extensions = {
   [".d.tl"] = true,
   [".tl"] = true,
   [".lua"] = true,
}

local function read_file(filename: string): string, string
   local fd, open_err = io.open(filename, "rb")
   if not fd then
      return nil, open_err
   end
   local source, read_err = fd:read("*a")
   fd:close()
   return source, read_err
end

local function search_for(
   module_name: string,
   suffix: string,
   path: string,
   tried: {string},
   read_source: ReadSourceFn
): string, string, {string}
   for entry in path:gmatch("[^;]+") do
      local slash_name = module_name:gsub("%.", "/")

      -- skip the `init.lua` entries from the path; we handle them ourselves
      if not entry:match("%?[/\\]init%.lua$") then
         local filename = entry:gsub("?", slash_name)
         local tl_filename = filename:gsub("%.lua$", suffix)
         local code = read_source(tl_filename)
         if not code then
            table.insert(tried, "no file '" .. tl_filename .. "'")

            -- if the plain entry wasn't found, try the `init` entry
            tl_filename = filename:gsub("%.lua$", "/init" .. suffix)
            code = read_source(tl_filename)
            if not code then
               table.insert(tried, "no file '" .. tl_filename .. "'")
            end
         end

         if code then
            return tl_filename, code, tried
         end
      end
   end
   return nil, nil, tried
end

function require_file.search_module(
   module_name: string,
   extension_set?: {Extension:boolean},
   read_source?: ReadSourceFn
): string, string, {string}
   local found: string
   local code: string
   local tried: {string} = {}
   local path = os.getenv("TL_PATH") or package.path
   read_source = read_source or read_file

   if extension_set and extension_set[".d.tl"] then
      found, code, tried =
         search_for(module_name, ".d.tl", path, tried, read_source)
      if found then
         return found, code
      end
   end
   if (not extension_set) or extension_set[".tl"] then
      found, code, tried =
         search_for(module_name, ".tl", path, tried, read_source)
      if found then
         return found, code
      end
   end
   if extension_set and extension_set[".lua"] then
      found, code, tried =
         search_for(module_name, ".lua", path, tried, read_source)
      if found then
         return found, code
      end
   end
   return nil, nil, tried
end

local function a_circular_require(w: Where): TypeDeclType
   return a_type(w, "typedecl", { def = a_type(w, "circular_require", {}) } as TypeDeclType)
end

function require_file.search_and_load(env: Env, module_name: string, extension_set?: {Extension:boolean}): Result, string, {string}
   local function read_source(filename: string): string, string
      return environment.read_source(env, filename)
   end
   local found, code, tried =
      require_file.search_module(module_name, extension_set, read_source)
   if not found then
      return nil, nil, tried
   end

   local cached = env.session and
      env.session:restore_checked(found, module_name, code)
   if cached then
      return cached as Result, found
   end

   env.module_filenames[module_name] = env.session
      and env.session:normalize_filename(found)
      or found

   local w = { f = found, x = 1, y = 1 }
   env.modules[module_name] = a_circular_require(w)

   local found_result = input.check(env, found, code)
   if not found_result then
      return nil, nil, tried
   end

   if env.session then
      env.session:bind_module(found, module_name, found_result)
   else
      env.modules[module_name] = found_result.type
   end

   return found_result, found
end

function require_file.resolve_module(
   env: Env,
   module_name: string
): string, string
   local function read_source(filename: string): string, string
      return environment.read_source(env, filename)
   end
   local filename, source = require_file.search_module(
      module_name,
      require_file.all_extensions,
      read_source
   )
   return filename, source
end

function require_file.require_module(env: Env, module_name: string): Type, string
   local mod = env.modules[module_name]
   if mod then
      return mod, env.module_filenames[module_name]
   end

   local extensions = require_file.all_extensions
   local found_result, found = require_file.search_and_load(env, module_name, extensions)
   if not found_result then
      return nil
   end

   return found_result.type, found
end

return require_file
