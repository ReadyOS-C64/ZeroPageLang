# Language reference

ZeroPage is a deliberately small, Zig-shaped language for the Commodore 64. Source files use `.zp64`.

Zig 0.16.0 validates the ordinary source grammar. A preparser isolates ZeroPage machine declarations and inline assembly. The ZeroPage parser validates those forms and lowers its supported Zig subset. Unsupported constructs fail with an explicit diagnostic.

Code generation may replace supported arithmetic with equivalent target instructions;
for example, integer literal addition/subtraction can use immediate operands.
This introduces no additional syntax or semantic exception. Unsupported constructs
remain rejected before such selection. See [optimizations](optimizations.md).

## Program shape

```zig
const c64 = @import("c64");
const ZeroPage = @import("ZeroPage");
const math = @import("math.zp64");

export fn main() void {
    const value: u8 = math.add(2, 3);
    c64.console.print("VALUE {x}\n", .{value});
}
```

A program has one `export fn main() void`. Other functions and local imports are compiled into the same PRG. The compiler-provided `c64` and `ZeroPage` modules expose target APIs; they are not filesystem imports.

## Types

| Category | Supported forms |
| --- | --- |
| Scalars | `bool`, `u8`, `i8`, `u16`, `i16`, `usize` |
| Enums | `enum(u8)` |
| Arrays | Fixed arrays of supported scalars, enums, or fixed-layout structs |
| Structs | Fixed-layout fields composed of supported scalars, enums, arrays, and nested structs |
| Pointers | `*T`, `*volatile T`, `[*]T`, `[*]volatile T`; nonvolatile `*Struct` |
| Optionals | Scalars, enums, and supported pointers |
| Unions | Narrow `union(enum)` with scalar, enum, pointer, or payloadless fields |
| Strings | Module constants and fixed-capacity mutable buffers |

There is no `u32`, floating point, slice, sentinel, general heap-owned value, error union, or arbitrary-width integer support.

`usize` is 16-bit. Pointers are 16-bit C64 addresses. `@alignOf` is `1` for every supported type.

## Bindings and functions

Local `var` and `const` bindings use static storage unless the function is assigned to the software-stack ABI. Type inference is limited to supported scalar expressions.

```zig
fn add(a: u8, b: u8) u8 {
    return a + b;
}

export fn main() void {
    var total: u16 = 0x0100;
    const step = add(2, 3);
    total += step;
}
```

Functions accept supported scalar, pointer, and fixed-layout struct parameters and returns. Arrays are storage, not by-value arguments or return values. Recursive calls require the software-stack subset.

## Expressions

Supported operations include:

- assignment and `+=`, `-=`, `*=`, `&=`, `|=`, `^=`, `<<=`, `>>=`;
- `+`, `-`, unsigned `*`, bitwise operators, shifts, and unary `~`;
- `==`, `!=`, and unsigned ordering comparisons;
- `!`, short-circuit `and`, and short-circuit `or`;
- scalar expression-valued `if`, `switch`, and labeled blocks;
- calls, field paths, array indexes, pointer access, and supported built-ins.

Signed storage is supported, but signed ordering, multiplication, division, and remainder are not. Arithmetic keeps the low byte or low 16 bits of the destination width.

`@as(T, value)` supports fitting literals, unsigned widening, exact enum contexts, and exact pointer annotations. It is not a general cast facility. `@ptrFromInt` and `@intFromPtr` support scalar and enum pointers; raw integer-to-struct pointers are rejected.

## Control flow

```zig
if (ready) {
    run();
} else {
    wait();
}

while (count != 0) {
    count -= 1;
}

for (items, 0..) |item, index| {
    if (item == 0) continue;
    if (index == 8) break;
}

const result = switch (key) {
    c64.key.space => 1,
    else => 0,
};
```

`for` supports fixed arrays and zero-based fixed ranges. Payloads are read-only copies. Runtime indexes are unchecked; literal out-of-range indexes are compile errors.

`switch` supports scalar selectors, comma lists, unsigned ranges, optionals, and tagged unions. Payload captures are read-only.

## Arrays and structs

Fixed arrays use contiguous byte layout. Word elements are low byte first. Arrays of structs use array-of-records layout.

```zig
const Point = struct { x: u8, y: u8 };

var points: [2]Point = .{
    Point{ .x = 1, .y = 2 },
    Point{ .x = 3, .y = 4 },
};

points[1].x += 1;
```

Structs are flattened, fixed-layout records. Exact-type copies, parameters, and returns copy every field. Layout-compatible conversion between different struct names is not supported.

