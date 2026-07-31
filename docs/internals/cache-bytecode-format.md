# Teal runtime-local cache format

Status: experimental internal format

This document specifies the runtime-local binary format intended for persisted
Teal CLI cache artifacts. It is deliberately not part of the public Teal API.
The codec performs no artifact filesystem I/O. When its runtime fingerprint is
first requested, it reads the loaded compiler implementation sources to derive
a build identity. Graphs use a generated table-builder chunk compiled with
`load` and `string.dump`. Readers discard artifacts from a different virtual
machine or bytecode configuration.

## Module API

The CLI-internal `tlcli.cache_format` module exposes:

```lua
local bytes, err = cache_format.encode(root)
local bytes, err = cache_format.encode_compiler_graph(graph)
local root, err = cache_format.decode(bytes)
local format_version = cache_format.version
local runtime_id = cache_format.runtime_fingerprint
```

Both operations return `nil, error_message` on failure. A successfully decoded
`nil` root is distinguished by a `nil` error. The module performs no filesystem
I/O and is shipped only in the `tlcli` namespace.

`encode` is the general plain-table graph codec.
`encode_compiler_graph` preserves Teal node and type metatables in arbitrary
cyclic compiler graphs.

## Backends

The envelope identifies one of two backends:

| ID | Backend | Use |
| ---: | --- | --- |
| `0` | VM bytecode graph | General plain-table values |
| `2` | VM bytecode compiler graph | Compiler nodes and types |

## General bytecode graph

One artifact contains one root value. Supported values are:

- `nil`
- booleans
- numbers
- strings
- tables

Table identity, cycles, shared references, and table-valued keys are preserved.
Functions, threads, userdata, light userdata, and cdata are rejected.

Metatables are rejected by `encode`. `encode_compiler_graph` clones compiler
nodes and types into a wrapper that records which tables need their standard
metatables restored.

### Builder generation

Encoding performs these steps:

1. Walk the graph iteratively and assign every table a one-based object ID.
2. Generate a Lua chunk that allocates every table first.
3. Reuse one local table register while emitting direct assignments for every
   key/value edge.
4. Return the root value.
5. Compile the chunk in an empty environment.
6. Store its stripped `string.dump` output.

Decoding validates the envelope and runtime fingerprint, loads the binary chunk
in an empty environment, and executes it. There is no tree of generated helper
closures: one loaded chunk performs table allocation and direct assignments as
VM bytecode. Compiler graphs include arrays of node and type objects, allowing
the decoder to restore compiler-owned metatables without rediscovering the
graph.

Object order and bytecode bytes are implementation details. Cache artifacts are
not canonical and must never be used as semantic fingerprints.

## Envelope

Unsigned integer lengths use little-endian base-128 varints.

| Field | Encoding |
| --- | --- |
| Magic | Eight bytes: `TLBCODE\0` |
| Format version | One byte; currently `2` |
| Backend | One byte; `0` or `2` |
| Runtime-fingerprint length | Varint |
| Payload length | Varint |
| Payload checksum | 16 runtime-local checksum bytes |
| Runtime fingerprint | Unmodified bytes |
| Payload | Backend-specific binary bytes |

Trailing and truncated bytes are invalid. The implementation limits graph
objects, graph entries, generated source, fingerprint size, and bytecode size.

## Runtime fingerprint

The runtime fingerprint contains:

- `_VERSION`
- `jit.version` when running under LuaJIT
- Teal's reported compiler version
- a digest of the loaded compiler implementation
- the dumped bytecode of a fixed probe function

The probe embeds the VM bytecode header and its representation parameters. An
artifact with a non-identical fingerprint is a cache miss. Loader rejection is
also a cache miss.

The fingerprint deliberately prevents sharing between PUC Lua and LuaJIT or
between incompatible releases. A user switching runtimes recompiles once and
gets a separate cache population.

## Compiler cache versioning

The bytecode envelope and runtime fingerprint cover the transport, compiler
graph projection, runtime, reported Teal version, and implementation.
The containing CLI cache manifest must additionally record:

- all parsing, checking, generation, and feature options
- the source-content digest
- ordered dependency artifact keys or exported-interface digests

Any mismatch is a cache miss. Early implementations should invalidate old
artifacts instead of migrating them.

## Filesystem and execution safety

The bytecode backends contain executable VM bytecode. All backends must be
stored in a user-private cache directory, never loaded from a
repository-controlled directory, and never accepted from another user or a
downloaded build artifact. A writer should use a private temporary file
followed by an atomic rename and must not follow untrusted symlinks.

The envelope validates sizes and verifies a full-payload checksum before
passing bytecode to the VM. This prevents truncated or accidentally corrupted
cache files from reaching unsafe binary loaders. The checksum is not
authentication: anyone able to replace both payload and checksum can still
supply executable bytecode. This is not a format for untrusted
deserialization.

## Performance and size tradeoff

The design trades disk space and encode time for avoiding checker work.
Standalone persisted ASTs were removed. Bytecode and LuaJIT string-buffer
implementations lost in end-to-end measurements. A later shape-interned binary
prototype reduced a 96 KB source's AST artifact to about 500 KB, but decoding
still took about 82 ms versus 63 ms to parse under PUC Lua 5.5, and 31 ms
versus 25 ms under LuaJIT. The smaller artifact did not fix table
reconstruction cost.

The `tl check` path instead stores one graph-shared, type-only project image:
checked types and diagnostics remain reusable while annotated ASTs are omitted.
When sources change, the previous image seeds the dependency graph so only the
invalidated closure is checked before writing its successor.

The `tl gen` path stores each successful root's emitted Lua string in a
separate plain-table object. An unchanged invocation can therefore skip
parsing, checking, and generation without reconstructing an annotated AST.
After an edit, manifest dependency metadata seeds reverse invalidation,
unaffected roots reuse their Lua objects, and only the affected closure is
checked and generated. Compact type-only project images provide dependency
types to those checks; images over 1 MiB are bypassed in favor of checking the
affected roots' dependency cones from source. Each Lua object's key includes
the root's transitive dependency context so a dependency-driven
code-generation change cannot reuse stale output. A file that begins mutating
global compiler state forces one ordered full-generation retry, because this
creates dependencies that the previous graph could not have recorded.

On a five-run 52-file PUC Lua 5.5 measurement, the median check was 1.12
seconds uncached, 80 ms unchanged, 220 ms after one localized edit, and 270 ms
after two localized edits. CLI persistence remains opt-in while the format is
experimental. In-memory editor caching does not use this bytecode envelope.

These numbers are development data, not a permanent guarantee. Integration
must retain representative benchmarks and may decline to cache files where
filesystem, integrity, and validation overhead dominate.

## Project-cache boundary

This module only encodes and rebuilds compiler graphs. `teal.incremental` owns
live dependency tracking, source overlays, and reverse invalidation;
`teal.incremental_memory` is the separate in-process backend.
`tlcli.project_cache` owns source keys, cross-process dependency validation,
and atomic CLI persistence. Their shared boundary is the artifact-store
interface specified in `docs/internals/project-cache.md`.
