const std = @import("std");
const SyscallManager = @import("syscall_manager").SyscallManager;
const Syscall = @import("syscall_manager").Syscall;
const win = @import("zigwin32").everything;

const W = std.unicode.utf8ToUtf16LeStringLiteral;
// pub extern "kernel32" fn GetModuleHandleW(
//     lpModuleName: [*:0]const win.WCHAR,
// ) callconv(.winapi) ?win.HMODULE;
//
// pub extern "kernel32" fn GetProcAddress(
//     module: win.HMODULE,
//     procName: [*:0]const u8,
// ) callconv(.winapi) ?win.FARPROC;

pub const SysLogger = struct {
    current_context: u256,
    enabled: bool,
    colour_crit: SysLoggerColour,
    colour_info: SysLoggerColour,
    pref_list: []const []const u8,
    colour_list: []SysLoggerColour, // Added colour_list

    const Self = @This();

    pub fn init(comptime sz: usize, comptime pref_list: [sz][]const u8, comptime colour_list: [sz]SysLoggerColour) Self {
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
    pub fn raw_print(_: Self, comptime msg: []const u8, args: anytype) void {
        print(msg, args);
    }

    pub fn info(self: Self, comptime msg: []const u8, args: anytype) void {
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

    pub fn crit(self: Self, comptime msg: []const u8, args: anytype) void {
        if (!self.enabled) {
            return;
        }
        const context_index = self.getContext();
        const prefix = self.pref_list[context_index];
        var buf: [256]u8 = undefined;
        const formatted_msg = std.fmt.bufPrint(&buf, msg, args) catch return;

        print("{s}[{s}]{s}{s}", .{ SysLoggerColour.getCrit(), prefix, formatted_msg, SysLoggerColour.getReset() });
    }
    pub fn info16(self: Self, comptime msg: []const u8, args: anytype, arg16: []const u16) void {
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

    pub fn crit16(self: Self, comptime msg: []const u8, args: anytype, arg16: []const u16) void {
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

    pub fn setContext(self: *Self, ctx: anytype) void {
        self.current_context = self.current_context << 4 | @as(u256, @intFromEnum(ctx));
    }

    pub fn rollbackContext(self: *Self) void {
        self.current_context >>= 4;
    }

    pub fn getContext(self: Self) usize {
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

    const Self = @This();

    pub fn getAnsiCode(self: Self) []const u8 {
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
    if (global_syscall_manager != null) return;

    var mgr = SyscallManager.init();

    const ntdll = win.GetModuleHandleW(W("ntdll.dll")).?;
    const NtWriteFileP: [*]const u8 = @ptrCast((win.GetProcAddress(ntdll, "NtWriteFile")).?);

    // Register the real ntdll export into the generic table
    mgr.addFromStub(.NtWriteFile, NtWriteFileP) catch @panic("Could not register NtWriteFile");

    global_syscall_manager = mgr;
}
fn raw_printer(bytes: []const u8) void {
    //  mov     rax, gs:60h
    //  mov     rcx, [rax+20h]
    //  mov     rdi, [rcx+28h]
    const stdout = asm volatile (".byte 0x65, 0x48, 0x8B, 0x04, 0x25, 0x60, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x48, 0x20, 0x48, 0x8B, 0x79, 0x28\n"
        : [ret] "={rdi}" (-> usize),
        :
        : .{ .rax = true, .rcx = true, .rdi = true });

    var io_block: win.IO_STATUS_BLOCK = undefined;

    // Single generic call for every syscall
    _ = global_syscall_manager.?.invoke(.NtWriteFile, .{
        stdout, // FileHandle: usize
        0, // Event
        0, // ApcRoutine
        0, // ApcContext
        &io_block, // *IO_STATUS_BLOCK
        bytes.ptr, // [*]const u8
        bytes.len, // usize
        0, // ByteOffset
        0, // Key
    }) catch return;
}

const WriterError = error{
    RuntimeRawPrinterUnset,
};

pub const CustomWriter = struct {
    pub const Self = @This();

    pub const Writer = struct {
        interface: std.Io.Writer,

        fn drain(io_w: *std.Io.Writer, parts: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Writer = @fieldParentPtr("interface", io_w);
            _ = self;

            if (global_syscall_manager == null) {
                return error.WriteFailed;
            }

            const piece = if (splat > 0) parts[parts.len - 1] else parts[0];
            raw_printer(piece);
            return piece.len;
        }
    };

    pub fn writer(self: *Self, buffer: []u8) Writer {
        _ = self;
        return .{
            .interface = .{
                .buffer = buffer,
                .vtable = &.{ .drain = Writer.drain },
            },
        };
    }
};

/// Like `std.debug.print` but routed through `CustomWriter` on 0.15.1.
/// Note: use buffering and flush if you care about perf.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var cw = CustomWriter{};
    // You can choose a real buffer size; zero-length disables buffering.
    var buf: [0]u8 = undefined;
    var w = cw.writer(buf[0..]);
    const io: *std.Io.Writer = &w.interface;

    // New API: call .print on the Writer interface.
    io.print(fmt, args) catch @panic("CustomPrintFailed");
    // Flushing is a no-op for our minimal drain-only writer, but harmless.
    io.flush() catch {};
}
