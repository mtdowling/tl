local type errors = require("teal.errors")
local type Error = errors.Error

local type parser = require("teal.parser")
local type Node = parser.Node

local record incremental_contract
   record SourceProvider
      read: function(
         self: SourceProvider,
         filename: string
      ): string, string
   end

   record CachedResult
      filename: string
      module_name: string
      result: any
      typeid_namespace: string
      typeid_ctr: integer
      typevar_ctr: integer
   end

   record Root
      filename: string
      module_name: string
   end

   record Evicted
      filename: string
      module_names: {string}
   end

   record ChangeSet
      changed: string
      evicted: {Evicted}
      roots: {Root}
   end

   record ArtifactStore
      get_parse: function(
         self: ArtifactStore,
         filename: string,
         source: string,
         flavor: string
      ): Node, {Error}, {string}
      put_parse: function(
         self: ArtifactStore,
         filename: string,
         source: string,
         flavor: string,
         ast: Node,
         syntax_errors: {Error},
         required_modules: {string}
      )
      record_result: function(
         self: ArtifactStore,
         filename: string,
         dependencies: {string:string}
      )
      invalidate: function(
         self: ArtifactStore,
         filename: string,
         affected: {string}
      )
      put_checked: function(
         self: ArtifactStore,
         filename: string,
         source: string,
         result: any,
         typeid_ctr: integer,
         typevar_ctr: integer
      )
      load_checked: function(
         self: ArtifactStore,
         filename: string,
         module_name: string,
         source: string,
         resolve_module: function(
            module_name: string
         ): string, string
      ): {CachedResult}
   end

   record InputAdapter
      check: function(
         self: InputAdapter,
         module_name?: string
      ): any, any
   end

   record CompilerAdapter
      open: function(
         self: CompilerAdapter,
         filename: string
      ): InputAdapter, string
      recall: function(
         self: CompilerAdapter,
         filename: string
      ): any, any
   end

   record Session
      set_artifact_store: function(
         self: Session,
         store: ArtifactStore
      )
      set_source_provider: function(
         self: Session,
         provider: SourceProvider
      )
      read_source: function(
         self: Session,
         filename: string
      ): string, string
      normalize_filename: function(
         self: Session,
         filename: string
      ): string
      parse: function(
         self: Session,
         filename: string,
         source: string,
         flavor: string,
         parse_source: function(): Node, {Error}, {string}
      ): Node, {Error}, {string}, boolean
      remember_root: function(
         self: Session,
         filename: string,
         module_name?: string
      )
      bind_module: function(
         self: Session,
         filename: string,
         module_name: string,
         result: any
      )
      record_result: function(
         self: Session,
         filename: string,
         dependencies: {string:string}
      )
      restore_checked: function(
         self: Session,
         filename: string,
         module_name: string,
         source: string
      ): any
      affected: function(
         self: Session,
         filename: string
      ): {string}
      update: function(
         self: Session,
         filename: string,
         source?: string
      ): ChangeSet
      invalidate: function(
         self: Session,
         filename: string
      ): ChangeSet
      recheck: function(
         self: Session,
         change: ChangeSet,
         compiler: CompilerAdapter
      ): any
      cache_results: function(self: Session)

      -- private:
      env: any
      store: ArtifactStore
      source_provider: SourceProvider
      source_overrides: {string:string}
      source_inputs: {string:string}
      dependencies: {string:{string:string}}
      reverse_dependencies: {string:{string:boolean}}
      roots: {string:Root}
      root_order: {string}
      cached_results: {string:any}
      restored_results: {any:boolean}
      restored_namespace: string
   end
end

return incremental_contract
