const std = @import("std");
const builtin = @import("builtin");

const logger_mod = @import("root.zig");
const W = std.unicode.utf8ToUtf16LeStringLiteral;

const LogNt = logger_mod.SysLogger(.{
    .debug_only = true,
    .backend = .nt_write_file,
    .max_context_depth = 128,
});

const LogDebug = logger_mod.SysLogger(.{
    .debug_only = true,
    .backend = .std_debug,
    .max_context_depth = 128,
});

const Phase = enum {
    Boot,
    Auth,
    ImportFix,
    PathResolve,
};

fn nestedWork(log: anytype) void {
    log.info("entered nested work", .{});

    var scope = log.push("inner-step");
    defer scope.end();

    log.info("performing nested operation #{d}", .{1});
    log.crit("nested warning: example critical message", .{});
}

fn runBoot(log: anytype) void {
    log.info("boot sequence starting", .{});

    var scope = log.pushEnum(Phase.Boot);
    defer scope.end();

    log.info("initializing subsystem {s}", .{"loader"});
    nestedWork(log);
    log.info("boot sequence complete", .{});
}

fn runAuth(log: anytype) void {
    log.info("auth phase entered", .{});

    var scope = log.pushEnum(Phase.Auth);
    defer scope.end();

    const username = "stassssss";
    log.info("authenticating user {s}", .{username});
    log.crit("authentication failed with code {d}", .{401});
}

fn runImportFix(log: anytype) void {
    var scope = log.pushEnum(Phase.ImportFix);
    defer scope.end();

    log.info("fixing imports for module {s}", .{"ntdll.dll"});
    log.info("patched {d} IAT entries", .{17});
}

fn runPathResolve(log: anytype) void {
    var scope = log.pushEnum(Phase.PathResolve);
    defer scope.end();

    const ascii_path16 = W("C:\\Windows\\System32\\kernel32.dll");
    const unicode_path16 = W("C:\\Temp\\example\\example.dll");

    log.info16("resolved utf16 ascii path", .{}, ascii_path16);
    log.crit16("resolved utf16 unicode path", .{}, unicode_path16);
}

fn runManualContext(log: anytype) void {
    log.setContext("manual-context");
    defer log.rollbackContext();

    log.info("using explicit manual context push/pop", .{});
}

fn runScenario(comptime name: []const u8, log: anytype) void {
    log.raw_print("\n=== logger test start ({s}) ===\n", .{name});

    log.info("main entered", .{});
    runBoot(log);
    runAuth(log);
    runImportFix(log);
    runPathResolve(log);
    runManualContext(log);

    {
        var outer = log.push("outer-scope");
        defer outer.end();

        log.info("testing nested manual scopes", .{});

        {
            var inner = log.push("inner-scope");
            defer inner.end();

            log.info("deep scope message", .{});
        }

        log.crit("back in outer scope", .{});
    }

    log.info("main exiting", .{});
    log.raw_print("=== logger test end ({s}) ===\n", .{name});
}

pub fn main() void {
    if (builtin.os.tag == .windows) {
        var nt_log = LogNt.init();
        runScenario("nt_write_file", &nt_log);
    }

    var debug_log = LogDebug.init();
    runScenario("std_debug", &debug_log);
}