Supported near-pointer and optional-pointer fields occupy two bytes, including
nested records, ordinary record copies, arguments and aggregate return storage.
Their field getters return both bytes in A/X. This representation does not add
pointer arithmetic, integer-to-pointer field coercions or general casts; the
existing typed construction and unsupported-context checks still apply.

Each fixed array is limited to 255 bytes. Slices, runtime bounds checks, by-value array assignment, nested arrays, and arrays of strings or unions are not supported.

An indexed compound assignment evaluates the index once, reads the old element,
evaluates the right-hand expression, then writes the result to the captured
element. This applies to scalar arrays, many-item pointers, and scalar array
fields reached through a struct pointer. For a direct many-item pointer binding,
the index runs before the pointer value is loaded. A struct pointer is captured
before evaluating the index of its array field.

## Enums, optionals, and unions

`enum(u8)` values are one-byte tags. Context-typed literals such as `.ready` work when the destination enum is known.

Scalar and enum optionals use a present byte followed by payload storage. Optional pointers use `$0000` as `null`.

```zig
if (maybe_value) |value| {
    use(value);
}
```

Narrow tagged unions use a one-byte tag and fixed payload area. Payloads are observed only through `switch` captures.

```zig
const Event = union(enum) {
    none,
    key: u8,
};

switch (event) {
    .key => |key| handle(key),
    .none => {},
}
```

## Pointers and volatile memory

Single-item pointers use `ptr.*`. Many-item pointers use `ptr[index]`. Struct pointers use Zig-style auto-deref field access.

```zig
const border: *volatile u8 = @ptrFromInt(0xd020);
border.* = 5;

const screen: [*]volatile u8 = @ptrFromInt(0x0400);
screen[0] = 'A';
```

Volatile access emits a real load or store. Pointer arithmetic, pointer comparison, slices, pointer-to-pointer, and array-to-pointer decay are not supported.

Address-of is supported for mutable scalar storage, literal-index scalar array elements, mutable structs, and mutable nested struct fields.

## Strings

Module string constants are fixed, length-counted byte tables. Mutable strings have static storage and fixed capacity.

```zig
const title = "READY";
var line = c64.string.buffer(32);

c64.string.append(line, title ++ "!");
c64.console.puts(line);
```

Use `c64.string.petscii` or `c64.string.ascii` when the byte encoding must be explicit. See the [Library API](api.md).

## Compile-time evaluation

Compile-time support is intentionally narrow:

- literals and enum tags;
- string concatenation;
- array lengths using literal arithmetic;
- `@sizeOf`, `@alignOf`, and `@offsetOf` for supported target types;
- configuration and module metadata;
- compile-time names used by heap and module APIs.

General `comptime`, reflection, type construction, target-function execution, and Zig's full cast family are not supported.

## Machine declarations

The main source can declare a `memory` block. Regions have literal addresses and byte sizes. C64 regions default to `.visible`. Declare `bank .ram_under_basic` or `bank .ram_under_kernal` explicitly for RAM behind ROM. Named claims resolve against the region table and are checked for address space, bank visibility, bounds, and overlap.

```zig
memory {
    region call_stack: c64 at 0xc800 size 0x0400;
    region work_ram: c64 at 0x9000 size 0x0800;
    region sprite_ram: c64 at 0x9800 size 0x0100;
    region asset_ram: reu at 0x010000 size 0x2000;
    region hidden: c64 at 0xe000 size 0x0400 bank .ram_under_kernal;

    stack in call_stack;
    arena scratch in work_ram;
    pool sprites in sprite_ram block 16;
    arena assets in asset_ram;
    placement cold in hidden load .startup_copy;

    image prg {
        load_addr = 0x0801;
        entry_addr = 0x1000;
        basic_stub = true;
        address_limit = 0xc600;
    }
}
```

`address_limit` is exclusive. A BASIC stub requires `load_addr = 0x0801`. Use `basic_stub = false` for a raw machine-language PRG. The entry may differ from the load address and must follow the BASIC stub when present.

Use `callconv(.stack)` on a function that requires a software-stack frame. `callconv(.static)` requests a fixed frame explicitly. Unannotated functions default to static frames. An explicit convention pins the function as an ABI root. A stack declaration can include `zp sp 0x30 fp 0x32` when the zero-page policy admits those pairs.

```zig
fn worker(n: u8) callconv(.stack) u8 { return n + 1; }

const cold_table: [2]u8 linksection("cold") = .{ 3, 7 };
fn lookup(index: u8) linksection("cold") u8 { return cold_table[index]; }
```

