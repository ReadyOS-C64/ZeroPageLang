const std = @import("std");
const machine = @import("instruction.zig");

pub const Location = struct { frame: usize, offset: u32 };
pub const Frame = struct {
    owner: []const u8,
    bytes: u32 = 0,
    valid: bool = true,
    ordinary_ram: bool = false,
    domain: usize = 0,
    lower: u32 = 0,
    upper: u32 = 0,
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayList(Frame) = .empty,
    labels: std.StringHashMap(Location),

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{ .allocator = allocator, .labels = std.StringHashMap(Location).init(allocator) };
    }

    pub fn deinit(self: *Model) void {
        self.frames.deinit(self.allocator);
        self.labels.deinit();
    }

    pub fn resolve(self: Model, reference: machine.Symbol, width: u32) ?Location {
        const base = self.labels.get(reference.name) orelse return null;
        const frame = self.frames.items[base.frame];
        if (!frame.valid or !frame.ordinary_ram) return null;
        const offset = @as(i64, base.offset) + reference.offset;
        if (offset < 0 or offset + width > frame.bytes) return null;
        return .{ .frame = base.frame, .offset = @intCast(offset) };
    }

    /// A frame can contain adjacent objects. A reference must stay before
    /// the next distinct label when an optimizer can remove an object.
    pub fn resolveObject(self: Model, reference: machine.Symbol, width: u32) ?Location {
        const resolved = self.resolve(reference, width) orelse return null;
        if (reference.offset < 0) return null;
        if (reference.offset == 0 and width == 1) return resolved;
        const base = self.labels.get(reference.name).?;
        var labels = self.labels.valueIterator();
        while (labels.next()) |other| {
            if (other.frame == base.frame and other.offset > base.offset and
                other.offset < resolved.offset + width) return null;
        }
        return resolved;
    }

    /// Match LDX high / LDA low of one ordinary object. A managed equate
    /// is eligible only if its actual allocation record owns both bytes.
    pub fn ordinaryWordLoad(self: Model, lines: []const []const u8, high_line: []const u8, low_line: []const u8, managed: bool) bool {
        const high = machine.Instruction.parse(high_line) orelse return false;
        const low = machine.Instruction.parse(low_line) orelse return false;
        if (high.op != .ldx or high.operand != .direct or high.operand.direct.offset != 1 or
            low.op != .lda or low.operand != .direct or low.operand.direct.offset != 0 or
            !std.mem.eql(u8, high.operand.direct.name, low.operand.direct.name)) return false;
        return self.ordinaryStorage(lines, low.operand.direct, 2, managed);
    }

    pub fn ordinaryStorage(self: Model, lines: []const []const u8, reference: machine.Symbol, width: u32, managed: bool) bool {
        if (self.resolveObject(reference, width) != null) return true;
        if (!managed or reference.offset < 0) return false;
        const claim = claimedAddress(lines, reference.name, "parameter") orelse return false;
        return claim.width <= 2 and @as(u32, @intCast(reference.offset)) + width <= claim.width;
    }

    pub fn disjoint(self: Model, first: Location, first_width: u32, second: Location, second_width: u32) bool {
        if (first.frame == second.frame) return first.offset + first_width <= second.offset or second.offset + second_width <= first.offset;
        const a = self.frames.items[first.frame];
        const b = self.frames.items[second.frame];
        // Within one monotonic origin segment, separately emitted storage
        // sections cannot overlap. A new origin/logical mapping starts a domain.
        return a.domain != 0 and a.domain == b.domain and a.valid and b.valid and a.ordinary_ram and b.ordinary_ram;
    }

    pub fn indexedReadIsRam(self: Model, reference: machine.Symbol) bool {
        const base = self.labels.get(reference.name) orelse return false;
        const frame = self.frames.items[base.frame];
        if (!frame.valid or !frame.ordinary_ram) return false;
        // Indexed read effects need RAM bounds, not object membership. A
        // guarded table may bias its absolute base below the first element.
        // resolve() deliberately remains stricter for value/alias identities.
        const lower = @as(i64, frame.lower) + base.offset + reference.offset;
        const end = @as(i64, frame.upper) + reference.offset + 255;
        return lower >= 0x0200 and end <= 0x10000 and (end <= 0xd000 or lower >= 0xe000);
    }

    pub fn collect(self: *Model, assembly: []const u8) !void {
        try self.collectFrames(assembly, null);
    }

    /// A late pass can keep resident objects in a mixed frame when each
    /// non-emitting parameter equate has an actual allocation claim.
    pub fn collectWithPromotedParameters(self: *Model, assembly: []const u8, lines: []const []const u8) !void {
        try self.collectFrames(assembly, lines);
    }

    fn collectFrames(self: *Model, assembly: []const u8, claims: ?[]const []const u8) !void {
        var active: ?usize = null;
        // Bounds, not a second assembler: known NMOS instructions cost at most
        // three bytes. Unknown layout directives revoke the bound until an origin.
        var lower: u32 = 0;
        var upper: ?u32 = null;
        var conditional_depth: usize = 0;
        var domain: usize = 0;
        var inline_assembly = false;
        var lines = std.mem.splitScalar(u8, assembly, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "; inline asm")) inline_assembly = true;
            if (std.mem.eql(u8, line, "; end inline asm")) {
                inline_assembly = false;
                continue;
            }
            // User assembly comments cannot manufacture storage identities.
            // Its real instructions/directives still contribute layout bounds.
            if (inline_assembly and line[0] == ';') continue;
            const frame_owner = sectionOwner(line, "static_frame");
            const scratch = compilerStorage(line, "scratch");
            const rodata = rodataOwner(line);
            if (frame_owner != null or scratch or rodata != null) {
                if (active) |index| self.frames.items[index].valid = false;
                active = self.frames.items.len;
                try self.frames.append(self.allocator, .{ .owner = frame_owner orelse (if (scratch) "compiler:scratch" else rodata.?), .valid = conditional_depth == 0, .domain = domain, .lower = lower });
                continue;
            }
            if (std.mem.startsWith(u8, line, "; zeropage_section_end ")) {
                if (active) |index| {
                    self.frames.items[index].upper = upper orelse 0;
                    self.frames.items[index].ordinary_ram = if (upper) |end|
                        lower >= 0x0200 and end <= 0x10000 and (end <= 0xd000 or lower >= 0xe000)
                    else
                        false;
                    active = null;
                }
                continue;
            }
            if (line[0] == ';') continue;
            if (std.mem.startsWith(u8, line, ".if ") or std.mem.eql(u8, line, ".else") or std.mem.eql(u8, line, ".endif")) {
                if (active) |index| self.frames.items[index].valid = false;
                if (std.mem.startsWith(u8, line, ".if ")) {
                    conditional_depth += 1;
                } else if (std.mem.eql(u8, line, ".endif")) {
                    if (conditional_depth == 0) upper = null else conditional_depth -= 1;
                } else if (conditional_depth == 0) upper = null;
                // Count both conditional bodies in the upper bound. They emit
                // no bytes themselves; origins inside them revoke the bound.
                continue;
            }
            if (std.mem.endsWith(u8, line, ":")) {
                if (active) |index| {
                    const entry = try self.labels.getOrPut(line[0 .. line.len - 1]);
                    if (entry.found_existing) {
                        self.frames.items[entry.value_ptr.frame].valid = false;
                        self.frames.items[index].valid = false;
                    } else entry.value_ptr.* = .{ .frame = index, .offset = self.frames.items[index].bytes };
                }
                continue;
            }
            if (std.mem.startsWith(u8, line, "* = ") or std.mem.startsWith(u8, line, ".logical ")) {
                domain += 1;
                const value = machine.integer(if (line[0] == '*') line[4..] else line[9..]);
                upper = if (conditional_depth == 0) value else null;
                lower = if (conditional_depth == 0) value orelse 0 else 0;
                if (active) |index| self.frames.items[index].valid = false;
                continue;
            }
            const count = dataBytes(line);
            if (active) |index| {
                if (count) |bytes| {
                    self.frames.items[index].bytes += bytes;
                } else if (!isPromotedParameter(line, self.frames.items[index].owner, claims)) {
                    self.frames.items[index].valid = false;
                }
            }
            if (count) |bytes| {
                advance(&upper, bytes);
            } else if (machine.Instruction.parse(line) != null) {
                advance(&upper, 3);
            } else if (std.mem.startsWith(u8, line, ".byte ") or std.mem.startsWith(u8, line, ".word ") or std.mem.startsWith(u8, line, ".text ")) {
                // A conservative bound for literals/expressions outside frames.
                advance(&upper, @intCast(line.len * 2));
            } else if (std.mem.startsWith(u8, line, ".fill ")) {
                const end = std.mem.indexOfScalar(u8, line, ',') orelse line.len;
                if (machine.integer(line[6..end])) |bytes| {
                    advance(&upper, bytes);
                } else if (std.mem.eql(u8, line, ".fill (($100 - (* & $ff)) & $ff),0")) {
                    // This exact runtime padding expression is bounded by its
                    // final mask. No other dynamic fill expression is guessed.
                    advance(&upper, 255);
                } else upper = null;
            } else if (!symbolAssignment(line)) {
                upper = null;
            }
        }
        if (active) |index| self.frames.items[index].valid = false;
    }
};

