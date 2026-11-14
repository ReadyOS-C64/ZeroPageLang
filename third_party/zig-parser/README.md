# Zig Parser Reference

This folder vendors Zig `0.16.0` frontend/parser support sources as an authoritative syntax reference for ZeroPage.

Source: Zig `0.16.0` `lib/std/zig`, copied from the pinned local toolchain reference at:

```text
../zeropage-tooling/reference/zig-0.16.0/lib/std/zig
```

Included source:

- `std-zig/`, a byte-for-byte copy of Zig `0.16.0`'s `lib/std/zig` subtree.
- `LICENSE-ZIG`

Verify the vendored subtree with:

```sh
diff -qr third_party/zig-parser/std-zig ../zeropage-tooling/reference/zig-0.16.0/lib/std/zig
```

ZeroPage parses with Zig's own parser first, then lowers only the supported subset into `src/ast.zig`. Unsupported valid Zig syntax belongs in semantic/lowering diagnostics, not in an ad hoc syntax fork.

The active compiler currently calls `std.zig.Ast.parse` from the pinned host Zig toolchain. The normal `zig build` path does not compile or link this vendored subtree. This copy exists so future work can adapt or inspect the same parser/AST implementation locally without guessing at supporting modules.

Current target build flow:

1. ZeroPage source is loaded.
2. ZeroPage machine declarations are isolated and inline assembler blocks are replaced with Zig-valid placeholders.
3. The rewritten source is parsed by host Zig's `std.zig.Ast.parse`.
4. ZeroPage lowering accepts the supported subset and rejects unsupported-but-valid Zig constructs.
5. Codegen emits 64tass assembly.
6. 64tass produces the final C64 `.prg`.
