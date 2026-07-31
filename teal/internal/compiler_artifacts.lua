

local compiler_state =
require("teal.internal.compiler_state")



local compiler_artifacts = {}












function compiler_artifacts.attach(
   compiler,
   store)

   local env = compiler_artifacts.environment(compiler)
   env.session:set_artifact_store(store)
end

function compiler_artifacts.finish(compiler)
   local env = compiler_artifacts.environment(compiler)
   env.session:cache_results()
end

function compiler_artifacts.environment(
   compiler)

   return compiler_state.get(compiler)
end

return compiler_artifacts