fn isPromotedParameter(line: []const u8, owner: []const u8, claims: ?[]const []const u8) bool {
    const lines = claims orelse return false;
    const end = std.mem.indexOf(u8, line, " = address(") orelse return false;
    const name = line[0..end];
    if (name.len <= owner.len or name[owner.len] != '_' or !std.mem.startsWith(u8, name, owner)) return false;
    return claimedAddress(lines, name, "parameter") != null;
}

pub const Claim = struct { address: u32, width: u32 };

/// Match the actual zero-page equate with its emitted allocation record.
pub fn claimedAddress(lines: []const []const u8, name: []const u8, kind: []const u8) ?Claim {
    var address: ?u32 = null;
    var claim: ?Claim = null;
    for (lines) |line| {
        if (std.mem.startsWith(u8, line, name)) {
            const tail = line[name.len..];
            if (std.mem.startsWith(u8, tail, " = address(") and std.mem.endsWith(u8, tail, ")")) {
                if (address != null) return null;
                address = machine.integer(tail[" = address(".len .. tail.len - 1]) orelse return null;
            }
        }
        const prefix = "; zeropage_zp_claim label=";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        var fields = std.mem.splitScalar(u8, line[prefix.len..], ' ');
        if (!std.mem.eql(u8, fields.next() orelse continue, name)) continue;
        const addr = fields.next() orelse return null;
        const size = fields.next() orelse return null;
        const claim_kind = fields.next() orelse return null;
        if (!std.mem.startsWith(u8, addr, "addr=") or !std.mem.startsWith(u8, size, "size=") or
            !std.mem.startsWith(u8, claim_kind, "kind=") or !std.mem.eql(u8, claim_kind["kind=".len..], kind) or claim != null) return null;
        const physical = machine.integer(addr["addr=".len..]) orelse return null;
        const width = machine.integer(size["size=".len..]) orelse return null;
        if (physical < 2 or physical > 255 or width == 0 or width > 256 - physical) return null;
        claim = .{ .address = physical, .width = width };
    }
    const result = claim orelse return null;
    return if (address == result.address) result else null;
}

