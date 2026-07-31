local util = require("spec.util")
local teal = require("teal.init")
local compiler_artifacts =
   require("teal.internal.compiler_artifacts")
local incremental_memory =
   require("teal.internal.incremental_memory")

describe("incremental compiler sessions", function()
   it("keeps artifact storage out of the public pipeline", function()
      local compiler = teal.compiler()
      assert.is_nil(compiler.env)
      assert.is_nil(compiler.set_artifact_store)
      assert.is_nil(compiler.cache_results)
      assert.is_nil(compiler.accepts_cached_results)

      local input = assert(compiler:input(
         "local value: number = 1",
         "main.tl"
      ))
      assert.is_nil(input.env)
      local tokens = assert(input:lex())
      assert.is_nil(tokens.env)
      local parse_tree = assert(tokens:parse())
      assert.is_nil(parse_tree.env)
      local module = assert(parse_tree:check("main"))
      assert.is_nil(module.env)
   end)

   it("owns dependency invalidation without a persistence store", function()
      local root = util.write_tmp_dir(finally, {
         ["dep.tl"] = [[
            return { answer = 42 }
         ]],
         ["main.tl"] = [[
            local dep = require("dep")
            local answer: number = dep.answer
            return answer
         ]],
      })

      util.do_in(root, function()
         local compiler = teal.compiler()
         local _, first_err =
            assert(compiler:open("main.tl")):check("main")
         assert.same(0, #first_err.type_errors)
         assert.same({
            "dep.tl",
            "main.tl",
         }, compiler:affected("./dep.tl"))
         local change = compiler:invalidate("./dep.tl")
         assert.same("dep.tl", change.changed)
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
         assert.same({
            {
               filename = "main.tl",
               module_name = "main",
            },
         }, change.roots)

         local batch = compiler:recheck(change)
         assert.same(0, #batch.files["main.tl"].errors.type_errors)
         assert.is_table(batch.files["dep.tl"].module)
      end)
   end)

   it("reuses pristine ASTs around an unsaved-buffer edit", function()
      local root = util.write_tmp_dir(finally, {})

      util.do_in(root, function()
         local store = incremental_memory.new()
         local compiler = teal.compiler()
         compiler_artifacts.attach(compiler, store)
         compiler:update("./dep.tl", [[
            return { answer = 42 }
         ]])
         compiler:update("main.tl", [[
            local dep = require("dep")
            local answer: number = dep.answer
            return answer
         ]])

         local _, first_err =
            assert(compiler:open("main.tl")):check("main")
         assert.same(0, #first_err.type_errors)
         assert.same({
            hits = 0,
            misses = 2,
            writes = 2,
         }, store:stats())

         local change = compiler:update("./dep.tl", [[
            return { answer = "changed in the editor" }
         ]])
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
         assert.same({
            {
               filename = "main.tl",
               module_name = "main",
            },
         }, change.roots)

         local batch = compiler:recheck(change)
         local second_err = batch.files["main.tl"].errors
         assert.same(1, #second_err.type_errors)
         assert.same({ "dep" },
            batch.files["dep.tl"].module_names)
         assert.same({
            hits = 1,
            misses = 3,
            writes = 3,
         }, store:stats())
      end)
   end)

   it("resolves modules through a virtual source provider", function()
      local root = util.write_tmp_dir(finally, {})

      util.do_in(root, function()
         local provider = {
            sources = {
               ["./dep.tl"] = "return { answer = 42 }",
               ["main.tl"] = [[
                  local dep = require("dep")
                  local answer: number = dep.answer
                  return answer
               ]],
            },
         }
         function provider:read(filename)
            return self.sources[filename], "not found"
         end

         local compiler = teal.compiler({
            incremental = true,
         })
         compiler:set_source_provider(provider)
         local _, check_err =
            assert(compiler:open("main.tl")):check("main")
         assert.same(0, #check_err.syntax_errors)
         assert.same(0, #check_err.type_errors)
      end)
   end)

   it("falls back to disk for files absent from a source provider", function()
      local root = util.write_tmp_dir(finally, {
         ["dep.tl"] = "return { answer = 42 }",
      })

      util.do_in(root, function()
         local provider = {
            sources = {
               ["main.tl"] = [[
                  local dep = require("dep")
                  local answer: number = dep.answer
                  return answer
               ]],
            },
         }
         function provider:read(filename)
            return self.sources[filename]
         end

         local compiler = teal.compiler()
         compiler:set_source_provider(provider)
         local _, check_err =
            assert(compiler:open("main.tl")):check("main")
         assert.same(0, #check_err.type_errors)
      end)
   end)

   it("normalizes overlay and module-search filenames", function()
      local compiler = teal.compiler()
      compiler:update("same.tl", [[
         local answer: number = "from overlay"
      ]])

      local _, check_err =
         assert(compiler:open("./same.tl")):check("same")
      assert.same(1, #check_err.type_errors)
      assert.same("same.tl", compiler:invalidate("./same.tl").changed)
   end)

   it("checks a previously unseen file through update and recheck", function()
      local compiler = teal.compiler()
      local change = compiler:update("new.tl", [[
         local answer: number = "wrong"
      ]])
      assert.same({
         {
            filename = "new.tl",
         },
      }, change.roots)

      local batch = compiler:recheck(change)
      assert.same(1, #batch.files["new.tl"].errors.type_errors)
   end)

   it("forgets a root after its source disappears", function()
      local compiler = teal.compiler()
      local opened = compiler:update("gone.tl", "return 1")
      compiler:recheck(opened)

      local removed = compiler:update("gone.tl", nil)
      local batch = compiler:recheck(removed)
      assert.is_string(batch.files["gone.tl"].open_error)
      assert.same({}, compiler:invalidate("gone.tl").roots)
   end)

   it("rechecks a direct root that has no module name", function()
      local compiler = teal.compiler({
         incremental = true,
      })
      compiler:update(
         "standalone.tl",
         "local answer: number = 42"
      )
      local _, first_error =
         assert(compiler:open("standalone.tl")):check()
      assert.same(0, #first_error.type_errors)

      local change = compiler:update(
         "standalone.tl",
         [[local answer: number = "wrong"]]
      )
      assert.same({
         {
            filename = "standalone.tl",
         },
      }, change.roots)

      local batch = compiler:recheck(change)
      assert.same(
         1,
         #batch.files["standalone.tl"].errors.type_errors
      )
   end)

   it("reports newly discovered dependencies in the recheck batch", function()
      local compiler = teal.compiler({
         incremental = true,
      })
      compiler:update("main.tl", "return 42")
      local _, first_error =
         assert(compiler:open("main.tl")):check("main")
      assert.same(0, #first_error.type_errors)

      compiler:update("./new_dep.tl", [[
         local answer: number = "wrong"
         return answer
      ]])
      local change = compiler:update("main.tl", [[
         return require("new_dep")
      ]])
      local batch = compiler:recheck(change)

      assert.same(0, #batch.files["main.tl"].errors.type_errors)
         assert.same(
            { "new_dep" },
            batch.files["new_dep.tl"].module_names
         )
         assert.same(
            1,
            #batch.files["new_dep.tl"].errors.type_errors
         )
   end)

   it("tracks dependencies loaded through an init-module alias", function()
      local root = util.write_tmp_dir(finally, {
         pkg = {
            ["init.tl"] = "return { value = 42 }",
         },
         ["consumer.tl"] = [[
            local pkg = require("pkg")
            local value: number = pkg.value
            return value
         ]],
      })

      util.do_in(root, function()
         local compiler = teal.compiler({
            incremental = true,
         })
         assert(compiler:open("pkg/init.tl")):check("pkg.init")
         local _, first_err =
            assert(compiler:open("consumer.tl")):check("consumer")
         assert.same(0, #first_err.type_errors)
         assert.same({
            "consumer.tl",
            "pkg/init.tl",
         }, compiler:affected("pkg/init.tl"))

         local change = compiler:update(
            "pkg/init.tl",
            [[return { value = "changed" }]]
         )
         local batch = compiler:recheck(change)
         assert.same(
            1,
            #batch.files["consumer.tl"].errors.type_errors
         )
      end)
   end)

   it("invalidates dependents when a new file shadows resolution", function()
      local root = util.write_tmp_dir(finally, {
         target = {
            ["init.tl"] = "return { value = 42 }",
         },
         ["consumer.tl"] = [[
            local target = require("target")
            local value: number = target.value
            return value
         ]],
      })

      util.do_in(root, function()
         local compiler = teal.compiler({
            incremental = true,
         })
         local _, first_err =
            assert(compiler:open("consumer.tl")):check("consumer")
         assert.same(0, #first_err.type_errors)

         local change = compiler:update(
            "target.tl",
            [[return { value = "shadowed" }]]
         )
         local batch = compiler:recheck(change)
         assert.same(
            1,
            #batch.files["consumer.tl"].errors.type_errors
         )
      end)
   end)

   it("retains type reports for unaffected files", function()
      local compiler = teal.compiler()
      compiler:enable_type_reporting(true)
      compiler:update("x.tl", "local x: number = 1")
      compiler:update("y.tl", "local y: string = 'y'")
      assert(compiler:open("x.tl")):check("x")
      assert(compiler:open("y.tl")):check("y")
      assert.is_table(compiler:get_type_report().by_pos["y.tl"])

      local change = compiler:update(
         "x.tl",
         [[local x: number = "wrong"]]
      )
      compiler:recheck(change)
      assert.is_table(compiler:get_type_report().by_pos["y.tl"])
   end)

   it("retains the type reporter for local-only rechecks", function()
      local compiler = teal.compiler()
      compiler:enable_type_reporting(true)
      compiler:update("x.tl", "local x: number = 1")
      assert(compiler:open("x.tl")):check("x")
      local report = compiler:get_type_report()

      local change = compiler:update(
         "x.tl",
         "local x: number = 2"
      )
      compiler:recheck(change)
      assert.is_true(report == compiler:get_type_report())
   end)

   it("propagates conservative global invalidation to the store", function()
      local store = incremental_memory.new()
      local invalidated
      local memory_invalidate = store.invalidate
      function store:invalidate(filename, affected)
         invalidated = affected
         return memory_invalidate(self, filename, affected)
      end

      local compiler = teal.compiler()
      compiler_artifacts.attach(compiler, store)
      compiler:update("z_global.tl", [[
         global incremental_test_value: number = 1
      ]])
      assert(
         assert(compiler:open("z_global.tl")):check("z_global")
      )
      compiler:update("a_other.tl", [[
         local copy: number = incremental_test_value
      ]])
      assert(
         assert(compiler:open("a_other.tl")):check("a_other")
      )

      local expected = {
         "a_other.tl",
         "z_global.tl",
      }
      local change = compiler:invalidate("z_global.tl")
      local filenames = {}
      for _, item in ipairs(change.evicted) do
         table.insert(filenames, item.filename)
      end
      assert.same(expected, filenames)
      assert.same({
         {
            filename = "z_global.tl",
            module_name = "z_global",
         },
         {
            filename = "a_other.tl",
            module_name = "a_other",
         },
      }, change.roots)
      assert.same(expected, invalidated)

      local batch = compiler:recheck(change)
      assert.same(
         0,
         #batch.files["a_other.tl"].errors.type_errors
      )
   end)

   it("rechecks all roots when a file introduces a global", function()
      local compiler = teal.compiler()
      compiler:update("changed.tl", "local value = 1")
      assert(assert(compiler:open("changed.tl")):check())
      compiler:update("other.tl", [[
         local copy: number = introduced
      ]])
      local _, first_err =
         assert(compiler:open("other.tl")):check()
      assert.same(1, #first_err.type_errors)

      local change = compiler:update("changed.tl", [[
         global introduced: number = 1
      ]])
      local batch = compiler:recheck(change)
      assert.same(
         0,
         #batch.files["other.tl"].errors.type_errors
      )
   end)
end)
