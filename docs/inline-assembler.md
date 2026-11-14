# ZeroPage inline assembly

ZeroPage supports statement-level inline 6502/6510 assembly in static-frame
functions. The block below changes the VIC-II border. The compiler restores A
and processor status when the block ends.

```zig
asm {
    lda #$05
    sta $d020
}
```

The block body uses 64tass-style instruction and operand syntax. ZeroPage
analyzes the instructions, resolves source operands, and emits the block into
the generated 64tass assembly.

## Design

`asm { ... }` is ZeroPage syntax, not native Zig syntax. To keep Zig's parser as the syntax front door for the rest of the language, the compiler runs a narrow preparser before `std.zig.Ast.parse`:

- statement-level `asm { ... }` blocks are extracted into an inline-asm side table;
- each block is replaced with a Zig-valid placeholder call such as `zeropage_inline_asm_0();`;
- Zig's parser validates the rewritten source;
- ZeroPage lowering turns each placeholder call into an `inline_asm` AST statement pointing back to the extracted source text and original source position.

The preparser only recognizes statement-boundary `asm { ... }` blocks and ignores `asm {` text inside strings and `//` comments.

## Supported v1 Surface

Inline assembly accepts the following forms:

- NMOS 6502/6510 mnemonics;
- 64tass-style operands such as `#$00`, `$d020`, `$0400,x`, and `$ffd2`;
- ZeroPage byte variable operands written as `@name`;
- ZeroPage string storage operands written as `@name.data`, `#<@name.data`, `#>@name.data`, `#@const_name.len`, and `@buffer_name.len`;
- blank lines and `;` comments;
- labels written as `name:`;
- branches and `jmp` to labels in the same block;
- a standalone absolute `jmp $hhhh` block for terminal ABI transfers such as a resident OS shim vector;
- external numeric or symbolic `jsr` operands.

Labels are scoped to a single asm block. Multiple asm blocks in the same function may reuse the same label names because codegen rewrites them to generated labels such as `zeropage_asm_0_loop`.

Byte parameters and mutable locals can be read and written with `@name`.
The byte types include `u8`, `i8`, `bool`, and `enum(u8)`. Character
values use `u8` storage.

```zig
fn copyWithAsm(unsigned_param: u8, signed_param: i8, glyph_param: u8, flag_param: bool) void {
    var unsigned_local: u8 = 0;
    var signed_local: i8 = 0;
    var glyph_local: u8 = ' ';
    var flag_local: bool = false;

    asm {
        lda @unsigned_param
        clc
        adc #1
        sta @unsigned_local
        lda @signed_param
        sta @signed_local
        lda @glyph_param
        sta @glyph_local
        lda @flag_param
        sta @flag_local
    }
}
```

The `@` prefix is ZeroPage-only syntax. The compiler rewrites it to the generated 64tass storage label, such as `copyWithAsm_unsigned_param`, after checking that the referenced variable exists and is byte-sized.

String interop uses explicit suffixes so inline asm does not rely on generated label names:

```zig
const source = "asm string ok";

export fn main() void {
    var msg = c64.string.buffer(32);
    asm {
        ldy #0
copy:
        lda @source.data,y
        sta @msg.data,y
        iny
        cpy #@source.len
        bne copy
        lda #@source.len
        sta @msg.len
    }
}
```

`@name.data` resolves to the byte data for a module-scope string constant or mutable string buffer. `#<@name.data` and `#>@name.data` produce pointer low/high immediates for KERNAL or custom routines. `#@const_name.len` produces an immediate byte length for a module-scope string constant. `@buffer_name.len` resolves to the mutable buffer's runtime length byte.

## Constraints

Inline asm v1 rejects:

- 64tass directives, macros, includes, and data declarations;
- duplicate labels inside one block;
- branch targets outside the current block, symbolic external `jmp` targets, and non-standalone absolute jumps;
- local `jsr` targets inside the same block;
- `@name` references to non-existent variables or non-byte variables;
- bare string operands such as `@string_name` without `.data` or `.len`;
- writes to module-scope string constant data;
- immediate mutable buffer lengths such as `#@buffer.len`;
- unknown string suffixes such as `@buffer.ptr`;
- immediate variable operands such as `#@name`;
- `rts`, `rti`, and `brk`;
- stack-mutating instructions such as `pha`, `pla`, `php`, `plp`, `tsx`, and `txs`;
- relative branches that ZeroPage can determine are outside the 6502 branch window.

