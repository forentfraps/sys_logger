const std = @import("std");
const testing = std.testing;

// Import the implementation as an out-of-line dependency so we do
// not pollute the root namespace with its symbols.
const logger_mod = @import("root.zig");
const SysLogger = logger_mod.SysLogger;
const SysLoggerColour = logger_mod.SysLoggerColour;

// ------- 1. COLOUR CODE CONTRACT -----------------------------------------
test "SysLoggerColour → ANSI escape mapping is correct" {
    const expect = testing.expect;
    try expect(std.mem.eql(u8, SysLoggerColour.red.getAnsiCode(), "\x1b[31;40m"));
    try expect(std.mem.eql(u8, SysLoggerColour.blue.getAnsiCode(), "\x1b[34;40m"));
    try expect(std.mem.eql(u8, SysLoggerColour.green.getAnsiCode(), "\x1b[32;40m"));
    try expect(std.mem.eql(u8, SysLoggerColour.white.getAnsiCode(), "\x1b[37;40m"));
    try expect(std.mem.eql(u8, SysLoggerColour.cyan.getAnsiCode(), "\x1b[36;40m"));
    try expect(std.mem.eql(u8, SysLoggerColour.pink.getAnsiCode(), "\x1b[35;40m"));
    try expect(std.mem.eql(u8, SysLoggerColour.yellow.getAnsiCode(), "\x1b[33;40m"));
    try expect(std.mem.eql(u8, SysLoggerColour.none.getAnsiCode(), "\x1b[0;0m"));

    try expect(std.mem.eql(u8, SysLoggerColour.getCrit(), "\x1b[37;41m"));
    try expect(std.mem.eql(u8, SysLoggerColour.getReset(), "\x1b[0;0m"));
}

// ------- 2. CONTEXT STACK -------------------------------------------------
test "SysLogger context push / pop behaves like a nibble stack" {
    const prefixes = [_][]const u8{ "GEN", "NET", "IO" };
    const colours = [_]SysLoggerColour{
        .white, .cyan, .yellow,
    };

    var log = SysLogger.init(prefixes.len, prefixes, colours);

    // Default context is 0.
    try testing.expectEqual(@as(usize, 0), log.getContext());

    // Push ‘2’ (IO) and verify.
    const Ctx = enum { IO };
    log.setContext(Ctx.IO);
    try testing.expectEqual(@as(usize, 2), log.getContext());

    // Push again (e.g., nested scope) then pop twice.
    log.setContext(Ctx.IO);
    try testing.expectEqual(@as(usize, 2), log.getContext());

    log.rollbackContext();
    try testing.expectEqual(@as(usize, 2), log.getContext());

    log.rollbackContext();
    try testing.expectEqual(@as(usize, 0), log.getContext());
}

// ------- 3. INITIALISATION & SILENCING -----------------------------------
test "SysLogger honours compile-time prefix / colour tables" {
    // Any two arbitrary, but different, entries are enough.
    const prefixes = [_][]const u8{ "BOOT", "AUTH" };
    const colours = [_]SysLoggerColour{ .green, .red };

    var log = SysLogger.init(prefixes.len, prefixes, colours);

    try testing.expectEqualSlices(SysLoggerColour, colours[0..], log.colour_list);

    // Turn logging off – the calls must *not* raise despite the writer
    // being unavailable in a test context.
    log.enabled = false;

    // NB: Each helper returns `void`, so a plain call is enough.
    log.info("booted in {d} ms", .{42});
    log.crit("security failure: 0x{x}", .{0xdead_beef});

    const codepoints: [3]u16 = .{ 'A', 'B', 'C' };
    log.info16("unicode path", .{}, &codepoints);
    log.crit16("unicode path", .{}, &codepoints);
}
