const std = @import("std");

// Small NMOS instruction/effect model. Unknown syntax is an optimization barrier.
pub const a: u16 = 1;
pub const x: u16 = 2;
pub const y: u16 = 4;
pub const sp: u16 = 8;
pub const c: u16 = 16;
pub const z: u16 = 32;
pub const n: u16 = 64;
pub const v: u16 = 128;
pub const i: u16 = 256;
pub const d: u16 = 512;
pub const nz = n | z;
pub const flags = c | nz | v | i | d;

pub const Op = enum {
    lda,
    ldx,
    ldy,
    sta,
    stx,
    sty,
    adc,
    sbc,
    @"and",
    ora,
    eor,
    cmp,
    cpx,
    cpy,
    inc,
    dec,
    asl,
    lsr,
    rol,
    ror,
    bit,
    tax,
    txa,
    tay,
    tya,
    tsx,
    txs,
    inx,
    dex,
    iny,
    dey,
    pha,
    pla,
    php,
    plp,
    clc,
    sec,
    cli,
    sei,
    cld,
    sed,
    clv,
    nop,
    jsr,
    jmp,
    rts,
    rti,
    brk,
    bcc,
    bcs,
    beq,
    bne,
    bmi,
    bpl,
    bvc,
    bvs,
};

pub const Symbol = struct { name: []const u8, offset: i32 = 0 };
pub const Operand = union(enum) {
    none,
    immediate: []const u8,
    direct: Symbol,
    indexed: struct { base: Symbol, register: u16 },
    indirect: []const u8,
    address: u16,
    unknown,
};
pub const Memory = enum { none, read, write, read_write, stack };
pub const Effects = struct { reads: u16 = 0, writes: u16 = 0, memory: Memory = .none, barrier: bool = false };

pub const Instruction = struct {
    op: Op,
    operand: Operand,

    pub fn parse(line: []const u8) ?Instruction {
        const text = std.mem.trim(u8, line, " \t\r");
        const split = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
        const op = std.meta.stringToEnum(Op, text[0..split]) orelse return null;
        return .{ .op = op, .operand = parseOperand(std.mem.trim(u8, text[split..], " \t")) };
    }

    pub fn effects(self: Instruction) Effects {
        const mem: Memory = switch (self.operand) {
            .none, .immediate => .none,
            else => .read,
        };
        var result: Effects = switch (self.op) {
            .lda => .{ .writes = a | nz, .memory = mem },
            .ldx => .{ .writes = x | nz, .memory = mem },
            .ldy => .{ .writes = y | nz, .memory = mem },
            .sta => .{ .reads = a, .memory = .write },
            .stx => .{ .reads = x, .memory = .write },
            .sty => .{ .reads = y, .memory = .write },
            .adc, .sbc => .{ .reads = a | c | d, .writes = a | nz | c | v, .memory = mem },
            .@"and", .ora, .eor => .{ .reads = a, .writes = a | nz, .memory = mem },
            .cmp => .{ .reads = a, .writes = nz | c, .memory = mem },
            .cpx => .{ .reads = x, .writes = nz | c, .memory = mem },
            .cpy => .{ .reads = y, .writes = nz | c, .memory = mem },
            .inc, .dec => .{ .writes = nz, .memory = .read_write },
            .asl, .lsr, .rol, .ror => .{
                .reads = (if (self.operand == .none) a else @as(u16, 0)) | (if (self.op == .rol or self.op == .ror) c else @as(u16, 0)),
                .writes = nz | c | (if (self.operand == .none) a else @as(u16, 0)),
                .memory = if (self.operand == .none) .none else .read_write,
            },
            .bit => .{ .reads = a, .writes = nz | v, .memory = mem },
            .tax => .{ .reads = a, .writes = x | nz },
            .txa => .{ .reads = x, .writes = a | nz },
            .tay => .{ .reads = a, .writes = y | nz },
            .tya => .{ .reads = y, .writes = a | nz },
            .tsx => .{ .reads = sp, .writes = x | nz },
            .txs => .{ .reads = x, .writes = sp },
            .inx, .dex => .{ .reads = x, .writes = x | nz },
            .iny, .dey => .{ .reads = y, .writes = y | nz },
            .pha => .{ .reads = a | sp, .writes = sp, .memory = .stack },
            .php => .{ .reads = flags | sp, .writes = sp, .memory = .stack },
            .pla => .{ .reads = sp, .writes = a | nz | sp, .memory = .stack },
            .plp => .{ .reads = sp, .writes = flags | sp, .memory = .stack },
            .clc, .sec => .{ .writes = c },
            .clv => .{ .writes = v },
            .cli, .sei => .{ .writes = i, .barrier = true },
            .cld, .sed => .{ .writes = d, .barrier = true },
            .nop => .{},
            .bcc, .bcs => .{ .reads = c, .barrier = true },
            .beq, .bne => .{ .reads = z, .barrier = true },
            .bmi, .bpl => .{ .reads = n, .barrier = true },
            .bvc, .bvs => .{ .reads = v, .barrier = true },
            .jsr, .jmp, .rts, .rti, .brk => .{ .barrier = true },
        };
        switch (self.operand) {
            .indexed => |indexed| result.reads |= indexed.register,
            .indirect => |text| {
                if (std.mem.endsWith(u8, text, ",y")) result.reads |= y;
                if (std.mem.endsWith(u8, text, ",x)")) result.reads |= x;
            },
            .unknown => result.barrier = true,
            else => {},
        }
        return result;
    }
};