pub fn claimedScratch(lines: []const []const u8, ref: machine.Symbol) bool {
    if (ref.offset < 0 or !std.mem.startsWith(u8, ref.name, "zeropage_")) return false;
    const claim = claimedAddress(lines, ref.name, "scratch") orelse return false;
    return @as(u32, @intCast(ref.offset)) < claim.width;
}

fn rodataOwner(line: []const u8) ?[]const u8 {
    const prefix = "; zeropage_section_begin owner=";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const end = std.mem.indexOfScalarPos(u8, line, prefix.len, ' ') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, line[end + 1 ..], ' ');
    while (fields.next()) |field| if (std.mem.eql(u8, field, "kind=rodata")) return line[prefix.len..end];
    return null;
}

fn compilerStorage(line: []const u8, kind: []const u8) bool {
    const prefix = "; zeropage_section_begin owner=compiler ";
    if (!std.mem.startsWith(u8, line, prefix)) return false;
    var fields = std.mem.tokenizeScalar(u8, line[prefix.len..], ' ');
    while (fields.next()) |field| if (std.mem.startsWith(u8, field, "kind=") and std.mem.eql(u8, field[5..], kind)) return true;
    return false;
}

fn symbolAssignment(line: []const u8) bool {
    const end = std.mem.indexOf(u8, line, " = ") orelse return false;
    const operand = machine.parseOperand(line[0..end]);
    return operand == .direct and operand.direct.offset == 0 and operand.direct.name.len == end;
}

