// Standalone host test generator: zig run src/stride_probe.zig > build/stride-probe.asm
const std = @import("std");
const stride = @import("codegen/tass64/stride_selection.zig");
const runtime = @import("codegen/tass64/runtime.zig");
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var file = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &file.interface;
    var usage: stride.Usage = .{};
    try writer.writeAll("* = $2000\nzeropage_mul_lhs = $c000\nzeropage_mul_rhs = $c002\nzeropage_mul_result = $c004\n");
    for ([_]u16{ 3, 4, 5, 8, 9, 16, 17, 32, 33, 64, 65, 128, 129, 256, 257, 512, 1024, 2048, 4096, 8192, 16384, 32768, 32769 }) |factor| {
        const plan = stride.chooseWithCost(factor, 100, true, .absolute).?;
        try writer.print("before_{d}:\n    sta zeropage_mul_lhs\n    stx zeropage_mul_lhs+1\n    lda #{d}\n    ldx #{d}\n    sta zeropage_mul_rhs\n    stx zeropage_mul_rhs+1\n    jsr zeropage_mul16\n    rts\nafter_{d}:\n", .{ factor, factor & 255, factor >> 8, factor });
        try usage.emitCall(writer, plan);
        try writer.writeAll("    rts\n");
    }
    try usage.emitHelpers(writer);
    try runtime.emitMultiplyRoutine(writer);
    try writer.flush();
}
