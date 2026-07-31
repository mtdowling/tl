local util = require("spec.util")
local lfs = require("lfs")
local project_cache = require("tlcli.project_cache")
local teal = require("teal.init")
local compiler_artifacts =
   require("teal.internal.compiler_artifacts")

local function new_cache(finally)
   local root = util.write_tmp_dir(finally, {})
   local directory = root .. "cache"
   return project_cache.open({
      directory = directory,
      project_root = root,
   }), directory, root
end

local function first_project_object(cache)
   local objects = cache:cache_directory() .. "/objects"
   for shard in lfs.dir(objects) do
      if shard ~= "." and shard ~= ".." then
         local directory = objects .. "/" .. shard
         local attributes = lfs.attributes(directory)
         if attributes and attributes.mode == "directory" then
            for basename in lfs.dir(directory) do
               if basename:match("%.check$") then
                  return directory .. "/" .. basename
               end
            end
         end
      end
   end
end

local function generated_object_count(cache)
   local count = 0
   local objects = cache:cache_directory() .. "/objects"
   for shard in lfs.dir(objects) do
      if shard ~= "." and shard ~= ".." then
         local directory = objects .. "/" .. shard
         local attributes = lfs.attributes(directory)
         if attributes and attributes.mode == "directory" then
            for basename in lfs.dir(directory) do
               if basename:match("%.gen$") then
                  count = count + 1
               end
            end
         end
      end
   end
   return count
end