fn advance(bound: *?u32, count: u32) void {
    if (bound.*) |current| bound.* = std.math.add(u32, current, count) catch null;
}

pub fn dataBytes(line: []const u8) ?u32 {
    const width: u32 = if (std.mem.startsWith(u8, line, ".byte ")) 1 else if (std.mem.startsWith(u8, line, ".word ")) 2 else return null;
    var fields = std.mem.splitScalar(u8, line[6..], ',');
    var count: u32 = 0;
    while (fields.next()) |field| {
        const value = std.mem.trim(u8, field, " \t");
        // Word arrays serialize as .byte <literal,>literal pairs. Each pure
        // numeric extraction still emits exactly one byte; symbols/vectors
        // and arbitrary assembler expressions remain unproved.
        const numeric = if (width == 1 and value.len > 1 and (value[0] == '<' or value[0] == '>')) value[1..] else value;
        _ = machine.integer(numeric) orelse return null;
        count += width;
    }
    return count;
}

test "numeric low and high extraction preserve rodata byte bounds" {
    for ([_][]const u8{ "<255,>255,<256,>256", "<unknown,>unknown", "<array+1,>array+1" }, 0..) |values, case| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "* = $2000\n; zeropage_section_begin owner=module:main kind=rodata\ntable:\n.byte {s}\n; zeropage_section_end owner=module:main kind=rodata\n", .{values});
        defer std.testing.allocator.free(text);
        var model = Model.init(std.testing.allocator);
        defer model.deinit();
        try model.collect(text);
        try std.testing.expectEqual(case == 0, model.resolve(.{ .name = "table" }, 4) != null);
    }
}

pub fn sectionOwner(line: []const u8, kind: []const u8) ?[]const u8 {
    const prefix = "; zeropage_section_begin owner=function:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const end = std.mem.indexOfScalarPos(u8, line, prefix.len, ' ') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, line[end + 1 ..], ' ');
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "kind=")) {
            return if (std.mem.eql(u8, field[5..], kind)) line[prefix.len..end] else null;
        }
    }
    return null;
}

test "frame storage resolves root and field aliases by byte offset" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.collect(
        \\* = $2000
        \\; zeropage_section_begin owner=function:f kind=static_frame lifetime=static address=near
        \\f_record:
        \\f_pointer:
        \\    .word 0
        \\f_value:
        \\    .byte 0
        \\; zeropage_section_end owner=function:f kind=static_frame
    );
    const root = model.resolve(.{ .name = "f_record", .offset = 1 }, 1).?;
    const alias = model.resolve(.{ .name = "f_pointer", .offset = 1 }, 1).?;
    try std.testing.expectEqual(root, alias);
    try std.testing.expectEqual(@as(u32, 2), model.resolve(.{ .name = "f_value" }, 1).?.offset);
    try std.testing.expect(model.resolve(.{ .name = "f_record", .offset = 3 }, 1) == null);
    try std.testing.expect(model.resolve(.{ .name = "f_pointer", .offset = -1 }, 1) == null);
}

test "RAM proof rejects IO stack unknown origins and frame directives" {
    for ([_][]const u8{ "* = $d000", "* = $01ff", ".align $100", "* = $cfff" }) |origin| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "{s}\n; zeropage_section_begin owner=function:f kind=static_frame\nf_pointer:\n .word 0\n; zeropage_section_end owner=function:f kind=static_frame\n", .{origin});
        defer std.testing.allocator.free(text);
        var model = Model.init(std.testing.allocator);
        defer model.deinit();
        try model.collect(text);
        try std.testing.expect(model.resolve(.{ .name = "f_pointer" }, 2) == null);
    }
}

