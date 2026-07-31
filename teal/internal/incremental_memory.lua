local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local pairs = _tl_compat and _tl_compat.pairs or pairs


local incremental_memory = { Store = {} }























































local Store = incremental_memory.Store
local Store_mt = {
   __index = Store,
}

local function clone_graph(value, seen)
   if type(value) ~= "table" then
      return value
   end
   seen = seen or {}
   local previous = seen[value]
   if previous then
      return previous
   end

   local copy = {}
   seen[value] = copy
   for key, item in pairs(value) do
      copy[clone_graph(key, seen)] = clone_graph(item, seen)
   end
   return setmetatable(copy, getmetatable(value))
end

local function copy_array(values)
   local copy = {}
   for i, value in ipairs(values or {}) do
      copy[i] = value
   end
   return copy
end

function Store:get_parse(
   filename,
   source,
   flavor)

   local by_flavor = self.objects[filename]
   local by_source = by_flavor and by_flavor[flavor]
   local object =
   by_source and by_source[source]
   if not object then
      self.misses = self.misses + 1
      return nil
   end
   self.hits = self.hits + 1
   return clone_graph(object.ast),
   copy_array(object.syntax_errors),
   copy_array(object.required_modules)
end

function Store:put_parse(
   filename,
   source,
   flavor,
   ast,
   syntax_errors,
   required_modules)

   if #syntax_errors > 0 then
      return
   end
   local by_flavor = self.objects[filename]
   if not by_flavor then
      by_flavor = {}
      self.objects[filename] = by_flavor
   end
   local by_source = by_flavor[flavor]
   if not by_source then
      by_source = {}
      by_flavor[flavor] = by_source
   end
   if not by_source[source] then
      self.writes = self.writes + 1
   end
   by_source[source] = {
      ast = clone_graph(ast),
      syntax_errors = copy_array(syntax_errors),
      required_modules = copy_array(required_modules),
   }
end

function Store:record_result(
   _filename,
   _dependencies)

end

function Store:invalidate(
   filename,
   _affected)

   self.objects[filename] = nil
end

function Store:put_checked(
   _filename,
   _source,
   _result,
   _typeid_ctr,
   _typevar_ctr)

end

function Store:load_checked(
   _filename,
   _module_name,
   _source,
   _resolve_module)



   return nil
end

function Store:stats()
   return {
      hits = self.hits,
      misses = self.misses,
      writes = self.writes,
   }
end

function incremental_memory.new()
   return setmetatable({
      objects = {},
      hits = 0,
      misses = 0,
      writes = 0,
   }, Store_mt)
end

return incremental_memory
