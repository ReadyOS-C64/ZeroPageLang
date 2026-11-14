# ReadyOS Precog integration

This document records the compatibility boundary between ZeroPage applications and ReadyOS Precog 0.5. It distinguishes behavior proved by the Tic-Tac-Toe integration from proposed compiler/runtime work.

## Proven compatibility

The ReadyOS Tic-Tac-Toe sample is a raw PRG loaded at and entered through `$1000`. Its resident image is bounded below `$c600`; the ReadyOS shim remains resident at `$c600-$c9ff` and exposes its public vectors at `$c800-$c9ff`.

The sample reimplements the small ReadyOS TUI and key-input surfaces it needs in ZeroPage. It uses PETSCII F2 (`$89`) for the next loaded application, F4 (`$8a`) for the previous loaded application, and Ctrl-B (`$02`) for the launcher. F2/F4 scan ReadyOS schema-5 token status through the shim's current physical control bank, put the selected logical token in `$c820`, and terminal-jump through `$c80f`. Ctrl-B terminal-jumps through `$c80c`.

This proves that ReadyOS TUI and keypress micro-modules do not need to be linked directly. Their observable ABI can be reimplemented in ZeroPage, while application switching, snapshotting, cache fetch, and launcher return remain owned by the ReadyOS shim.

The current sample deliberately performs a cold initialization whenever ReadyOS enters `$1000`. ReadyOS restores the cached application image, but the sample then starts a fresh game. Preserving a live game requires the lifecycle entry design below.

## ZeroPage Sheet

The spreadsheet uses a raw PRG at `$1000` and preserves its workbook and
session across app switches. Its app-side adapter claims three ReadyOS
schema-5 resources for live data, staging, and cached code and help.
Three fixed-address PRG overlays share C64 RAM under BASIC ROM, while
the grid and evaluator stay resident. This sample's adapter is part of
the application. The compiler-level host adapter below remains a
separate design.
[Spreadsheet architecture](spreadsheet-showcase.md) ·
[Hosted entry point](../sampleapps/spreadsheet/readyos.zp64)

## Entry points and segmented images

ZeroPage already treats PRG load address and executable entry address independently. ReadyOS currently has one fixed application entry, `$1000`, so a hosted application should retain a tiny, stable trampoline there and allow the actual resident body to start elsewhere.

The next image contract should distinguish:

- load address: where an image or segment arrives;
- run address: where copied or banked bytes execute;
- cold entry: first initialization after disk load;
- resume entry: re-entry after ReadyOS restores an application snapshot;
- suspend hook: optional state flushing before a switch;
- resident service vectors: ReadyOS-owned calls that survive application swaps.

The `$1000` trampoline should dispatch the cold or resume hook without requiring the ReadyOS shim to understand ZeroPage sections. A small versioned lifecycle block in normal app RAM can hold the initialized/resume reason state. A later ReadyOS ABI could pass the reason directly.

For more general broken-up memory, the compiler image model should evolve from one contiguous PRG range into a segment graph. Each segment needs a load-memory address, run-memory address, length, copy/zero-fill policy, visibility mode, and lifetime. The existing `.direct` and `.startup_copy` placements are the first two policies. A standalone PRG backend may pad direct segments or emit a compact bootstrap; a ReadyOS packager can retain compact segment records and let the `$1000` trampoline materialize them.

## One named-region ownership graph

Named regions are the physical vocabulary for Memory Arenas, resident placements, DLL windows, disk staging, REU cache, and snapshots. They must not become a second allocator beside any of those features.

A region describes physical facts:

- address space (`c64` or `reu`);
- address and size, or a host-allocated symbolic pool;
- C64 visibility (`visible`, `ram_under_basic`, or `ram_under_kernal`);
- owner (`application`, `readyos`, or shared host service);
- lifetime (`resident`, `overlay`, `snapshot`, or scratch);
- volatility and restoration policy.

Consumers claim a region by name and add policy:

- a Memory Arena allocates objects within it;
- a placement assigns resident code/data to it;
- a DLL window activates relocatable code within it;
- a staging consumer performs disk or host transfers through it;
- a cache consumer stores inactive payloads in it.

One planning pass must emit an ownership/claim ledger and reject accidental overlap. Intentional phase-sharing should require an explicit union/alias declaration with compatible lifetimes; two unrelated consumers must never infer that overlap is safe.

This keeps the distinction useful: regions answer **where and who owns the bytes**; arenas answer **how objects are allocated**; DLLs answer **how code is loaded, relocated, activated, referenced, and evicted**.

## RAM behind KERNAL ROM

