local util = require("spec.util")
local lfs = require("lfs")

local function popen_tl(...)
   return io.popen(util.tl_cmd(...) .. " 2>&1", "r")
end

local input_file = [[
global type1 = 2

global type type_g = record
end

local type type_2 = record
end

local function bla()
end

local function ovo()
   if type1 == 2 then
      print("hello")
   else
   end
end

local func1 = function()
end

local func2 = function()
    local a = 100
    local b = a
end

-- multi
-- multi
-- multi
-- multi
-- line
-- comment
local c = 100
]]

local output_file = [[
type1 = 2

type_g = {}





local function bla()
end

local function ovo()
   if type1 == 2 then
      print("hello")
   else
   end
end

local func1 = function()
end

local func2 = function()
   local a = 100
   local b = a
end







local c = 100
]]

local hashbang_cases = {
[1] = {
with_hashbang = [[
#!/usr/bin/env lua

print("hello world")
]],
without_hashbang = [[


print("hello world")
]],
},

[2] = {
with_hashbang = [[
#!/usr/bin/env lua
print("hello world")
]],
without_hashbang = [[

print("hello world")
]],
},
}

local function tl_to_lua(name)
   return (name:gsub("%.tl$", ".lua"):gsub("^" .. util.os_tmp .. util.os_sep, ""))
end

local function generated_objects(path)
   local result = {}
   local function scan(directory)
      local attributes = lfs.attributes(directory)
      if not attributes or attributes.mode ~= "directory" then
         return
      end
      for basename in lfs.dir(directory) do
         if basename ~= "." and basename ~= ".." then
            local child = directory
               .. util.os_sep
               .. basename
            local child_attributes = lfs.attributes(child)
            if child_attributes
               and child_attributes.mode == "directory"
            then
               scan(child)
            elseif basename:match("%.gen$") then
               table.insert(result, child)
            end
         end
      end
   end
   scan(path)
   table.sort(result)
   return result
end

