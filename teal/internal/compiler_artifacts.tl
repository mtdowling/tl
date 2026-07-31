local type teal = require("teal.init")
local type environment = require("teal.environment")
local compiler_state =
   require("teal.internal.compiler_state")
local type incremental_contract =
   require("teal.internal.incremental_contract")

local record compiler_artifacts
   type Store = incremental_contract.ArtifactStore

   attach: function(
      compiler: teal.Compiler,
      store: Store
   )
   finish: function(compiler: teal.Compiler)
   environment: function(
      compiler: teal.Compiler
   ): environment.Env
end

function compiler_artifacts.attach(
   compiler: teal.Compiler,
   store: compiler_artifacts.Store
)
   local env = compiler_artifacts.environment(compiler)
   env.session:set_artifact_store(store)
end

function compiler_artifacts.finish(compiler: teal.Compiler)
   local env = compiler_artifacts.environment(compiler)
   env.session:cache_results()
end

function compiler_artifacts.environment(
   compiler: teal.Compiler
): environment.Env
   return compiler_state.get(compiler) as environment.Env
end

return compiler_artifacts
