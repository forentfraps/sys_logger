const std = @import("std");
const SyscallManager = @import("syscall_manager").SyscallManager;
const Syscall = @import("syscall_manager").Syscall;
const builtin = @import("builtin");
const win = @import("zigwin32");
const W = std.unicode.utf8ToUtf16LeStringLiteral;

var global_syscall_manager: ?SyscallManager = null;

pub fn initRawPrinter() void {
    if (global_syscall_manager != null) return;

    var mgr = SyscallManager.init();

    const ntdll = win.system.library_loader.GetModuleHandleW(
        W("ntdll.dll"),
    ).?;
    const NtWriteFileP: [*]const u8 = @ptrCast((win.system.library_loader.GetProcAddress(ntdll, "NtWriteFile")).?);

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

    var io_block: win.system.windows_programming.IO_STATUS_BLOCK = undefined;

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

pub const LoggerBackend = enum {
    nt_write_file,
    std_debug,
};

pub const SysLoggerColour = enum {
    none,

    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,

    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    gray,
    orange,
    pink,

    white_on_red,
    black_on_yellow,
    black_on_cyan,

    pub fn ansi(self: @This()) []const u8 {
        return switch (self) {
            .none => "\x1b[0m",

            .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",

            .bright_black => "\x1b[90m",
            .bright_red => "\x1b[91m",
            .bright_green => "\x1b[92m",
            .bright_yellow => "\x1b[93m",
            .bright_blue => "\x1b[94m",
            .bright_magenta => "\x1b[95m",
            .bright_cyan => "\x1b[96m",
            .bright_white => "\x1b[97m",

            .gray => "\x1b[38;5;245m",
            .orange => "\x1b[38;5;208m",
            .pink => "\x1b[38;5;213m",

            .white_on_red => "\x1b[37;41m",
            .black_on_yellow => "\x1b[30;43m",
            .black_on_cyan => "\x1b[30;46m",
        };
    }

    pub fn reset() []const u8 {
        return "\x1b[0m";
    }
};

pub const default_palette = [_]SysLoggerColour{
    .bright_green,
    .bright_blue,
    .bright_cyan,
    .bright_yellow,
    .bright_magenta,
    .orange,
    .pink,
    .green,
    .blue,
    .cyan,
    .yellow,
    .magenta,
    .gray,
    .white,
};

pub const LoggerOptions = struct {
    enabled: bool = true,
    debug_only: bool = true,
    backend: LoggerBackend = .nt_write_file,

    // Replaces the old u256-packed history with a real stack.
    max_context_depth: usize = 256,

    // Formatting buffers.
    msg_buf_size: usize = 1024,
    line_buf_size: usize = 1536,
    ctx_buf_size: usize = 256,

    // Output style.
    show_function: bool = true,
    show_line: bool = true,
    show_context_chain: bool = true,

    info_palette: []const SysLoggerColour = default_palette[0..],
    crit_colour: SysLoggerColour = .white_on_red,
};

pub const NullScope = struct {
    pub inline fn end(_: @This()) void {}
};

pub const NullLogger = struct {
    pub inline fn init() @This() {
        return .{};
    }

    pub inline fn raw_print(_: *@This(), comptime _: []const u8, _: anytype) void {}
    pub inline fn info(_: *@This(), comptime _: []const u8, _: anytype) void {}
    pub inline fn info16(_: *@This(), comptime _: []const u8, _: anytype, _: []const u16) void {}
    pub inline fn crit(_: *@This(), comptime _: []const u8, _: anytype) void {}
    pub inline fn crit16(_: *@This(), comptime _: []const u8, _: anytype, _: []const u16) void {}

    pub inline fn setContext(_: *@This(), comptime _: []const u8) void {}
    pub inline fn push(_: *@This(), comptime _: []const u8) NullScope {
        return .{};
    }

    pub inline fn pushEnum(_: *@This(), _: anytype) NullScope {
        return .{};
    }

    pub inline fn rollbackContext(_: *@This()) void {}
};

pub fn SysLogger(comptime opts: LoggerOptions) type {
    const compile_enabled = opts.enabled and (!opts.debug_only or builtin.mode == .Debug);
    return if (compile_enabled) ActiveLogger(opts) else NullLogger;
}

fn ActiveLogger(comptime opts: LoggerOptions) type {
    return struct {
        enabled: bool = true,
        context_depth: usize = 0,
        context_stack: [opts.max_context_depth][]const u8 = undefined,

        const Self = @This();

        pub const Scope = struct {
            logger: *Self,

            pub inline fn end(self: @This()) void {
                self.logger.rollbackContext();
            }
        };

        const Severity = enum {
            info,
            crit,
        };

        pub inline fn init() Self {
            if (opts.backend == .nt_write_file) {
                initRawPrinter();
            }
            return .{};
        }

        pub inline fn raw_print(self: *Self, comptime msg: []const u8, args: anytype) void {
            if (!self.enabled) return;
            emit(msg, args);
        }

        pub inline fn info(self: *Self, comptime msg: []const u8, args: anytype) void {
            self.log(.info, @src(), msg, args);
        }

        pub inline fn crit(self: *Self, comptime msg: []const u8, args: anytype) void {
            self.log(.crit, @src(), msg, args);
        }

        pub inline fn info16(self: *Self, comptime msg: []const u8, args: anytype, arg16: []const u16) void {
            self.log16(.info, @src(), msg, args, arg16);
        }

        pub inline fn crit16(self: *Self, comptime msg: []const u8, args: anytype, arg16: []const u16) void {
            self.log16(.crit, @src(), msg, args, arg16);
        }

        // Optional manual context labels when function name alone is not enough.
        pub inline fn setContext(self: *Self, comptime label: []const u8) void {
            if (self.context_depth >= opts.max_context_depth) return;
            self.context_stack[self.context_depth] = label;
            self.context_depth += 1;
        }

        pub inline fn push(self: *Self, comptime label: []const u8) Scope {
            self.setContext(label);
            return .{ .logger = self };
        }

        // Zero setup enum support:
        //   var s = log.pushEnum(.ImpFix); defer s.end();
        pub inline fn pushEnum(self: *Self, tag: anytype) Scope {
            return self.push(@tagName(tag));
        }

        pub inline fn rollbackContext(self: *Self) void {
            if (self.context_depth == 0) return;
            self.context_depth -= 1;
        }

        fn log(
            self: *Self,
            comptime sev: Severity,
            comptime src: std.builtin.SourceLocation,
            comptime msg: []const u8,
            args: anytype,
        ) void {
            if (!self.enabled) return;

            var msg_buf: [opts.msg_buf_size]u8 = undefined;
            const payload = std.fmt.bufPrint(&msg_buf, msg, args) catch return;

            var line_buf: [opts.line_buf_size]u8 = undefined;
            const fn_name = shortFnName(src.fn_name);
            const colour = switch (sev) {
                .info => colourForLabel(fn_name),
                .crit => opts.crit_colour,
            };

            const full_line = if (opts.show_context_chain and self.context_depth != 0) blk: {
                var ctx_buf: [opts.ctx_buf_size]u8 = undefined;
                const ctx = self.contextChain(&ctx_buf);
                break :blk std.fmt.bufPrint(
                    &line_buf,
                    "{s}[{s}:{d} | {s}] {s}{s}\n",
                    .{ colour.ansi(), fn_name, src.line, ctx, payload, SysLoggerColour.reset() },
                ) catch return;
            } else blk: {
                break :blk std.fmt.bufPrint(
                    &line_buf,
                    "{s}[{s}:{d}] {s}{s}\n",
                    .{ colour.ansi(), fn_name, src.line, payload, SysLoggerColour.reset() },
                ) catch return;
            };

            writeBytes(full_line);
        }

        fn log16(
            self: *Self,
            comptime sev: Severity,
            comptime src: std.builtin.SourceLocation,
            comptime msg: []const u8,
            args: anytype,
            arg16: []const u16,
        ) void {
            if (!self.enabled) return;

            var msg_buf: [opts.msg_buf_size]u8 = undefined;
            const payload = std.fmt.bufPrint(&msg_buf, msg, args) catch return;

            var line_buf: [opts.line_buf_size]u8 = undefined;
            const fn_name = shortFnName(src.fn_name);
            const colour = switch (sev) {
                .info => colourForLabel(fn_name),
                .crit => opts.crit_colour,
            };

            const prefix = if (opts.show_context_chain and self.context_depth != 0) blk: {
                var ctx_buf: [opts.ctx_buf_size]u8 = undefined;
                const ctx = self.contextChain(&ctx_buf);
                break :blk std.fmt.bufPrint(
                    &line_buf,
                    "{s}[{s}:{d} | {s}] {s} -> ",
                    .{ colour.ansi(), fn_name, src.line, ctx, payload },
                ) catch return;
            } else blk: {
                break :blk std.fmt.bufPrint(
                    &line_buf,
                    "{s}[{s}:{d}] {s} -> ",
                    .{ colour.ansi(), fn_name, src.line, payload },
                ) catch return;
            };

            writeBytes(prefix);
            writeUtf16Lossy(arg16);
            writeBytes(SysLoggerColour.reset());
            writeBytes("\n");
        }

        fn emit(comptime fmt: []const u8, args: anytype) void {
            var buf: [opts.line_buf_size]u8 = undefined;
            const out = std.fmt.bufPrint(&buf, fmt, args) catch return;
            writeBytes(out);
        }

        fn writeBytes(bytes: []const u8) void {
            switch (opts.backend) {
                .nt_write_file => raw_printer(bytes),
                .std_debug => std.debug.print("{s}", .{bytes}),
            }
        }

        fn writeUtf16Lossy(text: []const u16) void {
            var utf8_buf: [4]u8 = undefined;

            for (text) |cu| {
                // Cheap BMP-only output for logs. Surrogates become '?'.
                const cp: u21 = if (cu >= 0xD800 and cu <= 0xDFFF)
                    @as(u21, '?')
                else
                    @as(u21, cu);

                const len = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
                writeBytes(utf8_buf[0..len]);
            }
        }

        fn shortFnName(full: []const u8) []const u8 {
            const idx = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
            return full[idx + 1 ..];
        }

        fn colourForLabel(label: []const u8) SysLoggerColour {
            var h: u32 = 2166136261;
            for (label) |c| {
                h = (h ^ c) *% 16777619;
            }
            return opts.info_palette[h % opts.info_palette.len];
        }

        fn contextChain(self: *Self, out: []u8) []const u8 {
            var used: usize = 0;
            const sep = " > ";

            for (self.context_stack[0..self.context_depth], 0..) |ctx, i| {
                if (i != 0) {
                    if (used + sep.len > out.len) break;
                    @memcpy(out[used .. used + sep.len], sep[0..]);
                    used += sep.len;
                }

                const remaining = out.len - used;
                if (remaining == 0) break;

                const n = @min(remaining, ctx.len);
                @memcpy(out[used .. used + n], ctx[0..n]);
                used += n;

                if (n != ctx.len) break;
            }

            return out[0..used];
        }
    };
}
