local cache_format = require("tlcli.cache_format")

local function round_trip(value)
   local encoded, encode_err = cache_format.encode(value)
   assert.is_nil(encode_err)
   assert.is_string(encoded)

   local decoded, decode_err = cache_format.decode(encoded)
   assert.is_nil(decode_err)
   return decoded, encoded
end

local function read_varuint(data, position)
   local value = 0
   local scale = 1
   while true do
      local byte = data:byte(position)
      position = position + 1
      value = value + (byte % 128) * scale
      if byte < 128 then
         return value, position
      end
      scale = scale * 128
   end
end

local function payload_offsets(data)
   local position = 11
   local fingerprint_length
   fingerprint_length, position = read_varuint(data, position)
   local bytecode_length
   bytecode_length, position = read_varuint(data, position)
   return position + 16, fingerprint_length, bytecode_length
end

local function assert_ast_links_and_metatables(root)
   local seen = {}
   local objects = { root }
   local backlink_count = 0
   local node_metatable_count = 0
   local type_metatable_count = 0
   local scan = 1
   seen[root] = true

   while scan <= #objects do
      local object = objects[scan]
      if rawget(object, "kind") and rawget(object, "f") then
         assert.is_table(getmetatable(object))
         node_metatable_count = node_metatable_count + 1
      elseif rawget(object, "typename") and rawget(object, "f") then
         assert.is_table(getmetatable(object))
         type_metatable_count = type_metatable_count + 1
      end

      if rawget(object, "if_blocks") then
         for _, block in ipairs(object.if_blocks) do
            assert.is_true(block.if_parent == object)
            backlink_count = backlink_count + 1
         end
      end

      for key, value in pairs(object) do
         if type(key) == "table" and not seen[key] then
            seen[key] = true
            objects[#objects + 1] = key
         end
         if type(value) == "table" and not seen[value] then
            seen[value] = true
            objects[#objects + 1] = value
         end
      end
      scan = scan + 1
   end

   assert.is_true(backlink_count > 0)
   assert.is_true(node_metatable_count > 0)
   assert.is_true(type_metatable_count > 0)
end

describe("tlcli.cache_format", function()
   it("writes a versioned bytecode envelope", function()
      local _, encoded = round_trip("hello")
      assert.same(2, cache_format.version)
      assert.same("TLBCODE\0", encoded:sub(1, 8))
      assert.same(2, encoded:byte(9))
      assert.same(0, encoded:byte(10))
      assert.is_true(#cache_format.runtime_fingerprint > 0)
      assert.is_string(cache_format.compiler_version)
      assert.is_true(#cache_format.compiler_version > 0)
      assert.is_string(cache_format.compiler_identity)
      assert.is_true(#cache_format.compiler_identity > 0)
   end)

   it("folds compiler implementation identity into the fingerprint", function()
      local original_identity = cache_format.compiler_identity
      local original_fingerprint = cache_format.runtime_fingerprint
      rawset(
         cache_format,
         "compiler_identity",
         original_identity .. "-changed"
      )
      rawset(cache_format, "runtime_fingerprint", nil)
      local changed_fingerprint = cache_format.runtime_fingerprint

      rawset(cache_format, "compiler_identity", original_identity)
      rawset(
         cache_format,
         "runtime_fingerprint",
         original_fingerprint
      )
      assert.not_same(original_fingerprint, changed_fingerprint)
   end)

   it("round-trips scalar values", function()
      assert.is_nil((round_trip(nil)))
      assert.is_false((round_trip(false)))
      assert.is_true((round_trip(true)))
      assert.same(0, (round_trip(0)))
      assert.same(-42, (round_trip(-42)))
      assert.same(1.25, (round_trip(1.25)))
      assert.same("a\0b\255", (round_trip("a\0b\255")))
      if math.mininteger then
         local minimum = round_trip(math.mininteger)
         assert.same(math.mininteger, minimum)
         assert.same("integer", math.type(minimum))
      end
   end)

   it("preserves table identity, cycles, and table keys", function()
      local child = { name = "child" }
      local root = {
         first = child,
         second = child,
      }
      root.self = root
      root[child] = root

      local decoded = round_trip(root)
      assert.same("child", decoded.first.name)
      assert.is_true(decoded.first == decoded.second)
      assert.is_true(decoded.self == decoded)
      assert.is_true(decoded[decoded.first] == decoded)
   end)

   it("round-trips numeric edge cases", function()
      local values = {
         -0.0,
         math.huge,
         -math.huge,
         math.ldexp(1, -1074),
         math.ldexp(2 - math.ldexp(1, -52), 1023),
      }

      for _, value in ipairs(values) do
         local decoded = round_trip(value)
         if value == 0 then
            assert.same(1 / value, 1 / decoded)
         else
            assert.same(value, decoded)
         end
      end

      local nan = 0 / 0
      local decoded_nan = round_trip(nan)
      assert.is_true(decoded_nan ~= decoded_nan)
   end)

   it("preserves wide integers when the runtime supports them", function()
      if math.type and math.maxinteger and math.maxinteger > 9007199254740991 then
         local decoded = round_trip(math.maxinteger)
         assert.same("integer", math.type(decoded))
         assert.same(math.maxinteger, decoded)
      end
   end)

   it("rejects unsupported graph values", function()
      local encoded, err = cache_format.encode({ callback = function() end })
      assert.is_nil(encoded)
      assert.matches("unsupported value type 'function'", err, nil, true)

      encoded, err = cache_format.encode(setmetatable({}, {}))
      assert.is_nil(encoded)
      assert.matches("has a metatable", err, nil, true)
   end)

   it("rejects a non-string input", function()
      local decoded, err = cache_format.decode({})
      assert.is_nil(decoded)
      assert.matches("input must be a string", err, nil, true)
   end)

   it("rejects incompatible or incorrectly sized envelopes", function()
      local _, encoded = round_trip({ answer = 42 })

      local decoded, err = cache_format.decode(
         "XLBCODE\0" .. encoded:sub(9)
      )
      assert.is_nil(decoded)
      assert.matches("incorrect magic", err, nil, true)

      decoded, err = cache_format.decode(
         encoded:sub(1, 8) .. "\99" .. encoded:sub(10)
      )
      assert.is_nil(decoded)
      assert.matches("unsupported format version", err, nil, true)

      decoded, err = cache_format.decode(
         encoded:sub(1, 9) .. "\255" .. encoded:sub(11)
      )
      assert.is_nil(decoded)
      assert.matches("unsupported cache backend", err, nil, true)

      decoded, err = cache_format.decode(encoded:sub(1, -2))
      assert.is_nil(decoded)
      assert.matches("payload length mismatch", err, nil, true)

      decoded, err = cache_format.decode(encoded .. "\0")
      assert.is_nil(decoded)
      assert.matches("payload length mismatch", err, nil, true)
   end)

   it("rejects another runtime fingerprint", function()
      local _, encoded = round_trip({ answer = 42 })
      local fingerprint_at = payload_offsets(encoded)
      local changed = encoded:sub(1, fingerprint_at - 1)
         .. string.char((encoded:byte(fingerprint_at) + 1) % 256)
         .. encoded:sub(fingerprint_at + 1)

      local decoded, err = cache_format.decode(changed)
      assert.is_nil(decoded)
      assert.matches("runtime fingerprint mismatch", err, nil, true)
   end)

   it("rejects payload corruption before loading bytecode", function()
      local _, encoded = round_trip({ answer = 42 })
      local fingerprint_at, fingerprint_length = payload_offsets(encoded)
      local bytecode_at = fingerprint_at + fingerprint_length
      for offset = 0, 8 do
         local at = bytecode_at + math.floor(
            offset * (#encoded - bytecode_at) / 8
         )
         local changed = encoded:sub(1, at - 1)
            .. string.char((encoded:byte(at) + 1) % 256)
            .. encoded:sub(at + 1)

         local decoded, err = cache_format.decode(changed)
         assert.is_nil(decoded)
         assert.matches(
            "cache payload checksum mismatch",
            err,
            nil,
            true
         )
      end
   end)

   it("round-trips compiler graphs with AST relationships", function()
      local teal = require("teal")
      local compiler = teal.compiler()
      local parse_tree = compiler:input([[
         local message: string = "hello"
         if message == "hello" then
            local answer: number = 42
            print(answer)
         end
      ]], "cache_test.tl"):parse()

      local encoded, encode_err =
         cache_format.encode_compiler_graph(parse_tree.ast)
      assert.is_nil(encode_err)
      assert.is_string(encoded)
      assert.same(2, encoded:byte(10))

      local decoded, decode_err = cache_format.decode(encoded)
      assert.is_nil(decode_err)
      assert_ast_links_and_metatables(decoded)
      assert.is_string(tostring(decoded))

      parse_tree.ast = decoded
      local module, check_err = parse_tree:check("cache_test")
      assert.is_table(module)
      assert.same(0, #check_err.syntax_errors)
      assert.same(0, #check_err.type_errors)
   end)
end)
