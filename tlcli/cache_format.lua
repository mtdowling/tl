local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local debug = _tl_compat and _tl_compat.debug or debug; local io = _tl_compat and _tl_compat.io or io; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local load = _tl_compat and _tl_compat.load or load; local math = _tl_compat and _tl_compat.math or math; local _tl_math_maxinteger = math.maxinteger or math.pow(2, 53); local _tl_math_mininteger = math.mininteger or -math.pow(2, 53); local package = _tl_compat and _tl_compat.package or package; local pcall = _tl_compat and _tl_compat.pcall or pcall; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local debug = debug
local io = io
local ipairs = ipairs
local load = load
local math = math
local next = next
local package = package
local pcall = pcall
local rawget = rawget
local require = require
local setmetatable = setmetatable
local string = string
local table = table
local tostring = tostring
local type = type

















local cache_format = {}
local environment = require("teal.environment")
local lfs = require("lfs")
local initial_directory = lfs.currentdir()
local compiler_version = environment.VERSION

local MAGIC = "TLBCODE\0"
local VERSION = 2
local BACKEND_BYTECODE = 0
local BACKEND_BYTECODE_AST = 2

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_FINGERPRINT_BYTES = 64 * 1024
local MAX_OBJECTS = 1000000
local MAX_ENTRIES = 16000000
local MAX_SOURCE_BYTES = 512 * 1024 * 1024
local MAX_PAYLOAD_BYTES = 512 * 1024 * 1024
local CHECKSUM_BYTES = 16























local globals = _G
local loadstring = globals.loadstring
local setfenv = globals.setfenv
local jit_runtime = globals.jit
local native_math = globals.math
local native_string = globals.string
local math_type = native_math.type

cache_format.version = VERSION
cache_format.compiler_version = compiler_version

local function encode_error(message)
   error("cannot encode Teal bytecode cache: " .. message, 0)
end

local function protected_call(
   fn,
   ...)

   if jit_runtime then
      jit_runtime.on()
   end
   local ok, result, extra = pcall(fn, ...)
   if jit_runtime then
      jit_runtime.off()
   end
   return ok, result, extra
end

local function decode_error(message)
   error("invalid Teal bytecode cache: " .. message, 0)
end

local function load_chunk(
   data,
   name,
   mode)

   if loadstring then
      local chunk, err = loadstring(data, name)
      if chunk and setfenv then
         setfenv(chunk, {})
      end
      return chunk, err
   end
   return load(data, name, mode, {})
end

local function runtime_probe()
   return 719
end

local function dump_function(fn)
   local ok, result = pcall(string.dump, fn, true)
   if ok then
      return result
   end
   return string.dump(fn)
end

local function hex32(value)
   local high = math.floor(value / 65536)
   local low = math.floor(value % 65536)
   return string.format("%04x%04x", high, low)
end

local native_digest
if math_type and native_string.pack then
   local digest_loader = load([[
      return function(value)
         local h1 = 0xcbf29ce484222325
         local h2 = 0x6c62272e07bb0142
         local length = #value
         local i = 1
         while i + 7 <= length do
            local b1, b2, b3, b4, b5, b6, b7, b8 =
               value:byte(i, i + 7)
            h1 = (h1 ~ b1) * 0x100000001b3
            h1 = (h1 ~ b2) * 0x100000001b3
            h1 = (h1 ~ b3) * 0x100000001b3
            h1 = (h1 ~ b4) * 0x100000001b3
            h1 = (h1 ~ b5) * 0x100000001b3
            h1 = (h1 ~ b6) * 0x100000001b3
            h1 = (h1 ~ b7) * 0x100000001b3
            h1 = (h1 ~ b8) * 0x100000001b3
            h2 = (h2 ~ b8) * 0x9e3779b185ebca87
            h2 = (h2 ~ b7) * 0x9e3779b185ebca87
            h2 = (h2 ~ b6) * 0x9e3779b185ebca87
            h2 = (h2 ~ b5) * 0x9e3779b185ebca87
            h2 = (h2 ~ b4) * 0x9e3779b185ebca87
            h2 = (h2 ~ b3) * 0x9e3779b185ebca87
            h2 = (h2 ~ b2) * 0x9e3779b185ebca87
            h2 = (h2 ~ b1) * 0x9e3779b185ebca87
            i = i + 8
         end
         while i <= length do
            local byte = value:byte(i)
            h1 = (h1 ~ byte) * 0x100000001b3
            h2 = (h2 ~ byte) * 0x9e3779b185ebca87
            i = i + 1
         end
         return string.pack("<i8i8", h1, h2)
      end
   ]], "@tl-cache-digest", "t", {
      string = native_string,
   })
   if digest_loader then
      native_digest = digest_loader()

   end
