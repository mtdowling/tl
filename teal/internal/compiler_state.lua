local compiler_state = {}




local environments = setmetatable(
{},
{ __mode = "k" })


function compiler_state.set(compiler, environment)
   environments[compiler] = environment
end

function compiler_state.get(compiler)
   return environments[compiler]
end

return compiler_state
