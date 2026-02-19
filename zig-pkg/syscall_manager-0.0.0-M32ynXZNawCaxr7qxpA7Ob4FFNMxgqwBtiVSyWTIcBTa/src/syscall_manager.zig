const std = @import("std");
const syscall_lib = @import("syscall_wrapper.zig");
const winc = @import("Windows.h.zig");
const win = std.os.windows;

pub const Syscall = syscall_lib.Syscall;

const syscall_manager_error = error{
    SyscallMissing,
    BadSpec,
};

// 1) Declare the syscalls you care about ONCE here: enum + signature specs.
pub const SysId = enum {
    NtVirtualProtectMemory,
    NtAllocateVirtualMemory,
    NtOpenProcess,
    NtWriteFile,
    NtUserGetAsyncKeyState,
};

inline fn specOf(comptime which: SysId) Spec {
    // Force tuple indexing to happen at comptime
    return comptime SPECS[idxOf(which)];
}
const Spec = struct { id: SysId, signature: type };

const SPECS = .{
    Spec{
        .id = .NtVirtualProtectMemory,
        .signature = fn (
            ProcessHandle: usize,
            PBaseAddress: *usize,
            NumberOfBytesToProtect: *usize,
            NewAccessProtection: usize,
            OldAccessProtection: *usize,
        ) syscall_manager_error!usize,
    },
    Spec{
        .id = .NtAllocateVirtualMemory,
        .signature = fn (
            BaseAddress: *?[*]u8,
            ZeroBits: usize,
            RegionSize: *usize,
            AllocationType: usize,
            Protect: usize,
        ) syscall_manager_error!usize,
    },
    Spec{
        .id = .NtOpenProcess,
        .signature = fn (
            ProcessHandle: *usize,
            DesiredAcess: usize,
            ObjectAttributes: *anyopaque,
            ClientId: *anyopaque,
        ) syscall_manager_error!usize,
    },
    Spec{
        .id = .NtWriteFile,
        .signature = fn (
            FileHandle: usize,
            Event: usize,
            ApcRoutive: usize,
            ApcContext: usize,
            IoStatusBlock: *win.IO_STATUS_BLOCK,
            Buffer: [*]const u8,
            Length: usize,
            ByteOffset: usize,
            Key: usize,
        ) syscall_manager_error!usize,
    },
    Spec{
        .id = .NtUserGetAsyncKeyState,
        .signature = fn (key: u32, numCallIdx: u32) syscall_manager_error!usize,
    },
};
inline fn coerceParam(comptime T: type, x: anytype) T {
    const X = @TypeOf(x);
    if (X == T) return x;

    const tinfo = @typeInfo(T);
    switch (tinfo) {
        .pointer => {
            const xinfo = @typeInfo(X);
            switch (xinfo) {
                .pointer => |p| {
                    if (p.size == .slice) return @as(T, @ptrFromInt(@intFromPtr(x.ptr)));
                    return @as(T, @ptrFromInt(@intFromPtr(x)));
                },
                .array => return @as(T, @ptrFromInt(@intFromPtr(&x))),
                .optional => {
                    if (x) |v| return coerceParam(T, v);
                    return @as(T, @ptrFromInt(0));
                },
                else => @compileError("Cannot coerce " ++ @typeName(X) ++ " to " ++ @typeName(T)),
            }
        },
        .int, .comptime_int => {
            const xinfo = @typeInfo(X);
            switch (xinfo) {
                .int, .comptime_int, .@"enum", .bool => return @as(T, @intCast(x)),
                .pointer => return @as(T, @intCast(@intFromPtr(x))),
                .optional => {
                    if (x) |v| return coerceParam(T, v);
                    return @as(T, 0);
                },
                else => @compileError("Cannot coerce " ++ @typeName(X) ++ " to " ++ @typeName(T)),
            }
        },
        .@"enum" => return @as(T, @enumFromInt(coerceParam(@typeInfo(T).Enum.tag_type, x))),
        else => return x,
    }
}
// Helper: comptime index for an enum tag in SPECS.
fn idxOf(comptime which: SysId) usize {
    inline for (SPECS, 0..) |s, i| {
        if (s.id == which) return i;
    }
    @compileError("SysId not found in SPECS: " ++ @tagName(which));
}

