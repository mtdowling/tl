local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local pairs = _tl_compat and _tl_compat.pairs or pairs; local check = require("teal.check.check")
local environment = require("teal.environment")

local errors = require("teal.errors")
local incremental = require("teal.incremental")
local compiler_state =
require("teal.internal.compiler_state")

local incremental_memory = require("teal.internal.incremental_memory")
local lexer = require("teal.lexer")
local loader = require("teal.loader")
local lua_compat = require("teal.gen.lua_compat")
local lua_generator = require("teal.gen.lua_generator")
local package_loader = require("teal.package_loader")
local parser = require("teal.parser")
local require_file = require("teal.check.require_file")
local targets = require("teal.gen.targets")

local util = require("teal.util")

local teal = { CheckError = {}, FileResult = {}, RecheckBatch = {}, Compiler = {}, Input = {}, TokenList = {}, ParseTree = {}, Module = {}, CompilerOptions = {} }





































































































































local Compiler = teal.Compiler
local Module = teal.Module




local Input = teal.Input


local ParseTree = teal.ParseTree


local TokenList = teal.TokenList




local Compiler_mt = { __index = Compiler }
local Input_mt = { __index = Input }
local TokenList_mt = { __index = TokenList }
local ParseTree_mt = { __index = ParseTree }
local Module_mt = { __index = Module }

local function attach_environment(
   value,
   env)

   compiler_state.set(value, env)
   return value
end

local function pipeline_environment(value)
   return compiler_state.get(value)
end

environment.set_require_module_fn(require_file.require_module)
environment.set_resolve_module_fn(require_file.resolve_module)





local function module_from_result(result)
   local parse_tree = attach_environment(
   setmetatable({
      filename = result.filename,
      ast = result.ast,
      required_modules = util.sorted_keys(result.dependencies),
      syntax_errors = result.syntax_errors,
   }, ParseTree_mt),
   result.env)

   local module = attach_environment(setmetatable({
      filename = result.filename,
      parse_tree = parse_tree,
   }, Module_mt), result.env)

   local check_error = {
      syntax_errors = result.syntax_errors or {},
      type_errors = result.type_errors or {},
      warnings = result.warnings or {},
   }

   return module, check_error
end





function Compiler:input(teal_code, filename)
   if teal_code == nil then
      return nil, "missing Teal code as input"
   end
   return attach_environment(setmetatable({
      filename = filename or "<input>.tl",
      teal_code = teal_code,
   }, Input_mt), pipeline_environment(self))
end

function Compiler:open(filename)
   local env = pipeline_environment(self)
   local teal_code, read_err =
   environment.read_source(env, filename)
   if not teal_code then
      return nil, "could not open " .. read_err
   end

   return self:input(teal_code, filename)
end

function Compiler:require(module_name)
   local env = pipeline_environment(self)
   local ok, err = environment.load_module(env, module_name)
   if not ok then
      return nil, nil, err
   end

   local filename = env.module_filenames[module_name]
   local result = env.loaded[filename]
   return module_from_result(result)
end

function Compiler:set_source_provider(provider)
   local env = pipeline_environment(self)
   env.session:set_source_provider(provider)
end

function Compiler:update(
   filename,
   source)

   local env = pipeline_environment(self)
   return env.session:update(filename, source)
end

function Compiler:affected(filename)
   local env = pipeline_environment(self)
   return env.session:affected(filename)
end

function Compiler:invalidate(filename)
   local env = pipeline_environment(self)
   return env.session:invalidate(filename)
end

function Compiler:recheck(change)
   return pipeline_environment(self).session:recheck(
   change,
   self)

end

function Compiler:enable_type_reporting(enable)
   local env = pipeline_environment(self)
   env.keep_going = enable
   env.report_types = enable
end

function Compiler:get_type_report()
   local env = pipeline_environment(self)
   if not env.reporter then
      return nil
   end

   return env.reporter:get_report()
end

function Compiler:loaded_files()
   local env = pipeline_environment(self)
   local i = 0
   return function()
      i = i + 1
      local filename = env.loaded_order[i]
      local result = filename and env.loaded[filename]
      return result and result.filename
   end
end

function Compiler:recall(filename)
   local env = pipeline_environment(self)
   local result = env.loaded[filename]
   if not result then
      filename = env.session:normalize_filename(filename)
      result = env.loaded[filename]
   end
   if not result then
      return nil, nil
   end
   if result.ast then
      lua_compat.apply(result)
   end
   return module_from_result(result)
