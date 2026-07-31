local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local io = _tl_compat and _tl_compat.io or io; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local os = _tl_compat and _tl_compat.os or os; local package = _tl_compat and _tl_compat.package or package; local pairs = _tl_compat and _tl_compat.pairs or pairs; local pcall = _tl_compat and _tl_compat.pcall or pcall; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table




local common = require("tlcli.common")
local project_cache = require("tlcli.project_cache")

local teal = require("teal.init")
local compiler_artifacts =
require("teal.internal.compiler_artifacts")



local driver = {}


local compiler_caches = setmetatable(
{},
{ __mode = "k" })


local function warning_options_key(
   warnings)

   local names = {}
   for name, enabled in pairs(warnings or {}) do
      if enabled then
         table.insert(names, name)
      end
   end
   table.sort(names)
   return tostring(
   warnings and warnings["\0cache-all"] == true) ..
   "\0" .. table.concat(names, "\0")
end

local function compiler_options_key(
   tlconfig,
   cache_mode,
   cache_variant)

   return table.concat({
      cache_mode or "",
      cache_variant or "",
      tlconfig["feat_arity"] or "",
      tlconfig["gen_compat"] or "",
      tlconfig["gen_target"] or "",
      tostring(tlconfig["no_stdlib"] == true),
      table.concat(tlconfig._init_env_modules or {}, "\0"),
      warning_options_key(
      tlconfig._disabled_warnings_set),

      warning_options_key(
      tlconfig._warning_errors_set),

   }, "\0")
end

local function filename_to_module_name(filename)
   local path = os.getenv("TL_PATH") or package.path
   for path_entry in path:gmatch("[^;]+") do
      local entry = path_entry:gsub("%.", "%%.")
      local lua_pat = "^" .. entry:gsub("%?", ".+") .. "$"
      local d_tl_pat = lua_pat:gsub("%%.lua%$", "%%.d%%.tl$")
      local tl_pat = lua_pat:gsub("%%.lua%$", "%%.tl$")

      for _, pat in ipairs({ tl_pat, d_tl_pat, lua_pat }) do
         local cap = filename:match(pat)
         if cap then
            return (cap:gsub("[/\\]", "."))
         end
      end
   end


   return (filename:gsub("%.lua$", ""):gsub("%.d%.tl$", ""):gsub("%.tl$", ""):gsub("[/\\]", "."))
end

function driver.setup_compiler(
   tlconfig,
   cache_mode,
   cache_variant)

   tlconfig._init_env_modules = tlconfig._init_env_modules or {}
   if tlconfig.global_env_def and
      tlconfig._init_env_modules[1] ~=
      tlconfig.global_env_def then

      table.insert(tlconfig._init_env_modules, 1, tlconfig.global_env_def)
   end

   local opts = {
      feat_arity = tlconfig["feat_arity"],
      gen_compat = tlconfig["gen_compat"],
      gen_target = tlconfig["gen_target"],
      no_stdlib = tlconfig["no_stdlib"] == true,
   }

   if (opts.gen_target == "5.4" or opts.gen_target == "5.5") and opts.gen_compat ~= "off" then
      common.die("gen-compat must be explicitly 'off' when gen-target is '5.4' or '5.5'")
   end

   local compiler = teal.compiler(opts)
   local cache
   if cache_mode == "check" or cache_mode == "gen" then
      cache = project_cache.open({
         mode = cache_mode,
         options_key = compiler_options_key(
         tlconfig,
         cache_mode,
         cache_variant),

      })
      if cache:is_enabled() then
         compiler_artifacts.attach(
         compiler,
         cache)

         compiler_caches[compiler] = cache
      end
   end

   for _, name in ipairs(tlconfig._init_env_modules) do
      local _, _, err = compiler:require(name)
      if err then
         common.die("Error: " .. err)
      end
   end
   if cache and cache:is_enabled() then
      local environment_files = {}
      for filename in compiler:loaded_files() do
         table.insert(environment_files, filename)
      end
      pcall(cache.bind_environment, cache, environment_files)
   end

   return compiler
end

local function roots_for(filenames)
   local roots = {}
   for _, filename in ipairs(filenames) do
      if filename == "-" then
         return nil
      end
      table.insert(roots, {
         filename = filename,
         module_name = filename_to_module_name(filename),
      })
   end
   return roots
end

function driver.prepare_compiler(
   compiler,
   filenames)

   local cache = compiler_caches[compiler]
   if not cache then
      return
   end
   local roots = roots_for(filenames)
   if not roots then
      return
   end
   cache.project_roots = roots
   pcall(cache.restore_project, cache, compiler, roots)
end

function driver.prepare_generation(
   compiler,
   filenames)

   local cache = compiler_caches[compiler]
   if not cache then
      return nil, false
   end
   local roots = roots_for(filenames)
   if not roots then
      return nil, false
   end
   cache.generation_roots = roots
   local has_diagnostics = false
   local ok
   local outputs
   ok, outputs, has_diagnostics = pcall(
   cache.load_generated,
   cache,
   compiler,
   roots)

   if ok and outputs and not has_diagnostics then
      return outputs, true
   end
   cache.project_roots = roots
   pcall(cache.restore_project, cache, compiler, roots)
   if has_diagnostics and
      not cache.project_restore_succeeded then

      return {}, false
   elseif outputs then
      return outputs, false
   end
   ok, outputs = pcall(
   cache.load_partial_generated,
   cache,
   compiler,
   roots)

   return ok and outputs or {}, false
end

function driver.generation_requires_full_rebuild(
   compiler)

   local cache = compiler_caches[compiler]
   return cache and
   cache:generation_requires_full_rebuild(compiler) or
   false
end

function driver.prepare_full_generation(
   compiler,
   filenames)

   local cache = compiler_caches[compiler]
   if not cache then
      return
   end
   local roots = roots_for(filenames)
   if not roots then
      return
   end
   cache.generation_roots = roots
   cache.project_roots = roots
end

function driver.finish_compiler(
   compiler,
   generated_outputs)

   local cache = compiler_caches[compiler]
   if cache then
      if cache.project_roots then
         pcall(
         cache.put_project,
         cache,
         compiler,
         cache.project_roots)

      end
      if cache.generation_roots and generated_outputs then
         pcall(
         cache.put_generated,
         cache,
         compiler,
         cache.generation_roots,
         generated_outputs)

      end
      pcall(cache.flush, cache)
      compiler_caches[compiler] = nil
   end
end

local function already_loaded(compiler, input_file)
   input_file = common.normalize(input_file)
   for file in compiler:loaded_files() do
      if common.normalize(file) == input_file then
         return compiler:recall(file)
      end
   end
end

function driver.process_module(compiler, filename)
   local module, check_err = already_loaded(compiler, filename)
   if module then
      return module, check_err
   end

   local is_stdin = filename == "-"
   local module_name
   local input
   local err

   if is_stdin then
      module_name = "stdin"
      input, err = compiler:input(io.input():read("*a"), "<stdin>")
   else
      module_name = filename_to_module_name(filename)
      input, err = compiler:open(filename)
   end
   if err then
      return nil, nil, err
   end

   local checked_module, checked_err = input:check(module_name)
   return checked_module, checked_err
end

return driver