`callconv` and `linksection` use Zig grammar with ZeroPage-specific meanings. Both take restricted literal arguments. A placement names its run region and uses `.direct` by default. `.startup_copy` keeps the load image compact and copies the placement to that region before `main`. The compiler emits bank-switching gateways for supported placed functions. The current placement subset supports static functions and constant strings or arrays. The stack and near heaps use visible C64 RAM.

Heap declarations bind compile-time names usable in calls such as `scratch.allocBytes(n)`, `scratch.reset()`, and `sprites.free(ptr)`. A REU region makes `arena assets` a far arena. A `pool` always uses visible C64 RAM. Ordinary allocation sizes continue to accept the supported expression grammar. Materialize REU data with `view.materialize(scratch)` or `view.materializeRange(scratch, start, count)` and write back with the explicit flush operation.

`module name abi 1 { … }` declares a DLL, `extern module Binding = name { … }` declares its typed imports, and `module_loader { … }` declares the execution windows, REU cache, staging, and per-module load/state policy. See [REU and modules](reu-overlays.md) for the full syntax and [ABI](abi.md) for call and export rules.

The older `zeropage_options` and `zeropage_module` forms remain accepted for existing sources. The same setting cannot be declared through both spellings. The main source owns the application memory map and DLL configuration. Imported source functions can declare a convention and use the main program’s configured stack.

## Inline assembly

`asm { ... }` is an intentional syntax extension beyond Zig. The block contains a restricted 64tass-style 6502/6510 instruction surface and is extracted before Zig parsing.

A standalone absolute `jmp $hhhh` block is the terminal-transfer form for resident OS/ROM ABI vectors; it does not return to the surrounding ZeroPage function.

See [Inline assembler](inline-assembler.md) for operands, local labels, preservation rules, and diagnostics.

## Test fixtures

`@import("test6502")` is accepted only for host-emulated fixtures. It provides expression assertions and CPU/memory observation hooks. Production programs should use `c64` and `ZeroPage` only.

## Explicitly unsupported

ZeroPage rejects features for which it has no defined storage or lowering model. Major examples include:

- `std`, packages, generics, methods, and full namespace semantics;
- slices, dynamic arrays, error unions, `try`, `catch`, `defer`, and `errdefer`;
- general comptime, reflection, async, threads, and exceptions;
- general pointer casts or arithmetic;
- full Zig inline assembly;
- implicit module loading or runtime reflection.

The compile-fail fixtures under `tests/fixtures/emu/lang/fail_compile/` are the executable record of these boundaries.


## Application zero-page settings

Declare zero-page policy within `memory` in the main source:

```zig
memory {
    zero_page {
        profile = .kernal;
        allocation = .scalars;
        reserve at 0x40 size 4;
        restore_basic = true;
        interrupts = .system;
    }
}
```

Profiles are `.compatibility`, `.basic`, `.kernal`, and `.bare`. Allocation modes are `.off`, `.scratch`, and `.scalars`. One or more `range at ADDRESS size BYTES;` clauses replace the profile’s candidate ranges. `reserve` subtracts application-owned bytes. `restore_basic` controls restoration on normal return, and `interrupts` selects `.system` or `.application` ownership. Addresses and sizes are literal machine metadata. See the exact pools and IRQ/NMI contracts in the [memory model](memory-model.md).

`.scratch` permits compiler scratch placement. `.scalars` also permits placement
of eligible private static-frame parameters: `bool`, `u8`, `i8`, `u16`, `i16`,
`usize`, byte enums and supported near pointer values. A pointer's value can be
passed or returned without exposing its parameter slot; taking `&parameter`
exposes the slot and prevents its promotion. Locals, return cells, arrays,
aggregate fields, optionals and handles are outside this promotion subset.

Entry/exported functions, explicitly configured ABI roots, fixed-placement
functions, software-stack frames, modules/loaders and recursive call-graph
members are excluded. A retained inline-assembly function conservatively
disables all parameter promotion; unresolved calls also exclude their callers.
The emitted definition must be one uniquely owned, zero-initialized scalar cell
of the declared width, with no aliases, indexed access or escaping address.
Eligible cells compete with scratch for capacity and spill intact to resident
storage when they do not fit; distinct cells never share lifetime-overlaid slots.
The map records each parameter's eligibility reason and placement status.

Application fixed-address bytes inside a candidate pool **must** appear in
`.reserve`, including bytes reached through literal pointers, assembly or
interrupt handlers. Declaring a pool grants the compiler ownership of its
unreserved bytes. The compiler does not infer reservations from arbitrary pointer
values or rewrite literal addresses to follow promoted cells.