describe("tlcli.project_cache", function()
   it("never makes compilation depend on cache availability", function()
      local function fail()
         error("cache is unavailable")
      end
      local compiler = teal.compiler()
      compiler_artifacts.attach(compiler, {
         get_parse = fail,
         invalidate = fail,
         load_checked = fail,
         put_parse = fail,
         put_checked = fail,
         record_result = fail,
      })

      local module, check_err = compiler:input(
         "local answer: number = 42",
         "main.tl"
      ):check("main")
      assert.is_table(module)
      assert.same(0, #check_err.syntax_errors)
      assert.same(0, #check_err.type_errors)
      assert.same({
         {
            filename = "main.tl",
            module_names = { "main" },
         },
      }, compiler:invalidate("main.tl").evicted)
      assert.has_no.errors(function()
         compiler_artifacts.finish(compiler)
      end)
   end)

   it("prunes at most once across repeated flushes", function()
      local cache = new_cache(finally)
      local prune_calls = 0
      cache.prune = function()
         prune_calls = prune_calls + 1
         return 0
      end

      assert(cache:flush())
      cache:record_result("main.tl", {})
      assert(cache:flush())
      assert.same(1, prune_calls)
   end)

   it("invalidates and rechecks reverse dependents in one compiler", function()
      local root = util.write_tmp_dir(finally, {
         ["dep.tl"] = [[
            return {
               answer = 42,
            }
         ]],
         ["main.tl"] = [[
            local dep = require("dep")
            local answer: number = dep.answer
            return answer
         ]],
      })

      util.do_in(root, function()
         local cache = project_cache.open({
            directory = root .. "cache",
            project_root = root,
         })
         local compiler = teal.compiler()
         compiler_artifacts.attach(compiler, cache)

         local _, first_err =
            assert(compiler:open("main.tl")):check("main")
         assert.same(0, #first_err.type_errors)

         local fd = assert(io.open("dep.tl", "wb"))
         assert(fd:write([[
            return {
               answer = "not a number",
            }
         ]]))
         assert(fd:close())

         local change = compiler:invalidate("./dep.tl")
         assert.same({
            {
               filename = "dep.tl",
               module_names = { "dep" },
            },
            {
               filename = "main.tl",
               module_names = { "main" },
            },
         }, change.evicted)

         local batch = compiler:recheck(change)
         local second_err = batch.files["main.tl"].errors
         assert.same(1, #second_err.type_errors)
      end)
   end)

   it("restores generated Lua for an unchanged dependency graph", function()
      local root = util.write_tmp_dir(finally, {
         ["dep.tl"] = [[
            return {
               answer = 42,
            }
         ]],
         ["main.tl"] = [[
            local dep = require("dep")
            local answer: number = dep.answer
            return answer
         ]],
      })
      local roots = {
         {
            filename = "main.tl",
            module_name = "main",
         },
      }

      util.do_in(root, function()
         local directory = root .. "cache"
         local first_cache = project_cache.open({
            directory = directory,
            mode = "gen",
            options_key = "gen-options",
            project_root = root,
         })
         local first_compiler = teal.compiler()
         compiler_artifacts.attach(first_compiler, first_cache)
         local module, errors =
            assert(first_compiler:open("main.tl")):check("main")
         assert.same(0, #errors.type_errors)
         local output = module:gen()
         assert(first_cache:put_generated(
            first_compiler,
            roots,
            { output }
         ))
         assert(first_cache:flush())
         assert.same(
            1,
            first_cache:stats().generation_writes
         )

         local second_cache = project_cache.open({
            directory = directory,
            mode = "gen",
            options_key = "gen-options",
            project_root = root,
         })
         local second_compiler = teal.compiler()
         local cached = second_cache:load_generated(
            second_compiler,
            roots
         )
         assert.same({ output }, cached)
         assert.same(
            1,
            second_cache:stats().generation_hits
         )
         assert.is_nil(second_compiler:recall("main.tl"))

         local fd = assert(io.open("dep.tl", "wb"))
         assert(fd:write([[
            return {
               answer = 43,
            }
         ]]))
         assert(fd:close())

         local changed_cache = project_cache.open({
            directory = directory,
            mode = "gen",
            options_key = "gen-options",
            project_root = root,
         })
         assert.is_nil(changed_cache:load_generated(
            teal.compiler(),
            roots
         ))
         assert.same(
            1,
            changed_cache:stats().generation_misses
         )

         local options_cache = project_cache.open({
            directory = directory,
            mode = "gen",
            options_key = "different-options",
            project_root = root,
         })
         assert.is_nil(options_cache:load_generated(
            teal.compiler(),
            roots
         ))
      end)
   end)

   it("reuses generated Lua outside a changed dependency closure", function()
      local root = util.write_tmp_dir(finally, {
         ["dep.tl"] = "return 1",
         ["main.tl"] = [[
            local dep = require("dep")
            return dep
         ]],
         ["other.tl"] = "return 'unchanged'",
      })
      local roots = {
         {
            filename = "main.tl",
            module_name = "main",
         },
         {
            filename = "other.tl",
            module_name = "other",
         },
      }

      util.do_in(root, function()
         local directory = root .. "cache"
         local first_cache = project_cache.open({
            directory = directory,
            mode = "gen",
            options_key = "gen-options",
            project_root = root,
         })
         local first_compiler = teal.compiler()
         compiler_artifacts.attach(first_compiler, first_cache)
         local first_outputs = {}
         for i, item in ipairs(roots) do
            local module, errors =
               assert(first_compiler:open(item.filename))
                  :check(item.module_name)
            assert.same(0, #errors.type_errors)
            first_outputs[i] = module:gen()
         end
         assert(first_cache:put_generated(
            first_compiler,
            roots,
            first_outputs
         ))
         assert(first_cache:flush())
         assert.same(2, generated_object_count(first_cache))

         local dependency = assert(io.open("dep.tl", "wb"))
         assert(dependency:write("return 2"))
         assert(dependency:close())

         local second_cache = project_cache.open({
            directory = directory,
            mode = "gen",
            options_key = "gen-options",
            project_root = root,
         })
         local second_compiler = teal.compiler()
         compiler_artifacts.attach(second_compiler, second_cache)
         assert.is_nil(second_cache:load_generated(
            second_compiler,
            roots
         ))
         assert.is_nil(second_compiler:recall("main.tl"))
         assert.is_nil(second_compiler:recall("other.tl"))

         local partial = second_cache:load_partial_generated(
            second_compiler,
            roots
         )
         assert.is_nil(partial[1])
         assert.same(first_outputs[2], partial[2])
         assert.same(
            1,
            second_cache:stats().generation_partial_hits
         )
         assert.same(
            1,
            second_cache:stats().generation_file_hits
         )
         assert.same(
            1,
            second_cache:stats().generation_file_misses
         )

         local main, errors =
            assert(second_compiler:open("main.tl"))
               :check("main")
         assert.same(0, #errors.type_errors)
         local second_outputs = {
            main:gen(),
            partial[2],
         }
         assert(second_cache:put_generated(
            second_compiler,
            roots,
            second_outputs
         ))
         assert(second_cache:flush())
         assert.same(
            1,
            second_cache:stats().generation_file_writes
         )
         assert.same(3, generated_object_count(second_cache))

         local third_cache = project_cache.open({
            directory = directory,
            mode = "gen",
            options_key = "gen-options",
            project_root = root,
         })
         assert.same(
            second_outputs,
            third_cache:load_generated(
               teal.compiler(),
               roots
            )
         )
      end)
   end)

   it("requires a full rebuild when a file introduces globals", function()
      local root = util.write_tmp_dir(finally, {
         ["before.tl"] = "return 1",
         ["changed.tl"] = "local value = 1",
         ["after.tl"] = "return 2",
      })
      local roots = {
         {
            filename = "before.tl",
            module_name = "before",
         },
         {
            filename = "changed.tl",
            module_name = "changed",
         },
         {
            filename = "after.tl",
            module_name = "after",
         },
      }

      util.do_in(root, function()
         local directory = root .. "cache"
         local first_cache = project_cache.open({
            directory = directory,
            mode = "gen",
            options_key = "gen-options",
            project_root = root,
         })
         local first_compiler = teal.compiler()
         compiler_artifacts.attach(first_compiler, first_cache)
         local outputs = {}
         for i, item in ipairs(roots) do
            local module, errors =
               assert(first_compiler:open(item.filename))
                  :check(item.module_name)
            assert.same(0, #errors.type_errors)
            outputs[i] = module:gen()
         end
         assert(first_cache:put_generated(
            first_compiler,
            roots,
            outputs
         ))
         assert(first_cache:flush())

         local changed = assert(io.open("changed.tl", "wb"))
         assert(changed:write(
            "global introduced: number = 1"
         ))
         assert(changed:close())

         local second_cache = project_cache.open({
            directory = directory,
            mode = "gen",
            options_key = "gen-options",
            project_root = root,
         })
         local second_compiler = teal.compiler()
         compiler_artifacts.attach(second_compiler, second_cache)
         assert.is_nil(second_cache:load_generated(
            second_compiler,
            roots
         ))
         local partial =
            second_cache:load_partial_generated(
               second_compiler,
               roots
            )
         assert.same(outputs[1], partial[1])
         assert.is_nil(partial[2])
         assert.same(outputs[3], partial[3])

         local _, errors =
            assert(second_compiler:open("changed.tl"))
               :check("changed")
         assert.same(0, #errors.type_errors)
         assert.is_true(
            second_cache
               :generation_requires_full_rebuild(
                  second_compiler
               )
         )
         assert.is_false(second_cache:put_generated(
            second_compiler,
            roots,
            outputs
         ))
      end)
   end)

   it("restores an exact check project as one type-only bundle", function()
      local root = util.write_tmp_dir(finally, {
         ["globals.tl"] = [[
            global project_answer: number = 42
         ]],
         ["main.tl"] = [[
            local answer: number = project_answer
            return answer
         ]],
      })
      local roots = {
         {
            filename = "globals.tl",
            module_name = "globals",
         },
         {
            filename = "main.tl",
            module_name = "main",
         },
      }

      util.do_in(root, function()
         local directory = root .. "cache"
         local first_cache = project_cache.open({
            directory = directory,
            mode = "check",
            options_key = "check-options",
            project_root = root,
         })
         local first_compiler = teal.compiler()
         compiler_artifacts.attach(first_compiler, first_cache)
         for _, item in ipairs(roots) do
            local input = assert(first_compiler:open(item.filename))
            local _, errors = input:check(item.module_name)
            assert.same(0, #errors.type_errors)
         end
         assert(first_cache:put_project(first_compiler, roots))
         assert(first_cache:flush())
         assert.same(1, first_cache:stats().project_writes)

         local second_cache = project_cache.open({
            directory = directory,
            mode = "check",
            options_key = "check-options",
            project_root = root,
         })
         local second_compiler = teal.compiler()
         compiler_artifacts.attach(second_compiler, second_cache)
         assert(second_cache:restore_project(
            second_compiler,
            roots
         ))
         assert.same(1, second_cache:stats().project_hits)

         local _, recalled_errors =
            assert(second_compiler:recall("main.tl"))
         assert.same(0, #recalled_errors.type_errors)
         local _, global_errors = second_compiler:input(
            "local answer: number = project_answer",
            "after.tl"
         ):check("after")
         assert.same(0, #global_errors.type_errors)

         local change = second_compiler:update(
            "globals.tl",
            "global project_answer: string = 'changed'"
         )
         local batch = second_compiler:recheck(change)
         assert.same(
            1,
            #batch.files["main.tl"].errors.type_errors
         )
      end)
   end)

   it("restores unaffected project results when a source changes", function()
      local root = util.write_tmp_dir(finally, {
         ["dep.tl"] = "return 1",
         ["main.tl"] = [[
            local dep = require("dep")
            local answer: number = dep
            return answer
         ]],
         ["other.tl"] = "return 'unchanged'",
      })
      local roots = {
         {
            filename = "main.tl",
            module_name = "main",
         },
         {
            filename = "other.tl",
            module_name = "other",
         },
      }

      util.do_in(root, function()
         local directory = root .. "cache"
         local first_cache = project_cache.open({
            directory = directory,
            mode = "check",
            options_key = "check-options",
            project_root = root,
         })
         local first_compiler = teal.compiler()
         compiler_artifacts.attach(first_compiler, first_cache)
         for _, item in ipairs(roots) do
            assert(first_compiler:open(item.filename))
               :check(item.module_name)
         end
         assert(first_cache:put_project(first_compiler, roots))
         assert(first_cache:flush())

         local fd = assert(io.open("dep.tl", "wb"))
         assert(fd:write("return 'changed'"))
         assert(fd:close())

         local second_cache = project_cache.open({
            directory = directory,
            mode = "check",
            options_key = "check-options",
            project_root = root,
         })
         local second_compiler = teal.compiler()
         compiler_artifacts.attach(second_compiler, second_cache)
         assert(second_cache:restore_project(
            second_compiler,
            roots
         ))
         assert.is_nil(second_compiler:recall("main.tl"))
         assert.is_nil(second_compiler:recall("dep.tl"))
         assert.is_table(second_compiler:recall("other.tl"))
         local _, errors =
            assert(second_compiler:open("main.tl")):check("main")
         assert.same(1, #errors.type_errors)
         assert.same(1, second_cache:stats().project_hits)
         assert.same(2, second_cache:stats().project_invalidated)
         assert.same(1, second_cache:stats().project_partial_hits)
         assert.same(0, second_cache:stats().project_misses)
         assert(second_cache:put_project(second_compiler, roots))
      end)
   end)

   it("invalidates the union of two changed dependency closures", function()
      local root = util.write_tmp_dir(finally, {
         ["a.tl"] = "return 1",
         ["b.tl"] = "return 2",
         ["main.tl"] = [[
            local a = require("a")
            local b = require("b")
            local answer_a: number = a
            local answer_b: number = b
            return answer_a + answer_b
         ]],
         ["other.tl"] = "return 'unchanged'",
      })
      local roots = {
         {
            filename = "main.tl",
            module_name = "main",
         },
         {
            filename = "other.tl",
            module_name = "other",
         },
      }

      util.do_in(root, function()
         local directory = root .. "cache"
         local first_cache = project_cache.open({
            directory = directory,
            mode = "check",
            options_key = "check-options",
            project_root = root,
         })
         local first_compiler = teal.compiler()
         compiler_artifacts.attach(first_compiler, first_cache)
         for _, item in ipairs(roots) do
            assert(first_compiler:open(item.filename))
               :check(item.module_name)
         end
         assert(first_cache:put_project(first_compiler, roots))
         assert(first_cache:flush())

         for _, filename in ipairs({ "a.tl", "b.tl" }) do
            local fd = assert(io.open(filename, "wb"))
            assert(fd:write("return 'changed'"))
            assert(fd:close())
         end

         local second_cache = project_cache.open({
            directory = directory,
            mode = "check",
            options_key = "check-options",
            project_root = root,
         })
         local second_compiler = teal.compiler()
         compiler_artifacts.attach(second_compiler, second_cache)
         assert(second_cache:restore_project(
            second_compiler,
            roots
         ))
         assert.is_nil(second_compiler:recall("a.tl"))
         assert.is_nil(second_compiler:recall("b.tl"))
         assert.is_nil(second_compiler:recall("main.tl"))
         assert.is_table(second_compiler:recall("other.tl"))
         local _, errors =
            assert(second_compiler:open("main.tl")):check("main")
         assert.same(2, #errors.type_errors)
         assert.same(3, second_cache:stats().project_invalidated)
         assert.same(1, second_cache:stats().project_partial_hits)
      end)
   end)

   it("bypasses restore when most of a large project is affected", function()
      local files = {
         ["dep.tl"] = "return 1",
      }
      local roots = {}
      for i = 1, 20 do
         local filename = string.format("consumer%02d.tl", i)
         files[filename] = [[
            local dep = require("dep")
            local answer: number = dep
            return answer
         ]]
         roots[#roots + 1] = {
            filename = filename,
            module_name = string.format("consumer%02d", i),
         }
      end
      local root = util.write_tmp_dir(finally, files)

      util.do_in(root, function()
         local directory = root .. "cache"
         local first_cache = project_cache.open({
            directory = directory,
            mode = "check",
            options_key = "check-options",
            project_root = root,
         })
         local first_compiler = teal.compiler()
         compiler_artifacts.attach(first_compiler, first_cache)
         for _, item in ipairs(roots) do
            assert(first_compiler:open(item.filename))
               :check(item.module_name)
         end
         assert(first_cache:put_project(first_compiler, roots))
         assert(first_cache:flush())

         local fd = assert(io.open("dep.tl", "wb"))
         assert(fd:write("return 'changed'"))
         assert(fd:close())

         local second_cache = project_cache.open({
            directory = directory,
            mode = "check",
            options_key = "check-options",
            project_root = root,
         })
         local second_compiler = teal.compiler()
         compiler_artifacts.attach(second_compiler, second_cache)
         assert.is_false(second_cache:restore_project(
            second_compiler,
            roots
         ))
         assert.same(1, second_cache:stats().project_bypasses)
         assert.same(0, second_cache:stats().project_hits)
         assert.same(0, second_cache:stats().project_misses)
      end)
   end)

   it("invalidates dependents when a cached source is deleted", function()
      local root = util.write_tmp_dir(finally, {
         ["dep.tl"] = "return 1",
         ["main.tl"] = [[
            local dep = require("dep")
            return dep
         ]],
      })
      local roots = {
         {
            filename = "main.tl",
            module_name = "main",
         },
      }

      util.do_in(root, function()
         local directory = root .. "cache"
         local first_cache = project_cache.open({
            directory = directory,
            mode = "check",
            options_key = "check-options",
            project_root = root,
         })
         local first_compiler = teal.compiler()
         compiler_artifacts.attach(first_compiler, first_cache)
         assert(first_compiler:open("main.tl")):check("main")
         assert(first_cache:put_project(first_compiler, roots))
         assert(first_cache:flush())
         assert(os.remove("dep.tl"))

         local second_cache = project_cache.open({
            directory = directory,
            mode = "check",
            options_key = "check-options",
            project_root = root,
         })
         local second_compiler = teal.compiler()
         compiler_artifacts.attach(second_compiler, second_cache)
         assert(second_cache:restore_project(
            second_compiler,
            roots
         ))
         assert.is_nil(second_compiler:recall("dep.tl"))
         assert.is_nil(second_compiler:recall("main.tl"))
         local _, errors =
            assert(second_compiler:open("main.tl")):check("main")
         assert.same(1, #errors.type_errors)
         assert.matches(
            "module not found",
            errors.type_errors[1].msg,
            nil,
            true
         )
         assert.same(2, second_cache:stats().project_invalidated)
      end)
   end)

   it("invalidates the whole project when changed globals require it", function()
      local root = util.write_tmp_dir(finally, {
         ["globals.tl"] = [[
            global cached_project_value: number = 1
         ]],
         ["main.tl"] = [[
            local value: number = cached_project_value
            return value
         ]],
         ["other.tl"] = "return 'otherwise independent'",
      })
      local roots = {
         {
            filename = "globals.tl",
            module_name = "globals",
         },
         {
            filename = "main.tl",
            module_name = "main",
         },
         {
            filename = "other.tl",
            module_name = "other",
         },
      }

      util.do_in(root, function()
         local directory = root .. "cache"
         local first_cache = project_cache.open({
            directory = directory,
            mode = "check",
            options_key = "check-options",
            project_root = root,
         })
         local first_compiler = teal.compiler()
         compiler_artifacts.attach(first_compiler, first_cache)
         for _, item in ipairs(roots) do
            assert(first_compiler:open(item.filename))
               :check(item.module_name)
         end
         assert(first_cache:put_project(first_compiler, roots))
         assert(first_cache:flush())

         local fd = assert(io.open("globals.tl", "wb"))
         assert(fd:write([[
            global cached_project_value: string = "changed"
         ]]))
         assert(fd:close())

         local second_cache = project_cache.open({
            directory = directory,
            mode = "check",
            options_key = "check-options",
            project_root = root,
         })
         local second_compiler = teal.compiler()
         compiler_artifacts.attach(second_compiler, second_cache)
         assert(second_cache:restore_project(
            second_compiler,
            roots
         ))
         for _, item in ipairs(roots) do
            assert.is_nil(
               second_compiler:recall(item.filename)
            )
         end
         assert(second_compiler:open("globals.tl"))
            :check("globals")
         local _, errors =
            assert(second_compiler:open("main.tl")):check("main")
         assert.same(1, #errors.type_errors)
         assert.same(3, second_cache:stats().project_invalidated)
      end)
   end)

   it("rechecks dependents when module resolution changes", function()
      local root = util.write_tmp_dir(finally, {
         target = {
            ["init.tl"] = "return 1",
         },
         ["main.tl"] = [[
            local target = require("target")
            return target
         ]],
      })
      local roots = {
         {
            filename = "main.tl",
            module_name = "main",
         },
      }

      util.do_in(root, function()
         local directory = root .. "cache"
         local first_cache = project_cache.open({
            directory = directory,
            mode = "check",
            options_key = "check-options",
            project_root = root,
         })
         local first_compiler = teal.compiler()
         compiler_artifacts.attach(first_compiler, first_cache)
         assert(first_compiler:open("main.tl")):check("main")
         assert(first_cache:put_project(first_compiler, roots))
         assert(first_cache:flush())

         local fd = assert(io.open("target.tl", "wb"))
         assert(fd:write("return 2"))
         assert(fd:close())

         local second_cache = project_cache.open({
            directory = directory,
            mode = "check",
            options_key = "check-options",
            project_root = root,
         })
         local second_compiler = teal.compiler()
         compiler_artifacts.attach(second_compiler, second_cache)
         assert(second_cache:restore_project(
            second_compiler,
            roots
         ))
         assert.is_nil(second_compiler:recall("main.tl"))
         local _, errors =
            assert(second_compiler:open("main.tl")):check("main")
         assert.same(0, #errors.type_errors)
         assert.matches(
            "target%.tl$",
            compiler_artifacts.environment(second_compiler)
               .loaded["main.tl"]
               .dependencies.target
         )
         assert.same(1, second_cache:stats().project_hits)
         assert.same(2, second_cache:stats().project_invalidated)
         assert.same(1, second_cache:stats().project_partial_hits)
         assert.same(0, second_cache:stats().project_misses)
      end)
   end)

   it("prunes abandoned atomic-write temporary files", function()
      local cache = new_cache(finally)
      local temporary = cache:cache_directory()
         .. "/manifest.cache.tmp.abandoned"
      local fd = assert(io.open(temporary, "wb"))
      assert(fd:write("partial"))
      assert(fd:close())

      assert.same(1, cache:prune(0))
      assert.is_nil(io.open(temporary, "rb"))
   end)

   it("evicts old project objects to enforce a byte budget", function()
      local root = util.write_tmp_dir(finally, {})
      local cache = project_cache.open({
         directory = root .. "cache",
         max_bytes = 1,
         mode = "check",
         project_root = root,
      })
      local compiler = teal.compiler()
      compiler_artifacts.attach(compiler, cache)
      local source = "local value: number = 1"
      local module, check_err =
         compiler:input(source, "main.tl"):check("main")
      assert.is_table(module)
      assert.same(0, #check_err.type_errors)
      assert(cache:put_project(compiler, {
         {
            filename = "main.tl",
            module_name = "main",
         },
      }))
      assert(cache:flush())

      local object_path = assert(first_project_object(cache))
      assert(lfs.touch(object_path, os.time() - 120))
      assert.same(1, cache:prune(0))
      assert.is_nil(io.open(object_path, "rb"))
   end)
end)
