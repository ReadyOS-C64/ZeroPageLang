# Zig reference notes

ZeroPage pins Zig 0.16.0 for host builds and syntax behavior.

## Parser contract

Source is parsed with `std.zig.Ast.parse` from the pinned host Zig before ZeroPage lowering. A Zig syntax error stops compilation. Valid Zig syntax may still be rejected when it falls outside the documented ZeroPage subset.

ZeroPage uses a preparser for `asm { ... }` and source-level machine declarations. It replaces assembly with Zig-valid placeholders and masks the machine declaration syntax while preserving source offsets. Zig still validates function bodies, ordinary declarations, and typed DLL prototypes. ZeroPage checks the machine-specific grammar and restores the assembly during lowering. See [Inline assembler](inline-assembler.md).

## Vendored reference

`third_party/zig-parser/std-zig/` is a copy of Zig 0.16.0's `lib/std/zig` subtree. It is kept for source review and future adaptation; the normal build does not compile or link it.

Verify the copy against the pinned toolchain with:

```sh
diff -qr third_party/zig-parser/std-zig ../zeropage-tooling/reference/zig-0.16.0/lib/std/zig
```

## Behavior audits

Use `../zeropage-tooling/reference/zig-0.16.0/test/behavior` as the release source of truth. Broad searches may use the indexed `github://ziglang/zig` repository, but results from newer Zig revisions must not silently redefine ZeroPage 0.16.0 behavior.

Parity work belongs in categorized fixtures under `tests/fixtures/emu/lang/pass/parity/`. Unsupported-but-valid Zig belongs in compile-fail fixtures with a focused ZeroPage diagnostic.
