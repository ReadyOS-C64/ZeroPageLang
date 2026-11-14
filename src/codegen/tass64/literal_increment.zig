const std = @import("std");
const ast = @import("../../ast.zig");
const cfg = @import("cfg_dead_values.zig");
const machine = @import("instruction.zig");
const storage = @import("storage_model.zig");
const storage_proof = @import("call_argument_proof.zig");

const label_prefix = "zeropage_word_increment_";
const Plan = struct {
    first: usize,
    length: usize,
    slot: []const u8,
    replacement: enum { original, increment, reload } = .original,

    fn isWord(self: Plan) bool {
        return self.length == 8;
    }
};

fn trim(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r");
}

fn planAt(lines: []const []const u8, first: usize) ?Plan {
    const word = std.mem.eql(u8, trim(lines[first]), "ldx #0");
    const low = first + @intFromBool(word);
    const length: usize = if (word) 8 else 4;
    if (first + length > lines.len) return null;
    if (!std.mem.eql(u8, trim(lines[low]), "lda #1") or !std.mem.eql(u8, trim(lines[low + 1]), "clc")) return null;
    const adc = trim(lines[low + 2]);
    if (!std.mem.startsWith(u8, adc, "adc ")) return null;
    const slot = adc[4..];
    const symbol = machine.parseOperand(slot);
    if (symbol != .direct or !std.mem.eql(u8, symbol.direct.name, slot)) return null;
    if (!exact(lines[low + 3], "sta ", slot, "")) return null;
    if (word and (!std.mem.eql(u8, trim(lines[low + 4]), "txa") or
        !exact(lines[low + 5], "adc ", slot, "+1") or !exact(lines[low + 6], "sta ", slot, "+1"))) return null;
    return .{ .first = first, .length = length, .slot = slot };
}

fn exact(raw: []const u8, mnemonic: []const u8, slot: []const u8, suffix: []const u8) bool {
    const text = trim(raw);
    return text.len == mnemonic.len + slot.len + suffix.len and std.mem.startsWith(u8, text, mnemonic) and
        std.mem.eql(u8, text[mnemonic.len .. mnemonic.len + slot.len], slot) and std.mem.endsWith(u8, text, suffix);
}

/// Run on generated source code in the D-clear ABI. NMOS INC's extra write
/// and the word recipe's conditional high-byte write require ordinary RAM.
/// Return null when the input can be retained directly.
pub fn rewrite(allocator: std.mem.Allocator, program: ast.Program, assembly: []const u8) !?[]u8 {
    if (program.zeropage_module != null or program.zeropage_options.modules != null or
        program.zeropage_options.memory.placements.len != 0 or
        std.mem.indexOf(u8, assembly, "    lda #1\n    clc\n    adc ") == null or
        std.mem.indexOf(u8, assembly, "; inline asm") != null or
        std.ascii.indexOfIgnoreCase(assembly, label_prefix) != null) return null;

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, assembly, '\n');
    while (split.next()) |line| try lines.append(allocator, line);
    var model = storage.Model.init(allocator);
    defer model.deinit();
    try model.collect(assembly);

    var plans: std.ArrayList(Plan) = .empty;
    defer plans.deinit(allocator);
    var owner: ?[]const u8 = null;
    var index: usize = 0;
    while (index < lines.items.len) : (index += 1) {
        const line = trim(lines.items[index]);
        if (std.mem.startsWith(u8, line, "; zeropage_section_")) owner = storage.sectionOwner(line, "code");
        const function = owner orelse continue;
        const plan = planAt(lines.items, index) orelse continue;
        const width: u32 = if (plan.isWord()) 2 else 1;
        const loc = model.resolve(.{ .name = plan.slot }, width) orelse continue;
        if (!storage_proof.visible(model, loc) or !std.mem.eql(u8, model.frames.items[loc.frame].owner, function)) continue;
        try plans.append(allocator, plan);
        index += plan.length - 1;
    }
    if (plans.items.len == 0) return null;

    var query = try cfg.OutputQuery.init(allocator, assembly);
    defer query.deinit();
    var pending = plans.items.len;
    var selected: usize = 0;
    while (pending != 0) {
        pending -= 1;
        const plan = &plans.items[pending];
        const last = plan.first + plan.length - 1;
        const carry_and_overflow = machine.c | machine.v;
        const changed = machine.a | carry_and_overflow | if (plan.isWord()) machine.x | machine.nz else 0;
        if (try query.deadAfterLine(last, changed)) {
            plan.replacement = .increment;
        } else if (!plan.isWord() and try query.deadAfterLine(last, carry_and_overflow)) {
            // Reloading the result preserves the original A/N/Z at two fewer
            // cycles than the load/carry/add/store sequence in ordinary RAM.
            plan.replacement = .reload;
        } else continue;
        query.closeEntry(plan.first);
        selected += 1;
    }
    if (selected == 0) return null;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var cursor: usize = 0;
    for (plans.items, 0..) |plan, id| {
        if (plan.replacement == .original) continue;
        for (lines.items[cursor..plan.first]) |line| try out.writer.print("{s}\n", .{line});
        try out.writer.print("    inc {s}\n", .{plan.slot});
        if (plan.isWord()) try out.writer.print("    bne " ++ label_prefix ++ "{d}\n    inc {s}+1\n" ++ label_prefix ++ "{d}:\n", .{ id, plan.slot, id });
        if (plan.replacement == .reload) try out.writer.print("    lda {s}\n", .{plan.slot});
        cursor = plan.first + plan.length;
    }
    for (lines.items[cursor..], cursor..) |line, i| {
        try out.writer.writeAll(line);
        if (i + 1 < lines.items.len) try out.writer.writeByte('\n');
    }
    return try out.toOwnedSlice();
}
