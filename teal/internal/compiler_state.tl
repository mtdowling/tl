local record compiler_state
   set: function(compiler: any, environment: any)
   get: function(compiler: any): any
end

local environments: {any:any} = setmetatable(
   {},
   { __mode = "k" }
)

function compiler_state.set(compiler: any, environment: any)
   environments[compiler] = environment
end

function compiler_state.get(compiler: any): any
   return environments[compiler]
end

return compiler_state