end

local function digest_bytes(value)
   if native_digest then
      return native_digest(value)
   end
   local h1 = 5381
   local h2 = 2166136261
   for i = 1, #value do
      local byte = string.byte(value, i)
      h1 = (h1 * 33 + byte) % 4294967296
      h2 = (h2 * 65599 + byte) % 4294967296
   end
   return hex32(h1) .. hex32(h2)
end

local function digest_hex(value)
   local bytes = digest_bytes(value)
   if not native_digest then
      return bytes
   end
   local out = {}
   for i = 1, #bytes do
      out[i] = string.format("%02x", string.byte(bytes, i))
   end
   return table.concat(out)
end

function cache_format.digest(value)
   local ok, result = protected_call(digest_hex, value)
   if not ok then
      return nil, result
   end
   return result
end

local function source_path(source)
   local path = source:sub(2)
   if path:sub(1, 1) ~= "/" and not path:match("^.:") then
      path = initial_directory ..
      package.config:sub(1, 1) ..
      path
   end
   return path
end

local function read_source_file(path)
   local fd = io.open(path, "rb")
   local contents = fd and fd:read("*a")
   if fd then
      fd:close()
   end
   return contents
end

local function collect_lua_files(
   directory,
   filenames)

   for basename in lfs.dir(directory) do
      if basename ~= "." and basename ~= ".." then
         local path = directory ..
         package.config:sub(1, 1) ..
         basename
         local attributes = lfs.symlinkattributes(path)
         if attributes and attributes.mode == "directory" then
            collect_lua_files(path, filenames)
         elseif attributes and
            attributes.mode == "file" and
            basename:match("%.lua$") then

            filenames[#filenames + 1] = path
         end
      end
   end
end

local function compiler_identity()
   local info = debug and debug.getinfo(environment.new, "S")
   local source = info and info.source
   if not source or source:sub(1, 1) ~= "@" then
      return digest_bytes(dump_function(environment.new))
   end

   local loaded_path = source_path(source)
   local loaded_source = read_source_file(loaded_path)
   local normalized_path = loaded_path:gsub("\\", "/")
   if not normalized_path:match("/teal/environment%.lua$") then
      return digest_bytes(
      loaded_source or dump_function(environment.new))

   end

   local teal_directory = loaded_path:match(
   "^(.*)[/\\]environment%.lua$")

   local filenames = {}
   local ok = pcall(collect_lua_files, teal_directory, filenames)
   if not ok then
      return digest_bytes(
      loaded_source or dump_function(environment.new))

   end

   table.sort(filenames)
   local sources = {}
   for _, filename in ipairs(filenames) do
      local contents = read_source_file(filename)
      if contents then
         sources[#sources + 1] = filename:sub(
         #teal_directory + 2)

         sources[#sources + 1] = contents
      end
   end
   if #sources == 0 then
      return digest_bytes(
      loaded_source or dump_function(environment.new))

   end
   return digest_bytes(table.concat(sources, "\0"))
end

local function runtime_fingerprint()
   local jit_version = jit_runtime and jit_runtime.version or ""
   return table.concat({
      _VERSION,
      "\0",
      jit_version,
      "\0",
      compiler_version,
      "\0",
      cache_format.compiler_identity,
      "\0",
      dump_function(runtime_probe),
   })
end

setmetatable(cache_format, {
   __index = function(self, key)
      local value
      if key == "compiler_identity" then
         value = compiler_identity()
      elseif key == "runtime_fingerprint" then
         value = runtime_fingerprint()
      end
      if value then
         rawset(self, key, value)
      end
      return value
   end,
})





local types_module
local function node_tostring(node)
   return tostring(node.f) ..
   ":" .. tostring(node.y) ..
   ":" .. tostring(node.x) ..
   " " .. tostring(node.kind)
end

local function type_tostring(type_value)
   if not types_module then
      types_module = require("teal.types")
   end
   return types_module.show_type(type_value)
end

local restored_node_metatable = {
   __tostring = node_tostring,
}
local restored_type_metatable = {
   __tostring = type_tostring,
}

local function append_varuint(out, value)
   if value < 0 or value > MAX_SAFE_INTEGER or value ~= math.floor(value) then
      encode_error("integer outside the varint range")
   end
   repeat
      local byte = value % 128
      value = math.floor(value / 128)
      if value > 0 then
         byte = byte + 128
      end
      out[#out + 1] = string.char(byte)
   until value == 0
end

local function number_expression(value)
   if value ~= value then
      return "(0/0)"
   elseif value == math.huge then
      return "(1/0)"
   elseif value == -math.huge then
      return "(-1/0)"
   elseif value == 0 and 1 / value < 0 then
      return "(-0.0)"
   elseif math_type and math_type(value) == "integer" then
      if _tl_math_mininteger and value == _tl_math_mininteger then
         return "(-" .. tostring(_tl_math_maxinteger) .. "-1)"
      end
      return tostring(value)
   end
   return string.format("%.17e", value)
end

local function intern_object(
   object_ids,
   objects,
   value)

   local id = object_ids[value]
   if not id then
      id = #objects + 1
      if id > MAX_OBJECTS then
         encode_error("too many objects")
      end
      object_ids[value] = id
      objects[id] = value
   end
   return id
end

local function capture_objects(
   root)

   local object_ids = {}
   local objects = {}
   local total_entries = 0

   if type(root) == "table" then
      intern_object(object_ids, objects, root)
   end

   local scan = 1
   while scan <= #objects do
      local object = objects[scan]
      if getmetatable(object) ~= nil then
         encode_error("object " .. tostring(scan) .. " has a metatable")
      end

      local key, value = next(object)
      while key ~= nil do
         total_entries = total_entries + 1
         if total_entries > MAX_ENTRIES then
            encode_error("too many object entries")
         end
         if type(key) == "table" then
            intern_object(
            object_ids,
            objects,
            key)

         end
         if type(value) == "table" then
            intern_object(
            object_ids,
            objects,
            value)

         end
         key, value = next(object, key)
      end
      scan = scan + 1
   end

   return object_ids, objects
end

local function value_expression(
   value,
   object_ids)

   if type(value) == "nil" then
      return "nil"
   elseif type(value) == "boolean" then
      return (value) and "true" or "false"
   elseif type(value) == "number" then
      return number_expression(value)
   elseif type(value) == "string" then
      return string.format("%q", value)
   elseif type(value) == "table" then
      return "o[" .. object_ids[value] .. "]"
   end
   encode_error("unsupported value type '" .. type(value) .. "'")
end

local function build_source(root)
   local object_ids, objects = capture_objects(root)
   local out = {
      "local o,t={}",
   }
   if #objects > 0 then
      out[#out + 1] = "for i=1," .. #objects .. " do o[i]={} end"
   end

   for id, object in ipairs(objects) do
      out[#out + 1] = "t=o[" .. id .. "]"
      local key, value = next(object)
      while key ~= nil do
         out[#out + 1] = "t[" ..
         value_expression(key, object_ids) ..
         "]=" ..
         value_expression(value, object_ids)
         key, value = next(object, key)
      end
   end

   out[#out + 1] = "return " .. value_expression(root, object_ids)
   local source = table.concat(out, "\n")
   if #source > MAX_SOURCE_BYTES then
      encode_error("generated builder is too large")
   end
   return source
end

local function clone_compiler_graph(root)
   if type(root) ~= "table" then
      return {
         root = root,
         nodes = {},
         types = {},
      }
   end

   local table_root = root
   local copies = {
      [table_root] = {},
   }
   local objects = { table_root }
   local nodes = {}
   local types = {}
   local scan = 1
   while scan <= #objects do
      local source = objects[scan]
      local target = copies[source]
      if rawget(source, "kind") ~= nil and
         rawget(source, "f") ~= nil and
         rawget(source, "x") ~= nil and
         rawget(source, "y") ~= nil then

         nodes[#nodes + 1] = target
      elseif rawget(source, "typename") ~= nil and
         rawget(source, "f") ~= nil then

         types[#types + 1] = target
      end

      local key, value = next(source)
      while key ~= nil do
         local copied_key = key
         if type(key) == "table" then
            local table_key = key
            copied_key = copies[table_key]
            if not copied_key then
               copied_key = {}
               copies[table_key] = copied_key
               objects[#objects + 1] = table_key
            end
         end

         local copied_value = value
         if type(value) == "table" then
            local table_value = value
            copied_value = copies[table_value]
            if not copied_value then
               copied_value = {}
               copies[table_value] = copied_value
               objects[#objects + 1] = table_value
            end
         end
         target[copied_key] = copied_value
         key, value = next(source, key)
      end
      scan = scan + 1
   end
   return {
      root = copies[table_root],
      nodes = nodes,
      types = types,
   }
end







local function restore_bytecode_ast(wrapper)
   if type(wrapper) ~= "table" then
      decode_error("invalid bytecode AST envelope")
   end

   local dynamic_wrapper = wrapper
   if type(dynamic_wrapper.root) ~= "table" or
      type(dynamic_wrapper.nodes) ~= "table" or
      type(dynamic_wrapper.types) ~= "table" then

      decode_error("invalid bytecode AST envelope")
   end

   local envelope = dynamic_wrapper
   for _, node in ipairs(envelope.nodes) do
      if type(node) ~= "table" then
         decode_error("invalid bytecode AST node list")
      end
      setmetatable(node, restored_node_metatable)
   end
   for _, type_value in ipairs(envelope.types) do
      if type(type_value) ~= "table" then
         decode_error("invalid bytecode AST type list")
      end
      setmetatable(type_value, restored_type_metatable)
   end
   return envelope.root
end

local function wrap_payload(backend, payload)
   if #payload > MAX_PAYLOAD_BYTES then
      encode_error("cache payload is too large")
   end
   local fingerprint = cache_format.runtime_fingerprint
   local out = { MAGIC, string.char(VERSION), string.char(backend) }
   append_varuint(out, #fingerprint)
   append_varuint(out, #payload)
   out[#out + 1] = digest_bytes(payload)
   out[#out + 1] = fingerprint
   out[#out + 1] = payload
   return table.concat(out)
end

local function encode_bytecode(
   root,
   backend)

   local source = build_source(root)
   local outer, compile_err = load_chunk(source, "@tl-cache-builder", "t")
   if not outer then
      encode_error("could not compile builder: " .. compile_err)
   end

   local bytecode = dump_function(outer)
   return wrap_payload(backend or BACKEND_BYTECODE, bytecode)
end

function cache_format.encode_compiler_graph(
   root)

   local ok, result = protected_call(
   encode_bytecode,
   clone_compiler_graph(root),
   BACKEND_BYTECODE_AST)

   if not ok then
      return nil, result
   end
   return result
end

function cache_format.encode(root)
   local ok, result = protected_call(
   encode_bytecode,
   root,
   BACKEND_BYTECODE)

   if not ok then
      return nil, result
   end
   return result
end

local function read_varuint(
   data,
   position,
   limit)

   local value = 0
   local scale = 1
   while true do
      if position > limit then
         decode_error("unexpected end of data")
      end
      local byte = string.byte(data, position)
      position = position + 1
      local digit = byte % 128
      if digit > math.floor((MAX_SAFE_INTEGER - value) / scale) then
         decode_error("varint overflow")
      end
      value = value + digit * scale
      if byte < 128 then
         return value, position
      end
      if scale > math.floor(MAX_SAFE_INTEGER / 128) then
         decode_error("varint overflow")
      end
      scale = scale * 128
   end
end

local function decode_unsafe(data)
   if type(data) ~= "string" then
      decode_error("input must be a string")
   end
   if #data < #MAGIC + 4 + CHECKSUM_BYTES then
      decode_error("input is too short")
   end
   if string.sub(data, 1, #MAGIC) ~= MAGIC then
      decode_error("incorrect magic")
   end

   local limit = #data
   local position = #MAGIC + 1
   local version = string.byte(data, position)
   position = position + 1
   if version ~= VERSION then
      decode_error("unsupported format version " .. tostring(version))
   end
   local backend = string.byte(data, position)
   position = position + 1
   if backend ~= BACKEND_BYTECODE and
      backend ~= BACKEND_BYTECODE_AST then

      decode_error("unsupported cache backend")
   end

   local fingerprint_length
   fingerprint_length, position = read_varuint(data, position, limit)
   if fingerprint_length > MAX_FINGERPRINT_BYTES then
      decode_error("runtime fingerprint is too large")
   end
   local payload_length
   payload_length, position = read_varuint(data, position, limit)
   if payload_length > MAX_PAYLOAD_BYTES then
      decode_error("cache payload is too large")
   end
   if position + CHECKSUM_BYTES +
      fingerprint_length + payload_length - 1 ~= limit then

      decode_error("payload length mismatch")
   end

   local expected_checksum = string.sub(
   data,
   position,
   position + CHECKSUM_BYTES - 1)

   position = position + CHECKSUM_BYTES
   local fingerprint = string.sub(
   data,
   position,
   position + fingerprint_length - 1)

   position = position + fingerprint_length
   if fingerprint ~= cache_format.runtime_fingerprint then
      decode_error("runtime fingerprint mismatch")
   end

   local payload = string.sub(data, position)
   if digest_bytes(payload) ~= expected_checksum then
      decode_error("cache payload checksum mismatch")
   end
   local builder, load_err = load_chunk(
   payload,
   "@tl-cache-builder",
   "b")

   if not builder then
      decode_error("could not load builder: " .. load_err)
   end
   local root = builder()
   return root, backend
end

function cache_format.decode(data)
   local ok, result, backend = protected_call(decode_unsafe, data)
   if not ok then
      return nil, result
   end
   if backend == BACKEND_BYTECODE_AST then
      local restore_ok, restored = pcall(
      restore_bytecode_ast,
      result)

      if not restore_ok then
         return nil, restored
      end
      return restored
   end
   return result
end

return cache_format
