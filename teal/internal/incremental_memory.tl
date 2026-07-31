local type incremental_contract =
   require("teal.internal.incremental_contract")

local record incremental_memory
   record Store
      get_parse: function(
         self: Store,
         filename: string,
         source: string,
         flavor: string
      ): any, {any}, {string}
      put_parse: function(
         self: Store,
         filename: string,
         source: string,
         flavor: string,
         ast: any,
         syntax_errors: {any},
         required_modules: {string}
      )
      record_result: function(
         self: Store,
         filename: string,
         dependencies: {string:string}
      )
      invalidate: function(
         self: Store,
         filename: string,
         affected: {string}
      )
      put_checked: function(
         self: Store,
         filename: string,
         source: string,
         result: any,
         typeid_ctr: integer,
         typevar_ctr: integer
      )
      load_checked: function(
         self: Store,
         filename: string,
         module_name: string,
         source: string,
         resolve_module: function(
            module_name: string
         ): string, string
      ): {incremental_contract.CachedResult}
      stats: function(self: Store): {string:integer}

      -- private:
      objects: {string:{string:{string:any}}}
      hits: integer
      misses: integer
      writes: integer
   end

   new: function(): Store
end

local Store = incremental_memory.Store
local Store_mt: metatable<Store> = {
   __index = Store,
}

local function clone_graph(value: any, seen?: {any:any}): any
   if type(value) ~= "table" then
      return value
   end
   seen = seen or {}
   local previous = seen[value]
   if previous then
      return previous
   end

   local copy: {any:any} = {}
   seen[value] = copy
   for key, item in pairs(value as {any:any}) do
      copy[clone_graph(key, seen)] = clone_graph(item, seen)
   end
   return setmetatable(copy, getmetatable(value))
end

local function copy_array(values: {any}): {any}
   local copy: {any} = {}
   for i, value in ipairs(values or {}) do
      copy[i] = value
   end
   return copy
end

function Store:get_parse(
   filename: string,
   source: string,
   flavor: string
): any, {any}, {string}
   local by_flavor = self.objects[filename]
   local by_source = by_flavor and by_flavor[flavor]
   local object: {string:any} =
      by_source and by_source[source] as {string:any}
   if not object then
      self.misses = self.misses + 1
      return nil
   end
   self.hits = self.hits + 1
   return clone_graph(object.ast),
      copy_array(object.syntax_errors as {any}),
      copy_array(object.required_modules as {any}) as {string}
end

function Store:put_parse(
   filename: string,
   source: string,
   flavor: string,
   ast: any,
   syntax_errors: {any},
   required_modules: {string}
)
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
   _filename: string,
   _dependencies: {string:string}
)
end

function Store:invalidate(
   filename: string,
   _affected: {string}
)
   self.objects[filename] = nil
end

function Store:put_checked(
   _filename: string,
   _source: string,
   _result: any,
   _typeid_ctr: integer,
   _typevar_ctr: integer
)
end

function Store:load_checked(
   _filename: string,
   _module_name: string,
   _source: string,
   _resolve_module: function(
      module_name: string
   ): string, string
): {incremental_contract.CachedResult}
   return nil
end

function Store:stats(): {string:integer}
   return {
      hits = self.hits,
      misses = self.misses,
      writes = self.writes,
   }
end

function incremental_memory.new(): Store
   return setmetatable({
      objects = {},
      hits = 0,
      misses = 0,
      writes = 0,
   }, Store_mt)
end

return incremental_memory
