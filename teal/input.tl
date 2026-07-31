local check = require("teal.check.check")

local parser = require("teal.parser")
local type Node = parser.Node

local type errors = require("teal.errors")
local type Error = errors.Error

local type environment = require("teal.environment")
local type Env = environment.Env
local type Result = environment.Result

local record input
end

function input.check(env: Env, filename: string, code: string): Result
   local loaded_filename = filename
   if env.session then
      loaded_filename = env.session:normalize_filename(filename)
   end
   if env.loaded and env.loaded[loaded_filename] then
      return env.loaded[loaded_filename]
   end

   local program: any
   local syntax_errors: {Error}
   local function parse_source(): Node, {Error}, {string}
      local ast, errs, required = parser.parse(code, filename)
      return ast as Node, errs, required
   end
   if env.session then
      program, syntax_errors = env.session:parse(
         filename,
         code,
         "reader",
         parse_source
      )
   else
      program, syntax_errors = parse_source()
   end

   if (not env.keep_going) and #syntax_errors > 0 then
      return environment.register_failed(env, filename, syntax_errors)
   end

   local result = check.check(program as Node, env, filename)

   result.syntax_errors = syntax_errors

   return result
end

return input