The standalone absolute jump is an intentional terminal-control-flow exception. It must be the only line in its asm block, so the block has no compiler-saved clobbers to abandon. It is intended for stable ROM or resident-shim vectors that do not return to the ZeroPage caller.

The remaining constraints keep inline asm from silently escaping function control flow or corrupting the compiler's save/restore wrapper. Data directives and richer 64tass fragments can be added later with a clearer placement model.

## Diagnostics

ZeroPage reports its own errors for unsupported inline-asm features before handing generated assembly to 64tass. This includes duplicate labels, nonlocal jumps, unsupported directives, forbidden instructions, and branch-window failures.

64tass still performs final assembly validation, so operand syntax and assembler-level errors continue to come from the assembler backend.

## Testing

The inline assembler is covered by:

- preparser unit tests for extraction, placeholder rewriting, source positions, strings/comments, and unterminated blocks;
- analyzer unit tests for duplicate labels, nonlocal jumps, clobber handling, and branch range checks;
- codegen unit tests for generated labels and preservation wrappers;
- codegen unit tests for stable string operand rewriting and rejected unsafe string forms;
- assembler-backed small-demo coverage through `examples/small/10_inline_asm.zp64`;
- string interop small-demo coverage through `examples/small/16_inline_asm_strings.zp64`;
- optional VICE smoke coverage for visible screen output after inline asm and an external KERNAL `jsr`.

## Source operands and storage

Use `@name` for a byte parameter or mutable byte local in a static-frame
function. It names the storage cell. `lda @value` reads the current byte,
`sta @value` writes it, and `inc @value` performs a memory read-modify-write.
A parameter is passed by value. An assembly store to its cell changes the
callee's copy. A Boolean cell should contain 0 or 1. A byte enum cell should
contain one of its declared tags. The assembler does not type-check values
written by the instructions.

A fixed-layout record parameter or local can expose a byte leaf through its
flattened name. For `actor.pos.x`, write `@actor_pos_x`. The name walks the
record's storage directly. It does not dereference a pointer. Dotted suffixes
are reserved for the string forms below. Use byte leaves and mutable storage for
writes. Whole records, array elements, words, and pointers have no documented
`@name` operand for selecting their component bytes. Use a Zig-shaped wrapper to
prepare byte inputs and reassemble outputs. An ordinary scalar `const` has no
`@name` binding. Use a literal for a known immediate.

| Operand | Meaning |
| --- | --- |
| `@delta` | The static byte parameter or local cell |
| `@actor_pos_x` | Byte leaf of a flattened local or by-value parameter |
| `@source.data,y` | Indexed read from a module string's data |
| `@buffer.data+1` | Address expression based on mutable buffer storage |
| `#<@source.data`, `#>@source.data` | Immediate low and high address bytes. These forms also accept a mutable buffer |
| `#@source.len` | Immediate length of a module-scope string constant |
| `@buffer.len` | Mutable buffer's runtime length cell |
| `#$05`, `$d020`, `$0400,x` | Literal immediate, absolute, and indexed operands passed to 64tass |
| `($30),y` | Indirect indexed addressing through an application-controlled zero-page pointer pair |

Raw addressing forms are validated by 64tass. An indirect operand names the
zero-page cell holding the pointer, so the program must initialize and own that
pair. Default compiler pointer scratch includes `$fb–$fe`; use a pair admitted
and reserved by the application policy instead of assuming a default scratch
pair survives generated code. Numeric addresses and compiler-generated labels
are outside the typed operand interface. The
[indirect example](tutorial-examples/asm-indirect.zp64) initializes a reserved
pair with a string address, reads through Y, and restores the borrowed BASIC
bytes itself. Compiler zero-page cleanup restores compiler claims. The register
wrapper does not restore assembly-owned RAM.

String data is length-counted. When copying into a mutable buffer, bound the
copy by its capacity and write the resulting length yourself. The compiler
rejects recognized writes to constant string data, including memory shifts and
increments. It does not bounds-check numeric or indexed assembly operands.
Use `#<` and `#>` for string addresses. Bare `#@source.data`, bare string
names, and `#@buffer.len` are rejected.

The [record example](tutorial-examples/asm-record.zp64) reads a by-value record
parameter, adjusts a mutable nested field, and stores an enum tag. The
[buffer example](../examples/small/16_inline_asm_strings.zp64) copies a string
using indexed addressing and updates the buffer length.

### Pass word data and capture a KERNAL result

