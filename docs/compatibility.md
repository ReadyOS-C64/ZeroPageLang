# Compatibility

ZeroPage is pre-1.0. The package version is `0.1.0`, and source, ABI, sidecar, and CLI details may change while the language is being defined.

## Stable project identifiers

- Product and language: ZeroPage
- Compiler: `zp64c`
- Zig package: `.zeropage`
- Source extension: `.zp64`
- Built-in module: `@import("ZeroPage")`
- Machine declarations: `memory`, `module`, `extern module`, and `module_loader`

## Versioned formats

Module JSON and binary sidecars carry their own format versions. Readers must reject unknown versions rather than guessing. Generated assembly labels and map files are debugging and tooling interfaces; they are kept stable where tests depend on them, but they are not yet a permanent external ABI.

## Language changes

Valid Zig syntax is not automatically valid ZeroPage. The compiler parses with Zig first, then accepts only the documented ZeroPage subset. Unsupported constructs produce explicit diagnostics.

Before 1.0, a change may remove or narrow behavior when the previous behavior was ambiguous, unsafe on the C64, or inconsistent with Zig syntax. Such changes should include tests, documentation, and an entry in [CHANGELOG.md](../CHANGELOG.md).

No migration guide is maintained yet because ZeroPage has no released compatibility boundary. When the first public release establishes one, migrations will be documented by release.
