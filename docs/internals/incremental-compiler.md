# Incremental compiler sessions

The Teal library can retain parsed files and dependency state inside a
long-lived compiler. This is an in-memory facility intended for editors and
other interactive clients; it performs no filesystem persistence.

Enable the built-in memory store when creating a compiler:

```lua
local compiler = teal.compiler({
   incremental = true,
})
```

After checking the project roots, update an in-memory source and recheck the
affected roots:

```lua
local change = compiler:update(filename, unsaved_source)
local batch = compiler:recheck(change)

for changed_filename, result in pairs(batch.files) do
   if result.errors then
      publish_diagnostics(changed_filename, result.errors)
   elseif result.open_error then
      publish_open_error(changed_filename, result.open_error)
   else
      clear_diagnostics(changed_filename)
   end
end
```

`update` installs or replaces a source overlay, computes the transitive
reverse-dependent set, and evicts those checked results. Passing `nil` removes
the overlay. `invalidate` performs the same graph invalidation without
changing an overlay, and `affected` returns the filenames that would be
invalidated.

The compiler remembers direct calls through `Input:check` and
`ParseTree:check` as roots. Checks performed while following `require` are not
roots. Roots retain their original order because files that declare or consume
compiler globals are order-dependent. A root may have no module name or
multiple module aliases.

The returned change set contains the changed filename, evicted files and their
module aliases, and the affected remembered roots. `recheck` reloads those
roots in order and returns a `files` map containing fresh modules, diagnostics,
or open errors.

For virtual or unsaved files, install a source provider:

```lua
compiler:set_source_provider({
   read = function(self, filename)
      return open_documents[filename]
   end,
})
```

The provider is used by `Compiler:open` and module search. Returning no source
falls back to disk, so it may contain only open buffers.

Session filenames are lexically normalized by collapsing redundant
separators, `.` components, and `..` components. Clients should consistently
use one path base, preferably project-relative or absolute.

If an invalidated file changed global compiler state, the session
conservatively invalidates the entire loaded environment. Type-report entries
are removed only for evicted files unless the whole environment is
invalidated.

The built-in memory store keeps pristine parsed trees. A changed file is
reparsed, while unchanged affected dependents can be rechecked from their
saved trees without encoding or filesystem I/O.