describe("tl gen", function()
   setup(util.chdir_setup)
   teardown(util.chdir_teardown)
   describe("on .tl files", function()
      it("reuses cached output and invalidates dependency changes", function()
         local root = util.write_tmp_dir(finally, {
            ["dep.tl"] = [[
               return {
                  answer = 42,
               }
            ]],
            ["main.tl"] = [[
               local dep = require("dep")
               print(dep.answer)
            ]],
         })
         local cache = root .. "cache"
         local command_options = {
            env = {
               TL_CACHE_DIR = cache,
            },
         }

         util.do_in(root, function()
            local function generate()
               local process = assert(io.popen(util.tl_cmd(
                  "gen",
                  command_options,
                  "main.tl"
               ) .. " 2>&1", "r"))
               local output = process:read("*a")
               util.assert_popen_close(0, process:close())
               assert.match("Wrote: main.lua", output, 1, true)
            end

            generate()
            local expected = util.read_file("main.lua")
            local objects = generated_objects(cache)
            assert.same(1, #objects)

            assert(os.remove("main.lua"))
            generate()
            assert.same(expected, util.read_file("main.lua"))
            assert.same(1, #generated_objects(cache))

            local corrupt = assert(io.open(objects[1], "wb"))
            assert(corrupt:write("corrupt"))
            assert(corrupt:close())
            assert(os.remove("main.lua"))
            generate()
            assert.same(expected, util.read_file("main.lua"))
            assert.same(1, #generated_objects(cache))

            local dependency = assert(io.open("dep.tl", "wb"))
            assert(dependency:write([[
               return {
                  answer = 43,
               }
            ]]))
            assert(dependency:close())
            generate()
            assert.same(2, #generated_objects(cache))

            local no_check_cache = root .. "no-check-cache"
            local process = assert(io.popen(util.tl_cmd(
               "gen",
               {
                  env = {
                     TL_CACHE_DIR = no_check_cache,
                  },
               },
               "--no-check",
               "main.tl"
            ) .. " 2>&1", "r"))
            process:read("*a")
            util.assert_popen_close(0, process:close())
            assert.same(
               0,
               #generated_objects(no_check_cache)
            )

            local warning = assert(io.open("warning.tl", "wb"))
            assert(warning:write("local unused = 10"))
            assert(warning:close())
            local warning_cache = root .. "warning-cache"
            process = assert(io.popen(util.tl_cmd(
               "gen",
               {
                  env = {
                     TL_CACHE_DIR = warning_cache,
                  },
               },
               "warning.tl"
            ) .. " 2>&1", "r"))
            local warning_output = process:read("*a")
            util.assert_popen_close(0, process:close())
            assert.match("1 warning", warning_output, 1, true)
            assert.same(
               1,
               #generated_objects(warning_cache)
            )

            assert(os.remove("warning.lua"))
            process = assert(io.popen(util.tl_cmd(
               "gen",
               {
                  env = {
                     TL_CACHE_DIR = warning_cache,
                  },
               },
               "warning.tl"
            ) .. " 2>&1", "r"))
            warning_output = process:read("*a")
            util.assert_popen_close(0, process:close())
            assert.match("1 warning", warning_output, 1, true)
            assert.same(
               1,
               #generated_objects(warning_cache)
            )

            local warning_options_cache =
               root .. "warning-options-cache"
            process = assert(io.popen(util.tl_cmd(
               "gen",
               {
                  env = {
                     TL_CACHE_DIR =
                        warning_options_cache,
                  },
               },
               "warning.tl",
               "--wdisable",
               "unused"
            ) .. " 2>&1", "r"))
            warning_output = process:read("*a")
            util.assert_popen_close(0, process:close())
            assert.not_match(
               "1 warning",
               warning_output,
               1,
               true
            )

            assert(os.remove("warning.lua"))
            process = assert(io.popen(util.tl_cmd(
               "gen",
               {
                  env = {
                     TL_CACHE_DIR =
                        warning_options_cache,
                  },
               },
               "warning.tl"
            ) .. " 2>&1", "r"))
            warning_output = process:read("*a")
            util.assert_popen_close(0, process:close())
            assert.match(
               "1 warning",
               warning_output,
               1,
               true
            )
         end)
      end)

      it("keeps generated objects outside a changed closure", function()
         local root = util.write_tmp_dir(finally, {
            ["dep.tl"] = "return 1",
            ["main.tl"] = [[
               local dep = require("dep")
               print(dep)
            ]],
            ["other.tl"] = "print('unchanged')",
         })
         local cache = root .. "cache"
         local command_options = {
            env = {
               TL_CACHE_DIR = cache,
            },
         }

         util.do_in(root, function()
            local function generate()
               local process = assert(io.popen(util.tl_cmd(
                  "gen",
                  command_options,
                  "main.tl",
                  "other.tl"
               ) .. " 2>&1", "r"))
               process:read("*a")
               util.assert_popen_close(0, process:close())
            end

            generate()
            local main_output = util.read_file("main.lua")
            local other_output = util.read_file("other.lua")
            assert.same(2, #generated_objects(cache))

            local dependency = assert(io.open("dep.tl", "wb"))
            assert(dependency:write("return 2"))
            assert(dependency:close())
            generate()

            assert.same(main_output, util.read_file("main.lua"))
            assert.same(other_output, util.read_file("other.lua"))
            assert.same(3, #generated_objects(cache))

            assert(os.remove("main.lua"))
            assert(os.remove("other.lua"))
            generate()
            assert.same(main_output, util.read_file("main.lua"))
            assert.same(other_output, util.read_file("other.lua"))
            assert.same(3, #generated_objects(cache))
         end)
      end)

      it("rebuilds when a changed file introduces globals", function()
         local root = util.write_tmp_dir(finally, {
            ["before.tl"] = "return 1",
            ["changed.tl"] = "local value = 1",
            ["after.tl"] = "return 2",
         })
         local cache = root .. "cache"
         local command_options = {
            env = {
               TL_CACHE_DIR = cache,
            },
         }

         util.do_in(root, function()
            local function generate()
               local process = assert(io.popen(util.tl_cmd(
                  "gen",
                  command_options,
                  "before.tl",
                  "changed.tl",
                  "after.tl"
               ) .. " 2>&1", "r"))
               process:read("*a")
               util.assert_popen_close(
                  0,
                  process:close()
               )
            end

            generate()
            assert.same(3, #generated_objects(cache))

            local changed =
               assert(io.open("changed.tl", "wb"))
            assert(changed:write(
               "global introduced: number = 1"
            ))
            assert(changed:close())
            generate()
            assert.same(6, #generated_objects(cache))

            assert(os.remove("before.lua"))
            assert(os.remove("changed.lua"))
            assert(os.remove("after.lua"))
            generate()
            assert.same(6, #generated_objects(cache))
         end)
      end)

      it("works on empty files", function()
         local name = util.write_tmp_file(finally, [[]])
         local pd = popen_tl("gen", name)
         local output = pd:read("*a")
         util.assert_popen_close(0, pd:close())
         local lua_name = tl_to_lua(name)
         assert.match("Wrote: " .. lua_name, output, 1, true)
         util.assert_line_by_line([[]], util.read_file(lua_name))
      end)

      it("reports 0 errors and code 0 on success", function()
         local name = util.write_tmp_file(finally, [[
            local function add(a: number, b: number): number
               return a + b
            end

            print(add(10, 20))
         ]])
         local pd = popen_tl("gen", name)
         local output = pd:read("*a")
         util.assert_popen_close(0, pd:close())
         local lua_name = tl_to_lua(name)
         assert.match("Wrote: " .. lua_name, output, 1, true)
         util.assert_line_by_line([[
            local function add(a, b)
               return a + b
            end

            print(add(10, 20))
         ]], util.read_file(lua_name))
      end)

      it("handles Unix newlines on every OS", function()
         local name = util.write_tmp_file(finally, "print'1'--comment\nprint'2'\nprint'3'\n")
         local pd = popen_tl("gen", name)
         local output = pd:read("*a")
         util.assert_popen_close(0, pd:close())
         local lua_name = tl_to_lua(name)
         assert.match("Wrote: " .. lua_name, output, 1, true)
         assert.same("print('1')\nprint('2')\nprint('3')\n", util.read_file(lua_name))
      end)

      it("catches type errors by default", function()
         local name = util.write_tmp_file(finally, [[
            local function add(a: number, b: number): number
               return a + b
            end

            print(add("string", 20))
            print(add(10, true))
         ]])
         local pd = popen_tl("gen", name)
         local output = pd:read("*a")
         util.assert_popen_close(1, pd:close())
         assert.match("2 errors", output, 1, true)
      end)

      it("ignores type errors with --no-check", function()
         local name = util.write_tmp_file(finally, [[
            local function add(a: number, b: number): number
               return a + b
            end

            print(add("string", 20))
            print(add(10, true))
         ]])
         local pd = popen_tl("gen", "--no-check", name)
         local output = pd:read("*a")
         util.assert_popen_close(0, pd:close())
         assert.match("Wrote:", output, 1, true)
         local lua_name = tl_to_lua(name)
         util.assert_line_by_line([[
            local function add(a, b)
               return a + b
            end

            print(add("string", 20))
            print(add(10, true))
         ]], util.read_file(lua_name))
      end)

      it("reports number of errors in stderr and code 1 on syntax errors", function()
         local name = util.write_tmp_file(finally, [[
            print(add("string", 20))))))
         ]])
         local pd = popen_tl("gen", name)
         local output = pd:read("*a")
         util.assert_popen_close(1, pd:close())
         assert.match("1 syntax error:", output, 1, true)
      end)

      it("ignores unknowns with --no-check", function()
         local name = util.write_tmp_file(finally, [[
            local function unk(x, y): number, number
               return a + b
            end
         ]])
         local pd = popen_tl("gen", "--no-check", name)
         local output = pd:read("*a")
         util.assert_popen_close(0, pd:close())
         assert.match("Wrote:", output, 1, true)
         local lua_name = tl_to_lua(name)
         util.assert_line_by_line([[
            local function unk(x, y)
               return a + b
            end
         ]], util.read_file(lua_name))
      end)

      it("does not mess up the indentation (#109)", function()
         local name = util.write_tmp_file(finally, input_file)
         local pd = popen_tl("gen", name)
         local output = pd:read("*a")
         util.assert_popen_close(0, pd:close())
         local lua_name = tl_to_lua(name)
         assert.match("Wrote: " .. lua_name, output, 1, true)
         assert.equal(output_file, util.read_file(lua_name))
      end)
   end)

   for i, case in ipairs(hashbang_cases) do
      it("[" .. i .. "] preserves hashbang with --keep-hashbang", function()
         local name = util.write_tmp_file(finally, case.with_hashbang)
         local pd = popen_tl("gen", "--keep-hashbang", name)
         local output = pd:read("*a")
         util.assert_popen_close(0, pd:close())
         local lua_name = tl_to_lua(name)
         assert.match("Wrote: " .. lua_name, output, 1, true)
         assert.equal(case.with_hashbang, util.read_file(lua_name))
      end)

      it("[" .. i .. "] drops hashbang when not using --keep-hashbang", function()
         local name = util.write_tmp_file(finally, case.with_hashbang)
         local pd = popen_tl("gen", name)
         local output = pd:read("*a")
         util.assert_popen_close(0, pd:close())
         local lua_name = tl_to_lua(name)
         assert.match("Wrote: " .. lua_name, output, 1, true)
         util.assert_line_by_line(case.without_hashbang, util.read_file(lua_name))
      end)
   end

   describe("with --gen-target=5.1", function()
      it("targets generated code to Lua 5.1+", function()
         local name = util.write_tmp_file(finally, [[

            local x = 2 // 3
            local y = 2 << 3
         ]])
         local pd = popen_tl("gen", "--gen-target=5.1", name)
         local output = pd:read("*a")
         util.assert_popen_close(0, pd:close())
         local lua_name = tl_to_lua(name)
         assert.match("Wrote: " .. lua_name, output, 1, true)
         util.assert_line_by_line([[
            local bit32 = bit32; if not bit32 then local p, m = pcall(require, 'bit32'); if p then bit32 = m end end
            local x = math.floor(2 / 3)
            local y = bit32.lshift(2, 3)
         ]], util.read_file(lua_name))
      end)

      it("with --no-check generates bit32 operations even for invalid variables (regression test for #673)", function()
         local name = util.write_tmp_file(finally, [[

            local foo = require("nonexisting")
            local y = 2 | (foo.wat << 9)
            local x = ~y
            local z = aa // bb
         ]])
         local pd = popen_tl("gen", "--no-check", "--gen-target=5.1", name)
         local output = pd:read("*a")
         util.assert_popen_close(0, pd:close())
         local lua_name = tl_to_lua(name)
         assert.match("Wrote: " .. lua_name, output, 1, true)
         util.assert_line_by_line([[
            local bit32 = bit32; if not bit32 then local p, m = pcall(require, 'bit32'); if p then bit32 = m end end
            local foo = require("nonexisting")
            local y = bit32.bor(2, (bit32.lshift(foo.wat, 9)))
            local x = bit32.bnot(y)
            local z = math.floor(aa / bb)
         ]], util.read_file(lua_name))
      end)
   end)

   describe("with --gen-target=5.3", function()
      it("targets generated code to Lua 5.3+", function()
         local name = util.write_tmp_file(finally, [[
            local x = 2 // 3
            local y = 2 << 3
         ]])
         local pd = popen_tl("gen", "--gen-target=5.3", name)
         local output = pd:read("*a")
         util.assert_popen_close(0, pd:close())
         local lua_name = tl_to_lua(name)
         assert.match("Wrote: " .. lua_name, output, 1, true)
         util.assert_line_by_line([[
            local x = 2 // 3
            local y = 2 << 3
         ]], util.read_file(lua_name))
      end)
   end)

   local input_code = [[

      local t = {1, 2, 3, 4}
      print(table.unpack(t))
      local t2 = table.pack(1, 2, "any")
      local n = 42
      local maxi = math.maxinteger
      local mini = math.mininteger
      if n is integer then
         print("hello")
      end
      if maxi is integer then
         print("maxi")
      end
      if mini is integer then
         print("mini")
      end
      local function testing(...arguments: any): any
         return arguments[2]
      end
   ]]

   local output_code_without_compat = [[

      local t = { 1, 2, 3, 4 }
      print(table.unpack(t))
      local t2 = table.pack(1, 2, "any")
      local n = 42
      local maxi = math.maxinteger
      local mini = math.mininteger
      if math.type(n) == "integer" then
         print("hello")
      end
      if math.type(maxi) == "integer" then
         print("maxi")
      end
      if math.type(mini) == "integer" then
         print("mini")
      end
      local function testing(...) local arguments = table.pack(...)
         return arguments[2]
      end
   ]]

   local output_code_without_compat_55 = [[

      local t = { 1, 2, 3, 4 }
      print(table.unpack(t))
      local t2 = table.pack(1, 2, "any")
      local n = 42
      local maxi = math.maxinteger
      local mini = math.mininteger
      if math.type(n) == "integer" then
         print("hello")
      end
      if math.type(maxi) == "integer" then
         print("maxi")
      end
      if math.type(mini) == "integer" then
         print("mini")
      end
      local function testing(...arguments)
         return arguments[2]
      end
   ]]

   local output_code_with_optional_compat = [[
      local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local math = _tl_compat and _tl_compat.math or math; local _tl_math_maxinteger = math.maxinteger or math.pow(2, 53); local _tl_math_mininteger = math.mininteger or -math.pow(2, 53); local table = _tl_compat and _tl_compat.table or table; local _tl_table_pack = table.pack or function(...) return { n = select("#", ...), ... } end; local _tl_table_unpack = unpack or table.unpack
      local t = { 1, 2, 3, 4 }
      print(_tl_table_unpack(t))
      local t2 = _tl_table_pack(1, 2, "any")
      local n = 42
      local maxi = _tl_math_maxinteger
      local mini = _tl_math_mininteger
      if math.type(n) == "integer" then
         print("hello")
      end
      if math.type(maxi) == "integer" then
         print("maxi")
      end
      if math.type(mini) == "integer" then
         print("mini")
      end
      local function testing(...) local arguments = _tl_table_pack(...)
         return arguments[2]
      end
   ]]

   local output_code_with_required_compat = [[
      local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = true, require('compat53.module'); if p then _tl_compat = m end end; local math = _tl_compat and _tl_compat.math or math; local _tl_math_maxinteger = math.maxinteger or math.pow(2, 53); local _tl_math_mininteger = math.mininteger or -math.pow(2, 53); local table = _tl_compat and _tl_compat.table or table; local _tl_table_pack = table.pack or function(...) return { n = select("#", ...), ... } end; local _tl_table_unpack = unpack or table.unpack
      local t = { 1, 2, 3, 4 }
      print(_tl_table_unpack(t))
      local t2 = _tl_table_pack(1, 2, "any")
      local n = 42
      local maxi = _tl_math_maxinteger
      local mini = _tl_math_mininteger
      if math.type(n) == "integer" then
         print("hello")
      end
      if math.type(maxi) == "integer" then
         print("maxi")
      end
      if math.type(mini) == "integer" then
         print("mini")
      end
      local function testing(...) local arguments = _tl_table_pack(...)
         return arguments[2]
      end
   ]]

   local function run_gen_with_flag(finally, flag, output_code, version)
      local name = util.write_tmp_file(finally, input_code)
      local pd = popen_tl("gen", name, flag, version and ("--gen-target="..version))
      local output = pd:read("*a")
      util.assert_popen_close(0, pd:close())
      local lua_name = tl_to_lua(name)
      assert.match("Wrote: " .. lua_name, output, 1, true)
      util.assert_line_by_line(output_code, util.read_file(lua_name))
   end

   describe("with --skip-compat53", function()
      it("does not add compat53 insertions", function()
         run_gen_with_flag(finally, "--skip-compat53", output_code_without_compat)
      end)
   end)

   describe("with --gen-compat=off", function()
      it("does not add compat53 insertions", function()
         run_gen_with_flag(finally, "--gen-compat=off", output_code_without_compat)
      end)
   end)

   describe("with --gen-compat=optional", function()
      it("adds compat53 insertions with a pcall in the require", function()
         run_gen_with_flag(finally, "--gen-compat=optional", output_code_with_optional_compat)
      end)
   end)

   describe("with --gen-compat=required", function()
      it("adds compat53 insertions", function()
         run_gen_with_flag(finally, "--gen-compat=required", output_code_with_required_compat)
      end)
   end)

   describe("without --skip-compat53", function()
      it("adds compat53 insertions by default", function()
         run_gen_with_flag(finally, nil, output_code_with_optional_compat)
      end)
   end)

   describe("with target 5.5", function()
      it("uses new argument functionality", function()
         run_gen_with_flag(finally, "--gen-compat=off", output_code_without_compat_55, "5.5")
      end)
   end)

   describe("with target 5.4", function()
      it("does not add compat53 assertions", function()
         run_gen_with_flag(finally, "--gen-compat=off", output_code_without_compat, "5.4")
      end)
   end)

   it("generates code using pragma (regression test for #929)", function()
      local name = util.write_tmp_file(finally, [[
         --#pragma arity on
         local record A
         end

         function A.hi()
            print("hi")
         end

         return A
      ]])
      local pd = io.popen(util.tl_cmd("gen", name) .. " 2>&1 1>" .. util.os_null, "r")
      local output = pd:read("*a")
      util.assert_popen_close(0, pd:close())
      assert.same("", output)
      local lua_name = tl_to_lua(name)
      util.assert_line_by_line([[

         local A = {}


         function A.hi()
            print("hi")
         end

         return A
      ]], util.read_file(lua_name))
   end)
end)