end





function Input:lex()
   local env = pipeline_environment(self)
   local tokens, errs = lexer.lex(self.teal_code, self.filename)
   return attach_environment(setmetatable({
      filename = self.filename,
      tokens = tokens,
      lexical_errors = errs,
   }, TokenList_mt), env), errs
end

function Input:parse()
   local env = pipeline_environment(self)
   local fresh_tree
   local fresh_error
   local function parse_source()
      local token_list = self:lex()
      fresh_tree, fresh_error = token_list:parse()
      return fresh_tree.ast,
      fresh_tree.syntax_errors,
      fresh_tree.required_modules
   end

   local ast, errs, required_modules, cached =
   env.session:parse(
   self.filename,
   self.teal_code,
   "program",
   parse_source)

   if not cached then
      return fresh_tree, fresh_error
   end
   if #errs > 0 and not env.keep_going then
      environment.register_failed(env, self.filename, errs)
   end
   return attach_environment(setmetatable({
      filename = self.filename,
      required_modules = required_modules,
      ast = ast,
      syntax_errors = errs,
   }, ParseTree_mt), env), #errs > 0 and errs or nil
end

function Input:check(module_name)
   local env = pipeline_environment(self)
   env.session:remember_root(
   self.filename,
   module_name)

   if module_name then
      local cached = env.session:restore_checked(
      self.filename,
      module_name,
      self.teal_code)

      if cached then
         return module_from_result(
         cached)

      end
   end

   local parse_tree, parse_error = self:parse()

   if parse_error and not env.keep_going then
      return nil, {
         syntax_errors = parse_error,
         type_errors = {},
         warnings = {},
      }
   end

   return parse_tree:check(module_name)
end

function Input:gen(opts)
   local module, check_error = self:check()
   if #check_error.syntax_errors > 0 then
      return nil, module, check_error
   end
   local output = module:gen(opts)
   return output, module, check_error
end





function TokenList:get_token_at(line, column)
   return lexer.get_token_at(self.tokens, line, column)
end

function TokenList:parse()
   local env = pipeline_environment(self)
   local errs = self.lexical_errors or {}
   local ast, required_modules = parser.parse_program(self.tokens, errs, self.filename)

   if #errs > 0 and not env.keep_going then
      environment.register_failed(env, self.filename, errs)
   end

   return attach_environment(setmetatable({
      filename = self.filename,
      required_modules = required_modules,
      ast = ast,
      syntax_errors = errs,
   }, ParseTree_mt), env), #errs > 0 and errs or nil
end





function ParseTree:check(module_name)
   local env = pipeline_environment(self)
   env.session:remember_root(
   self.filename,
   module_name)

   if #self.syntax_errors > 0 and not env.keep_going then
      local filename =
      env.session:normalize_filename(self.filename)
      local result = env.loaded[filename]
      local _, check_err = module_from_result(result)
      return nil, check_err
   end

   local result = check.check(self.ast, env, self.filename)
   if result then
      result.syntax_errors = self.syntax_errors

      if result.ast then
         lua_compat.apply(result)
      end

      if module_name then
         env.session:bind_module(
         self.filename,
         module_name,
         result)

      end
   end

   return module_from_result(result)
end





function Module:gen(opts)
   local env = pipeline_environment(self)
   return lua_generator.generate(
   self.parse_tree.ast,
   env.opts.gen_target,
   opts)

end





function teal.compiler(opts)
   local compiler = setmetatable({}, Compiler_mt)

   local env_opts = {
      feat_arity = opts and opts.feat_arity,
      gen_compat = opts and opts.gen_compat,
      gen_target = opts and opts.gen_target,
      no_stdlib = opts and not not opts.no_stdlib,
   }

   local env = environment.new(env_opts)
   local store = opts and opts.incremental and
   incremental_memory.new() or

   nil
   env.session = incremental.new(env, store)
   compiler_state.set(compiler, env)

   return compiler
end

teal.load = loader.load

function teal.loader()
   package_loader.install_loader()
end

function teal.search_module(module_name, extension_set)
   local found, _, tried = require_file.search_module(module_name, extension_set)
   if not found then
      return nil, tried
   end
   return found
end

teal.runtime_target = targets.detect

function teal.warning_set()
   local warning_set = {}
   for k, v in pairs(errors.warning_kinds) do
      warning_set[k] = v
   end
   return warning_set
end

function teal.version()
   return environment.VERSION
end

return teal
