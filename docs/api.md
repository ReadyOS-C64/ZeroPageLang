# Library API

ZeroPage exposes two compiler-provided modules:

```zig
const c64 = @import("c64");
const ZeroPage = @import("ZeroPage");
```

These are built-ins, not source packages. Calls are validated and lowered directly by the compiler.

## `c64`

### VIC-II

```zig
c64.vic.border = color;
```

Writes the low color value to `$D020`.

### Screen

```zig
c64.screen.clear();
c64.screen.putAt(x, y, value);
c64.screen.putsAt(x, y, "TEXT");
c64.screen.hexAt(x, y, byte_value);
c64.screen.hex16At(x, y, word_value);
```

These helpers write screen RAM directly. Coordinates and values use the supported scalar expression grammar.

### Console

```zig
c64.console.clear();
c64.console.puts(message);
c64.console.print("HP {x} SCORE {x16}\n", .{ hp, score });
```

`print` uses a Zig-shaped anonymous tuple. Supported fields are `{s}` for a string, `{x}` for a byte, and `{x16}` for a word. Strings are length-counted PETSCII data, not NUL-terminated C strings.

To print a word stored in a record, copy the field into a named `u16` local
and pass that local to `{x16}`. In the preview, a direct field argument
prints its low byte with a zero high byte. See the
[aggregate return example](tutorial-examples/aggregate-return.zp64).

### KERNAL and keyboard

```zig
c64.kernal.puts(message);
c64.kernal.setName(filename);

const key = c64.keyboard.readPetscii();
const pressed = c64.keyboard.waitPetscii();
```

`readPetscii` returns `0` when no buffered key is available. `waitPetscii`
waits for the first nonzero byte, drains the buffer until GETIN returns zero,
then returns that first byte. It tests buffer availability rather than the
physical key state. `c64.key` provides named PETSCII key constants such as
`space`, `return_`, cursor keys, edit keys, function keys, and colors.

### Strings

```zig
const label = c64.string.petscii("READY");
const bytes = c64.string.ascii("HOST DATA");
var message = c64.string.buffer(32);

c64.string.clear(message);
c64.string.append(message, label ++ "!");
```

Buffers have fixed capacity and static storage. Append truncates at capacity. ASCII and PETSCII wrappers make the intended byte encoding explicit.

### Timing and control bytes

```zig
c64.time.sleepTicks(count);
c64.time.sleepFrames(count);
```

Both are busy waits. `c64.petscii` provides control bytes such as `clear`, `home`, `return_`, reverse-video controls, and colors.

## `ZeroPage`

### Near heaps

Declare a near `arena` or `pool` in `memory`, then use its name:

```zig
const block = scratch.allocBytes(16);
scratch.reset();
sprites.free(ptr);
```

Arena heaps support allocation and reset. Fixed-block heaps also support `free`. Allocation returns an optional many-item byte pointer. Heap names and regions are compile-time configuration; no allocator metadata is discovered dynamically.

### Raw REU operations

```zig
const available = ZeroPage.reu.present();
ZeroPage.reu.copyC64ToReu(c64_addr, reu_addr, len);
ZeroPage.reu.copyReuToC64(reu_addr, c64_addr, len);
ZeroPage.reu.swap(c64_addr, reu_addr, len);
ZeroPage.reu.compare(c64_addr, reu_addr, len);
ZeroPage.reu.fill(reu_addr, value, len);
```

REU addresses are 24-bit far addresses supplied as compile-time integers. REU memory cannot be cast to a normal C64 pointer.

### Far heaps and views

```zig
const maybe_far = assets.allocBytes(byte_count);

if (maybe_far) |far| {
    ZeroPage.reu.copyFromC64(far, c64_addr, len);
    ZeroPage.reu.copyToC64(far, c64_addr, len);

    var enemies = ZeroPage.reu.view(Enemy, far, 8);
    enemies.set(0, Enemy{ .hp = 10 });
    const first = enemies.get(0);
}
```

Far handles and views are opaque compiler-known values. A typed view can be materialized into a named near arena with `materialize` or `materializeRange`, edited with `get` and `set`, then copied back with `flush` or `flushRange`.

### Modules

Declare the export signature with `extern module` and call it through the binding:

```zig
extern module MathCore = math_core {
    fn add(value: u8) u8;
}

if (MathCore.load()) {
    if (MathCore.add(3)) |sum| {
        // Use sum.
    }
    MathCore.release();
}
```

The prototype describes the export payload. Here, `MathCore.add(3)` returns `?u8` because the module may be unavailable at runtime. The compiler checks the prototype against source exports for the current module and against build-time sidecars for dependencies. It resolves rows, windows, relocations, and ordinals at build time.

Low-level module operations use compile-time ids and export names:

```zig
ZeroPage.module.load("enemy_runtime");
ZeroPage.module.loadFromDisk("enemy_runtime", "enemyrt");
ZeroPage.module.loadDependency("math_core");
ZeroPage.module.acquireDependency("math_core");
ZeroPage.module.releaseDependency("math_core");
ZeroPage.module.loadDependencyGraph("math_core");
ZeroPage.module.acquireDependencyGraph("math_core");
ZeroPage.module.releaseDependencyGraph("math_core");
ZeroPage.module.isLoaded("math_core");
ZeroPage.module.unloadDependency("math_core");

const result = ZeroPage.module.call("math_core", "add", .{3});
```

Calls return optionals because an unloaded module is not callable. `load*` ensures residency; `acquire*` adds ownership. Release or unload clears callability only when the row's refcount reaches zero.

See [ABI](abi.md) and [REU and DLLs](reu-overlays.md) for loader and dispatch details.

## Test-only API

`@import("test6502")` is available only to host-emulated fixtures. It provides expression assertions, CPU/memory observations, register priming, and explicit pass/fail hooks. Production programs should not import it.