ZeroPage already supports `.startup_copy` placements and module windows wholly inside `$e000-$ffff` with `.ram_under_kernal`. Calls use resident gateways that save processor status and `$0001`, mask interrupts, expose RAM, call the hidden code, preserve scalar return registers, and restore the machine mapping.

The same restrictions apply under ReadyOS:

- hidden code must not call KERNAL, disk, or keyboard services while HIRAM is clear unless it uses an explicit bank-stable trampoline;
- interrupt and NMI behavior must remain valid while KERNAL ROM and its vectors are unavailable;
- hidden constants must be accessed only while their bank is exposed;
- long-running hidden-ROM work should be avoided unless the application supplies a complete bank-independent interrupt policy.

The ReadyOS shim itself stays at `$c600-$c9ff`; it is not an application placement window. RAM under KERNAL is appropriate for leaf code, immutable tables, or an activated DLL window with compile-time safety metadata.

## DLL loading and REU caching

The existing ZeroPage module format remains a good match for ReadyOS: compact jump-table-first payloads, explicit relocations, fixed export ordinals, compile-time dependency validation, multiple C64 activation windows, persistent ranges, and REU backing are all reusable.

The standalone loader currently assumes that its configured `.reu_cache` is a fixed physical REU range. That assumption must not cross into ReadyOS. ReadyOS schema 5 owns logical-token mapping, physical-bank types, resource records, cache status, and eviction. A `readyos_schema5` module host should therefore replace direct physical allocation while preserving the ZeroPage module lifecycle above it.

The hosted flow should be:

1. The compiler emits `.zpmod` payloads and a compact package manifest containing module id, ABI, checksum/version, windows, dependencies, state, and cache size.
2. The ReadyOS packager registers each payload as a ReadyOS resource and requests bank(s) through the ReadyOS allocator. No compiler-hardcoded physical bank number is stored in the app.
3. The ZeroPage runtime refers to an opaque resource handle. The host adapter resolves it through ReadyOS metadata, fetches the payload into its named C64 window, applies ZeroPage relocations, and dispatches through the ordinal jump table.
4. Loaded state, ownership/reference count, and eviction are authoritative in one place. The adapter maps ZeroPage acquire/release semantics onto ReadyOS resource records rather than maintaining competing loaded flags.
5. Cache identity includes module id, ABI, and content checksum so stale REU payloads cannot be mistaken for a compatible DLL.

Far Memory Arenas need the same host allocator. Under standalone mode, a named REU region may still resolve to a fixed address. Under ReadyOS, an arena requests `APP_ALLOC`-style resources and uses opaque allocation handles containing identity, offset, length, and generation. Raw physical REU addresses remain available only for explicitly unmanaged low-level code.

## Snapshots, DLL windows, and resume state

ReadyOS currently snapshots the complete application range `$1000-$c5ff` into a per-app physical REU bank. An active DLL window inside that range is therefore duplicated in the application snapshot even when its authoritative payload also lives in a resource cache. This is correct but wasteful.

The first hosted implementation can keep that behavior. Before switching, a suspend hook should flush dirty DLL persistent ranges and far views, then mark activation-window contents disposable. On resume, the lifecycle dispatcher restores app state and can reactivate required DLL rows from the authoritative ReadyOS cache.

ReadyOS leaves `$b600-$ffff` of each application bank outside the `$b600`-byte C64 snapshot. That tail can hold a versioned ZeroPage resume descriptor, module registry state, and dirty persistent data. It must be addressed by resolving the current logical application token through ReadyOS mapping; ZeroPage must not derive or retain a physical bank number. Records need a magic, schema version, checksum, and strict length bounds.

A later ReadyOS optimization may accept a segment/omission list and skip disposable DLL windows during snapshots. That is an optional shim enhancement, not a prerequisite for compatibility.

## Recommended implementation slices

1. Add a ReadyOS target profile with the `$1000` lifecycle trampoline, cold/resume distinction, fixed app boundary, and reserved shim declaration.
2. Add a host allocation interface with `standalone_fixed` and `readyos_schema5` implementations; make both Memory Arenas and module caches consume its handles through the named-region claim ledger.
3. Teach the packager to register `.zpmod` payloads as ReadyOS resources and activate them through one visible or banked named C64 window.
4. Add a versioned resume-tail descriptor for module state, arena handles, dirty ranges, and lifecycle reason.
5. Only then consider segmented ReadyOS snapshots that omit rehydratable DLL windows.

The core compatibility conclusion is therefore **yes, with an adapter**: ZeroPage-generated applications, reimplemented TUI/input helpers, banked code, and DLL payloads can work with the ReadyOS shim. Direct use of the standalone fixed-REU module allocator cannot, because ReadyOS must remain the physical allocation and cache authority.
