--------------------------------------------------------------------------------
-- tl gen
--------------------------------------------------------------------------------

local common = require("tlcli.common")
local driver = require("tlcli.driver")
local perf = require("tlcli.perf")
local report = require("tlcli.report")
local lfs = require("lfs")

local type TlConfig = require("tlcli.tlconfig")
local type Args = require("tlcli.args")

local type teal = require("teal")
local type GenOptions = teal.GenOptions

local record GeneratedModule
   cached_output: string
   check_err: teal.CheckError
   input_file: string
   module: teal.Module
   output_file: string
end

local mkdir_cache = {}

local function make_dir_for(pathname: string)
   local normalized, root = common.normalize(pathname)
   local dirname = normalized:match("^(.*" .. common.sep .. ")[^" .. common.sep .. "]+$")
   -- on Windows, root contains the drive letter and looks like `D:\`
   if dirname == root then
      return
   end
   if dirname then
      if mkdir_cache[dirname] then
         return
      end
      make_dir_for(dirname)
      lfs.mkdir(dirname)
      mkdir_cache[dirname] = true
   end
end

local function write_out(
   tlconfig: TlConfig,
   lua_code: string,
   output_file: string,
   tree: boolean
)
   local is_stdout = output_file == "-"
   local prettyname = is_stdout and "<stdout>" or output_file
   if tlconfig["pretend"] then
      print("Would Write: " .. prettyname)
      return
   end

   local ofd, err: FILE, string
   if is_stdout then
      ofd = io.output()
   else
      if tree then
         make_dir_for(output_file)
      end
      ofd, err = io.open(output_file, "wb")
      if not ofd then
         common.die("cannot write " .. prettyname .. ": " .. err)
      end
   end

   local _: FILE
   _, err = ofd:write(lua_code, "\n")
   if err then
      common.die("error writing " .. prettyname .. ": " .. err)
   end

   if not is_stdout then
      ofd:close()
   end

   if not tlconfig["quiet"] then
      print("Wrote: " .. prettyname)
   end
end

return function(tlconfig: TlConfig, args: Args)
   if args["output"] and #args["file"] ~= 1 then
      print("Error: --output can only be used to map one input to one output")
      os.exit(1)
   end

   perf.turbo(true)

   local cacheable = not args["no_check"]
      and not tlconfig["pretend"]
   for _, input_file in ipairs(args["file"]) do
      if input_file == "-" then
         cacheable = false
      end
   end

   local gen_opts: GenOptions = {
      preserve_indent = true,
      preserve_newlines = true,
      preserve_hashbang = args["keep_hashbang"]
   }

   local mods: {GeneratedModule}
   local compiler: teal.Compiler
   local cached_outputs: {string}
   local force_full_generation = false
   while true do
      compiler = driver.setup_compiler(
         tlconfig,
         cacheable and "gen" or nil,
         tostring(not not args["keep_hashbang"])
      )
      local complete_cache_hit = false
      if cacheable then
         if force_full_generation then
            driver.prepare_full_generation(
               compiler,
               args["file"]
            )
            cached_outputs = nil
         else
            cached_outputs, complete_cache_hit =
               driver.prepare_generation(
                  compiler,
                  args["file"]
               )
         end
      end
      if complete_cache_hit then
         for i, input_file in ipairs(args["file"]) do
            local output_file =
               common.get_output_filename(
                  input_file,
                  args["root"],
                  args["output_dir"],
                  args["custom_ext"]
               )
            write_out(
               tlconfig,
               cached_outputs[i],
               args["output"] or output_file,
               not not args["root"]
            )
         end
         driver.finish_compiler(compiler)
         os.exit(0)
      end

      mods = {}
      local rebuild = false
      for i, input_file in ipairs(args["file"]) do
         local output_file = common.get_output_filename(
            input_file,
            args["root"],
            args["output_dir"],
            args["custom_ext"]
         )
         if cached_outputs and cached_outputs[i] then
            table.insert(mods, {
               cached_output = cached_outputs[i],
               input_file = input_file,
               output_file = output_file,
               check_err = {
                  syntax_errors = {},
                  type_errors = {},
                  warnings = {},
               },
            })
         else
            local module, check_err, err =
               driver.process_module(
                  compiler,
                  input_file
               )
            if err then
               common.die(err)
            end

            table.insert(mods, {
               input_file = input_file,
               output_file = output_file,
               module = module,
               check_err = check_err,
            })
            perf.check_collect(i)
            if cached_outputs
               and driver.generation_requires_full_rebuild(
                  compiler
               )
            then
               rebuild = true
               break
            end
         end
      end
      if not rebuild then
         break
      end
      driver.finish_compiler(compiler)
      force_full_generation = true
   end

   local generated_outputs: {string} = {}
   for i, mod in ipairs(mods) do
      local err = mod.check_err
      if #err.syntax_errors == 0 and (args["no_check"] or #err.type_errors == 0) then
         local output_filename = args["output"] or mod.output_file
         if tlconfig["pretend"] then
            write_out(
               tlconfig,
               "",
               output_filename,
               not not args["root"]
            )
         else
            local lua_code = mod.cached_output
            if not lua_code then
               assert(mod.module)
               lua_code = mod.module:gen(gen_opts)
            end
            generated_outputs[i] = lua_code
            write_out(
               tlconfig,
               lua_code,
               output_filename,
               not not args["root"]
            )
         end
      end
   end

   local ok = report.report_all_errors(tlconfig, compiler, args["no_check"])
   if cacheable and ok then
      driver.finish_compiler(compiler, generated_outputs)
   else
      driver.finish_compiler(compiler)
   end

   os.exit(ok and 0 or 1)
end
