const std = @import("std");
const SyscallManager = @import("syscall_manager").SyscallManager;
const Syscall = @import("syscall_manager").Syscall;
const win = std.os.windows;

const W = std.unicode.utf8ToUtf16LeStringLiteral;

pub const SysLogger = struct {
    current_context: u256,
    enabled: bool,
    colour_crit: SysLoggerColour,
    colour_info: SysLoggerColour,
    pref_list: []const []const u8,
    colour_list: []SysLoggerColour, // Added colour_list

    pub fn init(comptime sz: usize, comptime pref_list: [sz][]const u8, comptime colour_list: [sz]SysLoggerColour) @This() {
        if (global_syscall_manager == null) {
            initRawPrinter();
        }
        return .{
            .current_context = 0,
            .enabled = true,
            .colour_crit = SysLoggerColour.red,
            .colour_info = SysLoggerColour.blue,
            .pref_list = &pref_list,
            .colour_list = @constCast(&colour_list),
        };
    }

    pub fn info(self: @This(), comptime msg: []const u8, args: anytype) void {
        if (!self.enabled) {
            return;
        }
        const context_index = self.getContext();
        const prefix = self.pref_list[context_index];
        const colour = self.colour_list[context_index];
        var buf: [256]u8 = undefined;
        const formatted_msg = std.fmt.bufPrint(&buf, msg, args) catch return;

        print("{s}[{s}] {s}{s}", .{ colour.getAnsiCode(), prefix, formatted_msg, SysLoggerColour.getReset() });
    }

    pub fn crit(self: @This(), comptime msg: []const u8, args: anytype) void {
        if (!self.enabled) {
            return;
        }
        const context_index = self.getContext();
        const prefix = self.pref_list[context_index];
        var buf: [256]u8 = undefined;
        const formatted_msg = std.fmt.bufPrint(&buf, msg, args) catch return;

        print("{s}[{s}]{s}{s}", .{ SysLoggerColour.getCrit(), prefix, formatted_msg, SysLoggerColour.getReset() });
    }
    pub fn info16(self: @This(), comptime msg: []const u8, args: anytype, arg16: []const u16) void {
        if (!self.enabled) {
            return;
        }
        const context_index = self.getContext();
        const prefix = self.pref_list[context_index];
        const colour = self.colour_list[context_index];
        var buf: [256]u8 = undefined;
        const formatted_msg = std.fmt.bufPrint(&buf, msg, args) catch return;

        print("{s}[{s}] {s} -> ", .{ colour.getAnsiCode(), prefix, formatted_msg });
        for (0..arg16.len) |i| {
            print("{u}", .{arg16[i]});
        }
        print("{s}\n", .{SysLoggerColour.getReset()});
    }

    pub fn crit16(self: @This(), comptime msg: []const u8, args: anytype, arg16: []const u16) void {
        if (!self.enabled) {
            return;
        }
        const context_index = self.getContext();
        const prefix = self.pref_list[context_index];
        var buf: [256]u8 = undefined;
        const formatted_msg = std.fmt.bufPrint(&buf, msg, args) catch return;
        print("{s} [{s}] {s} -> ", .{ SysLoggerColour.getCrit(), prefix, formatted_msg });
        for (0..arg16.len) |i| {
            print("{u}", .{arg16[i]});
        }
        print("{s}\n", .{SysLoggerColour.getReset()});
    }

    pub fn setContext(self: *@This(), ctx: anytype) void {
        self.current_context = self.current_context << 4 | @as(u256, @intFromEnum(ctx));
    }

    pub fn rollbackContext(self: *@This()) void {
        self.current_context >>= 4;
    }

    pub fn getContext(self: @This()) usize {
        const current_context_decoded: usize = @intCast(@as(u4, @truncate(self.current_context)));
        return current_context_decoded;
    }
};

pub const SysLoggerColour = enum {
    red,
    blue,
    green,
    white,
    pink,
    yellow,
    cyan,
    none,

    pub fn getAnsiCode(self: @This()) []const u8 {
        return switch (self) {
            .red => "\x1b[31;40m",
            .blue => "\x1b[34;40m",
            .green => "\x1b[32;40m",
            .white => "\x1b[37;40m",
            .cyan => "\x1b[36;40m",
            .pink => "\x1b[35;40m",
            .yellow => "\x1b[33;40m",
            .none => "\x1b[0;0m",
        };
    }

    pub fn getCrit() []const u8 {
        return "\x1b[37;41m";
    }
    pub fn getReset() []const u8 {
        return "\x1b[0;0m";
    }
};

var global_syscall_manager: ?SyscallManager = null;

pub fn initRawPrinter() void {
    if (global_syscall_manager == null) {
        global_syscall_manager = SyscallManager{};
    }
    const ntdll = win.kernel32.GetModuleHandleW(W("ntdll.dll")).?;
    const NtWriteFileP: [*]u8 = @ptrCast((win.kernel32.GetProcAddress(ntdll, "NtWriteFile")).?);

    const syscall: Syscall = Syscall.fetch(NtWriteFileP) catch @panic("Could not find NtWriteFile");
    global_syscall_manager.?.addNWF(syscall);
}
fn raw_printer(bytes: []const u8) void {
    //  mov     rax, gs:60h
    //  mov     rcx, [rax+20h]
    //  mov     rdi, [rcx+28h]
    const stdout = asm volatile (".byte 0x65, 0x48, 0x8B, 0x04, 0x25, 0x60, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x48, 0x20, 0x48, 0x8B, 0x79, 0x28\n"
        : [ret] "={rdi}" (-> usize),
        :
        : "rax", "rcx", "rdi"
    );
    var io_block: win.IO_STATUS_BLOCK = undefined;
    _ = global_syscall_manager.?.NtWriteFile(
        stdout,
        0,
        0,
        0,
        &io_block,
        bytes.ptr,
        bytes.len,
        0,
        0,
    ) catch return;
}

const WriterError = error{
    RuntimeRawPrinterUnset,
};

pub const CustomWriter = struct {
    /// The error set for this writer.
    pub const Error = anyerror;
    pub const Self = @This();

    /// The method that `std.fmt.format` calls to emit data.
    /// Must match signature: `fn writeAll(self: *CustomWriter, bytes: []const u8) !Error`.
    pub fn writeAll(_: Self, bytes: []const u8) !void {
        if (global_syscall_manager != null) {
            raw_printer(bytes);
        } else {
            return WriterError.RuntimeRawPrinterUnset;
        }

        return; // no error
    }
    pub fn writeBytesNTimes(self: Self, bytes: []const u8, n: usize) anyerror!void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try self.writeAll(bytes);
        }
    }
};

/// A function that behaves like `std.debug.print` but sends data to `CustomWriter`.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    const writer = CustomWriter{};
    // IMPORTANT: pass &writer so `std.fmt.format` can call writeAll on *CustomWriter
    std.fmt.format(writer, fmt, args) catch @panic("CustomPrintFailed");
}