pub const SyscallManager = struct {
    const Self = @This();

    // One slot per spec. No dynamic allocation needed.
    slots: [SPECS.len]?Syscall,

    pub fn init() Self {
        var s: Self = undefined;
        inline for (&s.slots) |*p| p.* = null;
        return s;
    }

    /// Register a syscall for the given enum tag.
    pub fn add(self: *Self, comptime which: SysId, sc: Syscall) void {
        self.slots[idxOf(which)] = sc;
    }

    /// Convenience: derive the Syscall by parsing the stub bytes and register it.
    pub fn addFromStub(self: *Self, comptime which: SysId, stub: [*]u8) !void {
        const sc = try Syscall.fetch(stub);
        self.add(which, sc);
    }

    pub fn has(self: *Self, comptime which: SysId) bool {
        return self.slots[idxOf(which)] != null;
    }

    /// One generic, type-checked caller for all syscalls.
    /// Usage: try mgr.invoke(.NtWriteFile, .{ fh, ev, apc, ctx, &iosb, buf, len, offs, key });
    pub fn invoke(self: *Self, comptime which: SysId, args: anytype) !usize {
        const Sig = specOf(which).signature; // <- comptime-safe
        const Expect = std.meta.ArgsTuple(Sig);

        const expect_fields = std.meta.fields(Expect);
        const got_fields = std.meta.fields(@TypeOf(args));

        comptime {
            if (expect_fields.len != got_fields.len) {
                @compileError("Wrong number of arguments for " ++ @tagName(which) ++
                    ". Expected " ++ std.fmt.comptimePrint("{d}", .{expect_fields.len}) ++
                    ", got " ++ std.fmt.comptimePrint("{d}", .{got_fields.len}));
            }
        }

        // Normalize each element to the exact expected param type,
        // so comptime literals and string literals are accepted.
        var norm: Expect = undefined;
        inline for (expect_fields, 0..) |ef, i| {
            @field(norm, ef.name) = coerceParam(ef.type, @field(args, got_fields[i].name));
        }

        const sc = self.slots[idxOf(which)] orelse return syscall_manager_error.SyscallMissing;
        return sc.call(norm);
    }
};

const builtin = @import("builtin");
const W = std.unicode.utf8ToUtf16LeStringLiteral;

// If you put this in a separate file, also:
// const manager_mod = @import("syscall_manager.zig");
// const SyscallManager = manager_mod.SyscallManager;
// const SysId = manager_mod.SysId;
// const Syscall = manager_mod.Syscall;
// const syscall_manager_error = manager_mod.syscall_manager_error;

// Helpers
fn getNtdllProc(name: [*:0]const u8) [*]u8 {
    const ntdll = win.kernel32.GetModuleHandleW(W("ntdll.dll")).?;
    const p = win.kernel32.GetProcAddress(ntdll, name) orelse
        @panic("GetProcAddress failed");
    return @ptrCast(p);
}

fn openNulWrite() win.HANDLE {
    const h = win.kernel32.CreateFileW(
        W("NUL"),
        win.GENERIC_WRITE,
        win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
        null,
        win.OPEN_EXISTING,
        win.FILE_ATTRIBUTE_NORMAL,
        null,
    );

    // Handle both signatures across Zig versions:
    switch (@typeInfo(@TypeOf(h))) {
        .optional => return h orelse @panic("CreateFileW(NUL) failed"),
        else => {
            if (h == win.INVALID_HANDLE_VALUE) @panic("CreateFileW(NUL) failed");
            return h;
        },
    }
}

test "SyscallManager registers NtWriteFile from ntdll and reports presence" {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64)
        return error.SkipZigTest;

    var mgr = SyscallManager.init();

    const stub = getNtdllProc("NtWriteFile");
    try mgr.addFromStub(.NtWriteFile, stub);

    try std.testing.expect(mgr.has(.NtWriteFile));
    try std.testing.expect(!mgr.has(.NtOpenProcess)); // not added yet
}

test "invoke(.NtWriteFile) writes to NUL and returns STATUS_SUCCESS" {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64)
        return error.SkipZigTest;

    var mgr = SyscallManager.init();

    // Resolve and register the real syscall
    try mgr.addFromStub(.NtWriteFile, getNtdllProc("NtWriteFile"));

    // Open NUL device for a harmless synchronous write
    const h = openNulWrite();
    // defer _ = win.kernel32.CloseHandle(h);

    var iosb: win.IO_STATUS_BLOCK = undefined;

    const msg = "hello\n";
    const status = try mgr.invoke(.NtWriteFile, .{
        @intFromPtr(h), // FileHandle: usize
        0, // Event: HANDLE (pass 0)
        0, // ApcRoutine: PIO_APC_ROUTINE
        0, // ApcContext: PVOID
        &iosb, // IoStatusBlock: *IO_STATUS_BLOCK
        msg.ptr, // Buffer: [*]const u8
        msg.len, // Length: usize
        0, // ByteOffset: PLARGE_INTEGER (0 = append/current)
        0, // Key: PULONG (optional)
    });

    // NTSTATUS == STATUS_SUCCESS (0) on success
    try std.testing.expectEqual(@as(usize, 0), status);
}

test "invoking a syscall that hasn't been registered returns SyscallMissing" {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64)
        return error.SkipZigTest;

    var mgr = SyscallManager.init();

    var iosb: win.IO_STATUS_BLOCK = undefined;
    const msg = "x";

    // Nothing registered; call should error
    try std.testing.expectError(syscall_manager_error.SyscallMissing, mgr.invoke(.NtWriteFile, .{
        0, 0, 0, 0, &iosb, msg.ptr, msg.len, 0, 0,
    }));
}
