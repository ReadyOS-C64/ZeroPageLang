# Dependencies

ZeroPage has no packages in `build.zig.zon`. The normal compiler build uses the Zig standard library supplied by the pinned host toolchain.

## Vendored source

The repository includes two third-party source trees under `third_party/`.

| Component | Included source | Used by | License |
| --- | --- | --- | --- |
| Zig parser reference, 0.16.0 | `third_party/zig-parser/std-zig/`, a copy of Zig's `lib/std/zig` subtree | Local parser/AST reference only | MIT; see `third_party/zig-parser/LICENSE-ZIG` |
| Peddle, commit `c23e34a7e6516b284750b8c7caaa8c41948a407a` | MOS 65xx CPU core under `third_party/peddle/Peddle/` | Peddle-backed host emulation tests | MIT; see `third_party/peddle/LICENSE` |

The vendored Zig subtree is not compiled or linked. `zp64c` calls `std.zig.Ast.parse` from the host Zig 0.16.0 standard library; the copy exists so parser behavior can be reviewed and adapted against the exact pinned release.

Peddle is compiled only into `zeropage_emu_tests` and its tests. It is not linked into `zp64c`. `third_party/peddle/zeropage_peddle.cpp` and `.h` are the ZeroPage integration shim.

## Required tools

| Tool | Version | When required |
| --- | --- | --- |
| Zig | 0.16.0 | Building `zp64c`, running unit tests, and providing the active Zig parser |
| 64tass | 1.60.3243 | `zp64c compile`, assembler-backed tests, and PRG generation |
| Bash and Perl | Host tools | Shell-based test scripts and binary artifact checks |
| C++20 | Zig's bundled toolchain and libc++ | Compiling Peddle for `test` and `emu-test` |

## Optional and test-only tools

| Tool | Purpose |
| --- | --- |
| VICE `x64sc` | Real C64 integration and UI automation |
| VICE `c1541` | Packaging and checking D64 images for `e2e`, `asm-test`, `size-report`, and `vice-test` |
| .NET SDK | Running the external VICE task harness |
| `vice_tasks_dotnet` harness | Compiling and executing generated VICE YAML plans |
| Python 3.12+ | Preparing the isolated macOS VICE bridge and optimization reports |

Install 64tass, VICE, and the .NET SDK separately. The VICE task harness and ROM images also come from outside this repository. ZeroPage ships its own [sample D64 images](../README.md#try-the-sample-disks).

When using the default sibling VICE harness, test scripts prepare an isolated
copy under `build/vice-harness/`. Its monitor bridge source is pinned to
`MihaMarkic/vice-bridge-net` revision
`b75ed9940ff2c3e3da795aeea190ae4a9ad51e87`, archive SHA-256
`f148be9d384d6b8850cce788f081e216f532619a90a93af901f09aedc5269330`.
The existing MIT license remains in the extracted source. The local patch
connects directly instead of depending on macOS TCP-listener enumeration, and
adds retry backoff. This is the same bridge fix used by the sibling compiler
comparison projects. Installed tools and sibling sources are not modified.
An explicit `ZEROPAGE_VICE_TASKS` project is used directly, so it should already
contain any platform-specific bridge fixes it needs.

The compiler checks environment overrides, local tool locations, then `PATH`. Some repository scripts invoke tools directly. See the [getting-started guide](getting-started.md#tool-lookup).

## Licensing

ZeroPage is licensed under the repository [MIT license](../LICENSE). Vendored projects retain their own copyright notices and license files; the project license does not replace them.
