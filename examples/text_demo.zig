const c64 = @import("c64");

const title = c64.petscii.clear ++ c64.petscii.home ++ "controls demo\n";
const banner = c64.petscii.reverse_on ++ "reverse" ++ c64.petscii.reverse_off ++ "\n";
const raw = c64.string.petscii("raw byte: \x41\n");
const host = c64.string.ascii("ascii proxy: ok\n");
const multi = c64.string.petscii(
    \\multi
    \\line
);

export fn main() void {
    c64.console.clear();
    c64.console.puts(title);
    c64.console.puts(banner);
    c64.console.puts(raw);

    var msg = c64.string.buffer(64);
    msg = "buffer " ++ c64.petscii.yellow ++ "control\n";
    c64.string.append(msg, host);
    c64.string.append(msg, multi);
    c64.console.puts(msg);
}
