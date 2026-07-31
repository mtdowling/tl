# Teal project cache

Status: experimental internal implementation

Teal has two incremental systems with different lifetimes:

- `teal.incremental` and `teal.incremental_memory` retain parsed files and
  checked dependency state inside a live compiler, as needed by editors;
- `tlcli.project_cache` persists type-only check snapshots and generated Lua
  between CLI invocations.

The library does not create cache directories. The CLI installs the persistent
backend for `tl check` and successful, normally checked `tl gen` invocations.
`tl run`, stdin generation, and `tl gen --no-check` compile normally.

## Persistent layout

Persistence is experimental and opt-in. Set `TL_CACHE_DIR=auto` to use:

```text
$XDG_CACHE_HOME/tl/projects/<project-id>/
```

When `XDG_CACHE_HOME` is unset, `auto` uses `~/.cache` on POSIX systems and
`LOCALAPPDATA` on Windows. An explicit `TL_CACHE_DIR` value overrides the base.
An unset value, `off`, or `0` disables persistence. Artifacts are never written
into the source repository.

Each project directory contains:

```text
manifest.cache
objects/
  ab/
    0123.check
  cd/
    4567.gen
  ef/
    89ab.gen
```

The manifest records the project root, compiler and resolution options, source
identities, dependency edges, roots, and the current object IDs. Objects are
immutable and content-addressed. The two-character directories keep large
object stores from concentrating every entry in one directory.

The backend is split by responsibility:

- `tlcli.project_cache` is the small artifact-store adapter;
- `tlcli.project_cache.generated` validates and stores emitted Lua;
- `tlcli.project_cache.snapshot` creates and restores project snapshots;
- `tlcli.project_cache.storage` owns paths, manifests, atomic writes, and
  pruning;
- `tlcli.cache_format` encodes and validates the graph.

## Project snapshot

After a cold `tl check` or cacheable `tl gen`, the CLI stores the loaded result
types, diagnostics, dependency edges, module aliases, type counters, and
ordered global-state transitions in one graph-shared bundle. Each result
carries a minimal placeholder AST so the normal result-reporting API remains
intact.

The manifest records the exact ordered root filename/module-name pairs and the
source identity of every loaded file. A later invocation can seed its compiler
from the bundle when:

1. the requested roots and their order match exactly;
2. compiler options, module paths, runtime, and implementation match;
3. the fresh compiler has no live project results.

Every source identity and previous dependency resolution is compared with the
current project. If all match, the restored graph is the completed check.
Otherwise, changed files and consumers whose module resolution changed are
invalidated through the restored reverse-dependency graph. The normal CLI root
loop skips unaffected restored results and checks only the invalidated closure.
The resulting mixed restored-and-fresh graph becomes the next snapshot.

The manifest carries enough dependency metadata to estimate the affected
closure before decoding the object. When at least 20 files and at least one
quarter of the loaded graph would be invalidated, the CLI bypasses restoration
and performs a normal check. This avoids decoding and rebinding a graph when
little work can be reused.

Generation also bypasses a project snapshot larger than 1 MiB. Large type
graphs can cost more to reconstruct than checking an affected root and its
dependencies from source. Exact generated-output hits do not decode the
project snapshot regardless of its size.

Global changes are replayed in loaded order. Each cached `global_previous`
entry is rebound to the fresh environment before applying its cached
post-file value. Changing a global-declaring file therefore invalidates the
whole loaded project, while ordinary module changes remain incremental. If a
changed file introduces global state for the first time, generation discards
the partial attempt and retries all roots in order. This rare fallback keeps
previously independent roots from observing stale global state.

## Generated output

Successful `tl gen` invocations store one emitted-Lua object per root file,
alongside the type-only project snapshot. One generation record is keyed by
the ordered root filename/module-name pairs, compiler and generator options,
runtime fingerprint, and module-resolution configuration.

The manifest records the exact source identity and resolved dependency map for
every file loaded by the cold compilation. A warm invocation validates every
source and re-resolves every dependency before decoding the root `.gen`
objects. On an exact hit, the CLI writes the cached Lua directly and skips
parsing, checking, snapshot decoding, and generation.

After a source change, the manifest's reverse-dependency graph identifies the
affected roots. Roots outside that closure reuse their emitted-Lua objects.
Invalidated roots are parsed, checked, and generated normally.

When the type-only project snapshot is compact, it supplies the affected
checks with restored dependency types. When the snapshot is too large or the
affected closure crosses the normal rebuild threshold, the compiler checks
affected roots and their transitive dependencies in a fresh environment
instead. A successful run merges that fresh dependency metadata with the
unchanged manifest records.

Each root object is content-addressed by its source and transitive dependency
context. Sources that changed outside that context do not create another
object. Global-declaring files participate in every root context because a
global change conservatively invalidates the entire loaded project.

Entries are invocation-level so root order and global compiler state remain
part of the exact-hit key, while their emitted objects are file-level. The
manifest retains at most 16 generation records per project; immutable objects
that lose their manifest reference are removed by normal pruning.

Only successful runs are stored. Runs with warnings mark the generation
record as diagnostic-bearing. A later hit restores the compact type-only
snapshot to replay those warnings; if that snapshot cannot be restored, the
CLI checks normally instead of suppressing diagnostics. Warning-disable and
warning-as-error settings participate in the key, as does `--keep-hashbang`.
Output filenames and directories do not participate because they do not
change emitted content.

## Parsed ASTs

The CLI does not persist parsed or fully checked ASTs. Bytecode, LuaJIT string
buffer, and compact binary prototypes were all slower to load than reparsing
or rechecking representative projects. The CLI artifact-store parse callbacks
record exact filename-and-source identities and dependency metadata, then let
normal parsing continue.

Caching emitted Lua is profitable precisely because it avoids rebuilding the
annotated AST. It also avoids generation itself and produces objects close to
the size of the final Lua output.

The in-memory incremental store is intentionally different: it keeps pristine
AST copies without encoding or filesystem I/O, which makes reuse profitable
inside a long-lived compiler.

## Library and editor behavior

The normal library does not create cache directories or persist artifacts.
Long-lived editor sessions use the separate in-memory facility described in
`docs/internals/incremental-compiler.md`.

## Invalidation and safety

The live compiler maintains forward and reverse dependency edges. Given:

```text
a.tl -> b.tl -> c.tl
```

invalidating `c.tl` evicts all three checked results. If an invalidated module
changed global compiler state, the compiler conservatively invalidates the
entire loaded environment.

The artifact fingerprint includes the Lua VM, LuaJIT version, Teal's reported
version, a digest of the loaded compiler implementation, and a VM bytecode
probe. The project key also includes compiler options, initial environment
modules, and module search paths. Corrupt or incompatible artifacts are cache
misses and never compilation failures.

Objects and the manifest are written to temporary files and renamed into
place. Concurrent writers may replace the manifest in either order, but
content-addressed objects remain valid; a lost manifest update only causes a
later rebuild. The cache rejects symbolic-link directories while constructing
its private path and must never load artifacts from a repository or another
user.
