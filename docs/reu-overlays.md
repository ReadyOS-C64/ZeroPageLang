# REU and DLLs

ZeroPage uses the Commodore RAM Expansion Unit (REU) for explicit far storage and as the backing store for dynamically loadable modules (DLLs). The CPU accesses REU memory through transfers to and from C64 RAM.

Import the built-in module with:

```zig
const ZeroPage = @import("ZeroPage");
```

The complete callable surface is listed in [API reference](api.md).

For a guided sequence, start with [bounded raw DMA](https://readyos-c64.github.io/ZeroPageLang/tutorial-dma.html),
then [update an enemy roster in batches of 20](https://readyos-c64.github.io/ZeroPageLang/tutorial-reu-pages.html#enemy-roster).
The [shared-window lesson](https://readyos-c64.github.io/ZeroPageLang/tutorial-dll-cache.html)
uses REU for code instead of records and traces when disk is read.

## Raw REU transfers

`ZeroPage.reu` supports presence detection, C64-to-REU and REU-to-C64 copies, swap, compare, and fill. A raw REU address must currently be a compile-time integer in `0..0x00ff_ffff`. Literal zero-length transfers are rejected; this avoids accidentally requesting the REU hardware's special 64 KB transfer.

The generated runtime programs `$df00-$df0a`. Peddle-based tests model the same register behavior, and optional VICE tests run with a 16 MB REU.

Presence detection establishes that the registers respond. Size the layout
against the installed capacity by adding each region's size to its base and
taking the largest exclusive end. Include the ranges of raw transfers as well
as arena, module payload, and saved-state reservations.

## Far heaps and views

Declare a far arena with `arena assets in asset_ram;` in `memory`, where `asset_ram` is an REU region. Regions must be non-empty, non-overlapping, and contained within the 16 MB REU address space.

`allocBytes` returns `?FarBytes`. A far handle contains an REU address and length, but is deliberately opaque: it cannot be dereferenced, indexed, converted to a C64 pointer, or passed to a near heap. Use explicit copy operations instead.

`ZeroPage.reu.view(T, far, count)` adds a fixed-layout struct type and count to a far allocation. `get` and `set` transfer one record through compiler-owned C64 staging storage. Supported records may contain scalars, enums, words, nested supported structs, and fixed scalar or enum arrays. Pointer, optional, union, string, and array-of-struct fields are rejected.

For repeated local work, `materialize` and `materializeRange` copy records into a named near arena heap. The returned `NearView` reads and writes C64 RAM; `flush` and `flushRange` copy changes back to REU. Materialization does not reset or otherwise own the near heap.

Choose storage by how each consumer uses the bytes. The
[split tile example](tutorial-examples/reu-split-tables.zp64) keeps artwork in a
fixed REU region for direct DMA to the screen. It keeps visits and flags in a
typed far view so editing state transfers only the state record. A tile ID
selects the corresponding entry in each table.

## Module artifacts

A `module` declaration makes `compile` emit:

- `.zpmod.json`: readable module metadata;
- `.zpmod`: deterministic binary metadata and a jump-table-first payload;
- optional disk-manifest, disk-payload, and relocation-simulation sidecars.

The binary format starts with `ZPMD` and is currently version 1. Export and dependency ordinals are fixed at compile time. Relocations are explicit `abs16`, `lo8`, or `hi8` records generated from compiler-owned anchors; they are not discovered by scanning arbitrary machine code.

Sidecars are compiler and packaging inputs. Target code does not parse JSON, names, signatures, dependency graphs, or the binary module format.

A producer build can supply more than one application. Compile each caller with
the producer's metadata and relocation simulation. Package the matching disk
payload in each application's D64 under the name that caller declares. The
[calculator caller](tutorial-examples/dll-reuse.zp64) and
[score updater](tutorial-examples/memory-plan.zp64) use the same
[FixedMath producer](tutorial-examples/memory-plan-math.zp64) with different
loading policies.

## Declaring a DLL and its loader

The producer lists exports in ordinal order. `export public_name = implementation;` gives a function a different DLL name. `dependency math_core;` lists a direct dependency. An id that includes a hyphen uses quotes. Define each exported implementation with `callconv(.stack)`.

```zig
module enemy_runtime abi 1 {
    export tick;
    dependency math_core;
}

extern module MathCore = math_core {
    fn add(value: u8) u8;
}

module_loader {
    window main in module_window;
    reu_cache in module_cache;
    disk_staging in staging_ram;
    capacity = 2;

    current {
        file = "enemyrt";
    }

    dependency MathCore {
        file = "mathcore";
        load = .on_demand;
        persist_in_reu at 0x0400 size 2;
    }
}
```

The `memory` block supplies the named C64 windows, visible disk staging, and REU cache. `window main` and `reu_cache` are required. Each additional `window NAME in REGION;` is available to a dependency via `window = NAME;`. The current module uses `main`. A dependency row may name the id directly or name a preceding `extern module` binding. Typed imports retain explicit load, acquire, release, and optional call results.

`current.file` and dependency `file` fields describe the disk manifest. `load` accepts `.manual`, `.preload`, or `.on_demand`. A non-manual current module can specify `load_file` for its runtime filename, defaulting to its manifest `file` when supplied. To describe a dependency graph, list each node’s edges with `requires = .{ .prerequisite };`, including `requires = .{};` for a leaf. A preload or on-demand row can use `graph = true` to load its prerequisites. `discard_on_unload;` and one or more `persist_in_reu at OFFSET size BYTES;` clauses select mutually exclusive state policies. See the [multi-window example](../examples/small/85_module_typed_multi_window_binding.zp64) for a complete configuration.

## Loading and dispatch

Module storage can refer to the same names used by Memory Arenas and resident placement. A C64 named region may supply `.load_window`, `.extra_load_windows`, or `.disk_staging`; an REU named region may supply `.reu_cache`. Far and near heaps use that same region table. Space, range, and overlap checks are therefore centralized, and a region cannot silently be claimed by both an arena and a DLL role.

A module row normally moves through three places:

1. KERNAL `LOAD` reads its disk PRG into the configured C64 staging buffer.
2. The runtime copies the payload into that row's planned REU cache slot.
3. A call activates the row in its assigned C64 window, applies relocations, and jumps through `window_base + ordinal * 3`.

The current module is row 0. Dependencies follow declared source order; transitive graph rows follow the validated graph plan. The registry records loaded state and an explicit ownership refcount. Repeated ensure-loads are idempotent; acquire/release operations change ownership.

Unloading clears callability when the final reference is released. It does not scrub staging RAM, the REU cache, or a load window.

Named regions do not change DLL lifecycle or relocation. They name and validate the physical window/cache reservations; module rows, caching, activation, eviction, refcounts, and relocation continue to work exactly as described below.

In a hosted environment, the cache name may resolve to an allocator-owned opaque resource instead of a fixed physical REU address. ReadyOS integration must map module lifecycle onto the host's resource registry rather than create a second set of physical-bank ownership and loaded-state records. See [ReadyOS Precog integration](readyos-precog.md).

## Dependencies and policies

Dependencies may be loaded manually, preloaded at program entry, or loaded on demand at an explicit call site. A dependency graph is validated for missing rows and cycles at compile time.

Graph load makes prerequisites and the requested direct dependency resident in REU, in topological order. Graph acquire does the same while taking ownership references. Failures roll back only rows or references introduced by that operation. Transitive modules are not activated or called implicitly; a call still needs a compile-time sidecar and an explicit binding.

Typed bindings such as `extern module MathCore = math_core { fn add(value: u8) u8; }` are a source-level convenience over the same row, ordinal, signature, and lifecycle contracts. The low-level string API remains available for diagnostics and tooling.

## Multiple and banked windows

Rows may be assigned to `.main` or to additional named windows. Each window tracks its own active row, so activating one window does not evict another.

An unassigned dependency must match the caller's main window address and size
in its producer sidecars. With an explicit `window = NAME;` assignment, the
producer's declared window size must fit in the destination window and the
loader applies relocation for that destination. Signature, payload, and bank
checks still apply.

Three window modes are supported:

- `.visible`: ordinary CPU-visible RAM;
- `.ram_under_basic`: RAM wholly within `$a000-$bfff`;
- `.ram_under_kernal`: RAM wholly within `$e000-$ffff`.

Banked operations save `$0001`, expose RAM only for the copy, patch, state, or call operation, then restore the processor port. KERNAL-bank operations also preserve processor status and mask interrupts. Code placed under KERNAL must be KERNAL-independent, except for the supported console trampoline path; unsafe keyboard, disk, raw KERNAL, inline-assembly, and unsupported helper paths are rejected.

## Persistent state

Configured byte ranges can be saved to deterministic REU snapshot slots before an active row is replaced or finally unloaded. They are restored after the payload is copied and relocated on the next activation. Ranges are relative to the row's load window.

## Deliberate limits

ZeroPage does not currently provide general `u24` values, direct REU pointers, dirty tracking, runtime sidecar parsing, implicit graph resolution, arbitrary dotted-call autoload, or UCI/Ultimate-specific loading.

Resident `placement` declarations are not DLL rows and are not cached or evicted by the module runtime. Conversely, module exports are not accepted as fixed resident placement targets. Keeping these ownership models distinct avoids treating a sparse absolute PRG segment as one huge relocatable module payload; both models still share the same named-region allocator and validation.

REU operations have fixed register-setup cost. Prefer transfers and materialized views over treating far storage like slow scalar RAM.
