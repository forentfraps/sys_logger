const std = @import("std");
const testing = std.testing;

// Import the implementation as an out-of-line dependency so we do
// not pollute the root namespace with its symbols.
const logger_mod = @import("root.zig");
const SysLogger = logger_mod.SysLogger;
const SysLoggerColour = logger_mod.SysLoggerColour;
// ------- 3. INITIALISATION & SILENCING -----------------------------------
test "SysLogger honours compile-time prefix / colour tables" {
    // Any two arbitrary, but different, entries are enough.
    const prefixes = [_][]const u8{ "BOOT", "AUTH" };
    const colours = [_]SysLoggerColour{ .green, .red };

    std.debug.print("Initting\n", .{});
    var log = SysLogger.init(prefixes.len, prefixes, colours);

    std.debug.print("post Initting\n", .{});
    log.info("Success\n", .{});
}