test "compiler scratch identities survive bounded conditional runtime padding" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.collect(
        \\* = $2000
        \\.if (* & $ff) > $f0
        \\    jmp loop
        \\.if (* & $ff) > $f0
        \\    .fill (($100 - (* & $ff)) & $ff),0
        \\.endif
        \\.endif
        \\loop:
        \\    rts
        \\; zeropage_section_begin owner=compiler kind=scratch lifetime=static address=near
        \\temporary:
        \\    .word 0
        \\; zeropage_section_end owner=compiler kind=scratch
    );
    try std.testing.expect(model.resolve(.{ .name = "temporary" }, 2) != null);
    try std.testing.expectEqual(@as(u32, 1), model.resolve(.{ .name = "temporary", .offset = 1 }, 1).?.offset);
}

test "conditional origins and conditional storage cannot establish RAM identity" {
    for ([_][]const u8{ ".if 1\n* = $2000\n.endif", ".if 1", ".fill unknown,0" }) |prefix| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "* = $2000\n{s}\n; zeropage_section_begin owner=compiler kind=scratch\ntemporary:\n.word 0\n; zeropage_section_end owner=compiler kind=scratch\n", .{prefix});
        defer std.testing.allocator.free(text);
        var model = Model.init(std.testing.allocator);
        defer model.deinit();
        try model.collect(text);
        try std.testing.expect(model.resolve(.{ .name = "temporary" }, 2) == null);
    }
}

test "storage domains distinguish monotonic sections from explicit overlapping origins" {
    for ([_][]const u8{ "", "* = $2000", ".logical $2000" }) |reset| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "* = $2000\n; zeropage_section_begin owner=function:f kind=static_frame\nf_pointer:\n.word 0\n; zeropage_section_end owner=function:f kind=static_frame\n{s}\n; zeropage_section_begin owner=module:main kind=rodata\ntable:\n.byte 0,1,2,3\n; zeropage_section_end owner=module:main kind=rodata\n", .{reset});
        defer std.testing.allocator.free(input);
        var model = Model.init(std.testing.allocator);
        defer model.deinit();
        try model.collect(input);
        const a = model.resolve(.{ .name = "f_pointer" }, 2).?;
        const b = model.resolve(.{ .name = "table" }, 1).?;
        try std.testing.expectEqual(reset.len == 0, model.disjoint(a, 2, b, 1));
        try std.testing.expect(model.indexedReadIsRam(.{ .name = "table" }));
    }
}

test "indexed reads require complete index range outside IO and wrap" {
    for ([_][]const u8{ "$ceff", "$ff00", "$d000" }) |origin| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "* = {s}\n; zeropage_section_begin owner=module:main kind=rodata\ntable:\n.byte 0,1,2,3\n; zeropage_section_end owner=module:main kind=rodata\n", .{origin});
        defer std.testing.allocator.free(input);
        var model = Model.init(std.testing.allocator);
        defer model.deinit();
        try model.collect(input);
        try std.testing.expect(!model.indexedReadIsRam(.{ .name = "table" }));
    }
}

test "opaque assembly comments cannot forge a RAM storage section" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.collect(
        \\* = $2000
        \\; inline asm from ZeroPage line 1
        \\; zeropage_section_begin owner=function:f kind=static_frame
        \\forged:
        \\.word 0
        \\; zeropage_section_end owner=function:f kind=static_frame
        \\; end inline asm
    );
    try std.testing.expect(model.resolve(.{ .name = "forged" }, 2) == null);
}

test "biased indexed read RAM proof does not create an outside-object identity" {
    for ([_][]const u8{ "$2000", "$0200", "$e000", "$cf00" }, 0..) |origin, case| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "* = {s}\n; zeropage_section_begin owner=compiler kind=rodata\ntable:\n.byte 0,1,2,3\n; zeropage_section_end owner=compiler kind=rodata\n", .{origin});
        defer std.testing.allocator.free(text);
        var model = Model.init(std.testing.allocator);
        defer model.deinit();
        try model.collect(text);
        const biased = machine.Symbol{ .name = "table", .offset = -240 };
        try std.testing.expect(model.resolve(biased, 1) == null);
        try std.testing.expectEqual(case == 0 or case == 3, model.indexedReadIsRam(biased));
    }
}
