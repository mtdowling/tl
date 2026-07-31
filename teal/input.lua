local check = require("teal.check.check")

local parser = require("teal.parser")





local environment = require("teal.environment")



local input = {}


function input.check(env, filename, code)
   local loaded_filename = filename
   if env.session then
      loaded_filename = env.session:normalize_filename(filename)
   end
   if env.loaded and env.loaded[loaded_filename] then
      return env.loaded[loaded_filename]
   end

   local program
   local syntax_errors
   local function parse_source()
      local ast, errs, required = parser.parse(code, filename)
      return ast, errs, required
   end
   if env.session then
      program, syntax_errors = env.session:parse(
      filename,
      code,
      "reader",
      parse_source)

   else
      program, syntax_errors = parse_source()
   end

   if (not env.keep_going) and #syntax_errors > 0 then
      return environment.register_failed(env, filename, syntax_errors)
   end

   local result = check.check(program, env, filename)

   result.syntax_errors = syntax_errors

   return result
end

return input
