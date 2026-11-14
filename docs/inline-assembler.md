# Inline Assembler

ZeroPage supports small inline 6502/6510 assembly blocks inside function bodies:

```zig
asm {
    lda #$00
    sta $d020
loop:
    inc $d021
    bne loop
}
```

The feature is deliberately close to Turbo Pascal-style inline assembler: simple source text, local labels, and direct machine-facing intent. The block body uses 64tass-style instruction and operand syntax, then ZeroPage analyzes and emits it into the generated 64tass assembly.

## Design

`asm { ... }` is ZeroPage syntax, not native Zig syntax. To keep Zig's parser as the syntax front door for the rest of the language, the compiler runs a narrow preparser before `std.zig.Ast.parse`:

- statement-level `asm { ... }` blocks are extracted into an inline-asm side table;
- each block is replaced with a Zig-valid placeholder call such as `zeropage_inline_asm_0();`;
- Zig's parser validates the rewritten source;
- ZeroPage lowering turns each placeholder call into an `inline_asm` AST statement pointing back to the extracted source text and original source position.

The preparser only recognizes statement-boundary `asm { ... }` blocks and ignores `asm {` text inside strings and `//` comments.

## Supported v1 Surface

Inline asm v1 accepts:

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

Function parameters and locals with 8-bit storage may be read and written from inline asm with `@name`. This currently includes `u8`, `i8`, and `bool`; character values are represented with `u8` storage.

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

## Register and Flag Preservation

ZeroPage analyzes each inline asm block for `A`, `X`, `Y`, and processor status flag clobbers. It emits save/restore code only for the state the block can change.

External `jsr` targets, including KERNAL calls such as `$ffd2`, are treated conservatively as clobbering `A`, `X`, `Y`, and flags. Memory writes are intentional side effects and are not sandboxed.

Example generated shape:

```asm
    php
    pha
    lda #$00
    sta $d020
    pla
    plp
```

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