For a two-byte counter, put the low and high bytes in a record. The
[word example](tutorial-examples/asm-word.zp64) reads them as
`@counter_low` and `@counter_high`. It clears decimal mode and carry, adds
the low byte, stores it, then propagates carry into the high byte.
`LDA` and `STA` leave carry intact. The wrapper restores the incoming
flags, so the two result cells carry the answer back to source code.
ZeroPage widens and combines those bytes into a `u16`.

The [GETIN example](tutorial-examples/asm-getin.zp64) calls the visible
KERNAL jump table at `$ffe4`. Store A to a mutable byte with `sta @key`
inside the block. The wrapper restores the caller's A before execution
returns to source code. For a routine that communicates through flags,
branch inside the block and store a byte result before fallthrough.

The [checked KERNAL load example](tutorial-examples/asm-kernal-load.zp64)
uses the filename's length and address with SETNAM, sets device parameters
with SETLFS, and branches on carry immediately after LOAD. The Boolean
stored before fallthrough survives register restoration. LOAD writes to
RAM and uses KERNAL workspace. The example pairs a known small file with a
reserved staging region.

## Preservation at a glance

The analyzer combines clobbers across the entire block, including instructions
on alternate paths. The wrapper saves state at entry and restores it on normal
fallthrough. This is the generated wrapper's hardware-stack use:

| Block operation | Saved state | Bytes |
| --- | --- | --- |
| `sta $d020`, `stx $0400`, `nop` only | None | 0 |
| `cmp #$05`, `bit $d011`, `inc @value`, `clc` | P | 1 |
| `lda #$05` or accumulator `asl a` | P, A | 2 |
| `ldx #3` or `ldy #3` | P, A, X or Y | 3 |
| A block that changes both X and Y, or any external `jsr` | P, A, X, Y | 4 |

Saving X or Y uses `TXA` or `TYA` and a push. The wrapper also saves A
because those transfers use it as a temporary. Restores run in reverse order.
`PLP` comes last so the flags set by `PLA`, `TAX`, or `TAY` do not leak out.
The byte counts exclude return addresses, interrupts, and any stack use in the
called routine. Prepare registers and branch on the resulting flags inside the
same block. To use a result in ZeroPage, write it to an eligible local before
fallthrough. A later block sees the surrounding program's register state.

For example, this block calls KERNAL CHROUT with PETSCII `A` in A. The
compiler saves all four pieces of state around it:

```asm
php
pha
txa
pha
tya
pha
lda #$41
jsr $ffd2
pla
tay
pla
tax
pla
plp
```

The [host fixture](../tests/fixtures/emu/lang/pass/parity/strings_asm/inline_asm.zp64)
primes A, X, Y, and P, then checks them after a clobbering block and a
KERNAL call. It also verifies that a mutable byte store survives fallthrough
and the hardware stack pointer returns to its starting value.

The wrapper preserves CPU registers and flags. Stores to RAM, I/O,
the processor port, or a firmware routine's workspace remain observable.
Calls into ROM require a compatible bank mapping and ROM workspace.
Source zero-page policy must reserve fixed bytes owned by your assembly.
Retained opaque assembly also limits compiler optimizations, including optional
zero-page parameter promotion.

## Scope and exits

Each label occupies its own line. Use a name beginning with a letter or
underscore followed by letters, digits, or underscores. A branch or local
`jmp` names a label in that block. The relative range is −128 to +127
bytes from the instruction after the branch. ZeroPage checks estimated offsets,
and 64tass validates the assembled operands. An external `jsr` may use a
numeric address or a symbol resolved by the assembler. It must return with the
hardware stack balanced. Calls to a label inside the same inline block are
rejected.

The following block uses the special terminal form. The literal must use four
hexadecimal digits.

```zig
asm {
    jmp $c80c
}
```

This transfers directly to a resident entry point without
running a wrapper epilogue or returning to the enclosing ZeroPage function.
Use a documented vector whose calling contract matches the machine state.
Prepare required memory in ZeroPage before the jump. A preceding inline block
restores registers and flags at fallthrough, so it cannot pass values in those
registers to the terminal block. The ReadyOS shim shows real terminal transfers.
[ReadyOS example](../sampleapps/tictactoe_readyos/readyos_shim.zp64)

Inline blocks are supported in static-frame functions. Software-stack
functions and DLL export bodies reject them. Code executing under KERNAL has
additional restrictions on ROM and inline-assembly use. See the
[ABI](abi.md) and [banked module rules](reu-overlays.md#multiple-and-banked-windows).
