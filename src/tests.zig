const std = @import("std");
const testing = std.testing;

const logger_mod = @import("root.zig");
const win = std.os.windows;
const SysLogger = logger_mod.SysLogger;
const SysLoggerColour = logger_mod.SysLoggerColour;
test "SysLogger honours compile-time prefix / colour tables" {
    const prefixes = [_][]const u8{ "BOOT", "AUTH" };
    const colours = [_]SysLoggerColour{ .green, .red };

    const log = SysLogger.init(prefixes.len, prefixes, colours);

    log.info("Success\n", .{});

    //Teest does not pass if called from zig build test, because mutexes...
}
