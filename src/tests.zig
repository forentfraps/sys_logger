const std = @import("std");
const testing = std.testing;

const logger_mod = @import("root.zig");
const SysLogger = logger_mod.SysLogger;
const SysLoggerColour = logger_mod.SysLoggerColour;

pub fn main() void {
    const prefixes = [_][]const u8{ "BOOT", "AUTH" };
    const colours = [_]SysLoggerColour{ .green, .red };

    const log = SysLogger.init(prefixes.len, prefixes, colours);

    log.info("Success\n", .{});

}