pub fn integer(text: []const u8) ?u32 {
    if (text.len == 0) return null;
    return std.fmt.parseInt(u32, if (text[0] == '$') text[1..] else text, if (text[0] == '$') 16 else 0) catch null;
}

fn symbol(text: []const u8) ?Symbol {
    if (text.len == 0 or !(std.ascii.isAlphabetic(text[0]) or text[0] == '_')) return null;
    var end: usize = 1;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) : (end += 1) {}
    var offset: i32 = 0;
    if (end < text.len) {
        if (text[end] != '+' and text[end] != '-') return null;
        const magnitude = integer(text[end + 1 ..]) orelse return null;
        if (magnitude > std.math.maxInt(i32)) return null;
        offset = @intCast(magnitude);
        if (text[end] == '-') offset = -offset;
    }
    return .{ .name = text[0..end], .offset = offset };
}

pub fn parseOperand(text: []const u8) Operand {
    // Explicit absolute addressing has the same register/memory effects. Do
    // not normalize @b: indexed zero-page wrapping has different semantics.
    if (std.mem.startsWith(u8, text, "@w ")) {
        const operand = std.mem.trimStart(u8, text[3..], " \t");
        if (operand.len == 0 or std.mem.eql(u8, operand, "a")) return .unknown;
        return parseOperand(operand);
    }
    if (text.len == 0 or std.mem.eql(u8, text, "a")) return .none;
    if (text[0] == '#') return .{ .immediate = text[1..] };
    if (text[0] == '(') return .{ .indirect = text };
    if (std.mem.indexOfScalar(u8, text, ',')) |comma| {
        const base = symbol(text[0..comma]) orelse return .unknown;
        const index = std.mem.trim(u8, text[comma + 1 ..], " \t");
        return .{ .indexed = .{ .base = base, .register = if (std.mem.eql(u8, index, "x")) x else if (std.mem.eql(u8, index, "y")) y else return .unknown } };
    }
    if (integer(text)) |address| return if (address <= 65535) .{ .address = @intCast(address) } else .unknown;
    return if (symbol(text)) |value| .{ .direct = value } else .unknown;
}

pub fn outputsDeadBeforeRead(instructions: []const Instruction, outputs: u16) bool {
    var live = outputs;
    for (instructions) |inst| {
        const effect = inst.effects();
        if (effect.barrier or effect.reads & live != 0) return false;
        live &= ~effect.writes;
        if (live == 0) return true;
    }
    return false;
}

test "effects distinguish ADC carry from load NZ and index inputs" {
    const adc = Instruction.parse("adc slot+1").?.effects();
    try std.testing.expectEqual(a | c | d, adc.reads);
    try std.testing.expectEqual(a | nz | c | v, adc.writes);
    try std.testing.expectEqual(Memory.read, adc.memory);
    const load = Instruction.parse("lda (zeropage_ptr_tmp),y").?.effects();
    try std.testing.expectEqual(y, load.reads);
    try std.testing.expectEqual(a | nz, load.writes);
    const rotate = Instruction.parse("ror a").?.effects();
    try std.testing.expectEqual(a | c, rotate.reads);
    try std.testing.expectEqual(Memory.none, rotate.memory);
}

test "removing outputs requires both A and NZ to die before any consumer" {
    for ([_][]const u8{ "bne target", "sta destination", "tax", "adc #0", "php", "jsr helper" }) |consumer| {
        const code = [_]Instruction{ Instruction.parse(consumer).?, Instruction.parse("lda #0").? };
        try std.testing.expect(!outputsDeadBeforeRead(&code, a | nz));
    }
    const safe = [_]Instruction{ Instruction.parse("ldy #3").?, Instruction.parse("lda (zeropage_ptr_tmp),y").? };
    try std.testing.expect(outputsDeadBeforeRead(&safe, a | nz));
    const flags_only = [_]Instruction{Instruction.parse("ldy #3").?};
    try std.testing.expect(!outputsDeadBeforeRead(&flags_only, a | nz));
}

test "operand parsing preserves offsets and treats complex aliases as unknown" {
    const direct = parseOperand("frame+12").direct;
    try std.testing.expectEqualStrings("frame", direct.name);
    try std.testing.expectEqual(@as(i32, 12), direct.offset);
    try std.testing.expect(parseOperand("frame+index") == .unknown);
    try std.testing.expect(parseOperand("$fb") == .address);
    try std.testing.expect(Instruction.parse("stz slot") == null);
    try std.testing.expect(Instruction.parse("sta slot,y").?.effects().memory == .write);
}

test "forced absolute indexed operands retain their machine effects" {
    const inst = Instruction.parse("ldx @w table-240,y").?;
    try std.testing.expect(inst.operand == .indexed);
    try std.testing.expectEqual(@as(i32, -240), inst.operand.indexed.base.offset);
    try std.testing.expectEqual(y, inst.effects().reads);
    try std.testing.expectEqual(x | nz, inst.effects().writes);
    try std.testing.expectEqual(Memory.read, inst.effects().memory);
    try std.testing.expect(Instruction.parse("lda @b table,y").?.effects().barrier);
}
