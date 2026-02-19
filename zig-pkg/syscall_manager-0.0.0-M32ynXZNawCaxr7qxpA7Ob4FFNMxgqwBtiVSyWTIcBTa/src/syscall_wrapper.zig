const std = @import("std");

extern fn syscall_wrapper(syscall_number: u32, argcount: usize, args: [*]usize) usize;

pub const syscallError = error{BadFunction};

pub const Syscall = struct {
    syscall_number: u16,

    const Self = @This();

    pub fn init(syscall_number: u16) Self {
        return .{ .syscall_number = syscall_number };
    }

    // Converts common arg types to usize automatically.
    inline fn toUsize(x: anytype) usize {
        const T = @TypeOf(x);
        switch (@typeInfo(T)) {
            .pointer => |p| {
                if (p.size == .slice) {
                    // []T / []const T -> pass pointer part
                    return @intFromPtr(x.ptr);
                } else {
                    return @intFromPtr(x);
                }
            },
            .optional => |opt| {
                // Support ?[*]T / ?*T / ?[]T; null -> 0
                if (x) |val| {
                    const child = opt.child;
                    const child_info = @typeInfo(child);
                    switch (child_info) {
                        .pointer => |p| {
                            if (p.size == .slice) return @intFromPtr(val.ptr);
                            return @intFromPtr(val);
                        },
                        .int, .comptime_int, .@"enum", .bool => return @as(usize, @intCast(val)),
                        else => @compileError("Unsupported optional argument type; pass a pointer/int or usize."),
                    }
                } else {
                    return 0;
                }
            },
            .int, .comptime_int, .@"enum", .bool => return @as(usize, @intCast(x)),
            .array => return @intFromPtr(&x),
            else => @compileError("Unsupported argument type for syscall; pass pointer/int/usize."),
        }
    }

    pub fn call(self: *const Syscall, args: anytype) usize {
        const fields = std.meta.fields(@TypeOf(args));
        const N = fields.len;
        var values: [N]usize = undefined;

        inline for (fields, 0..) |field, i| {
            values[i] = toUsize(@field(args, field.name));
        }
        return syscall_wrapper(self.syscall_number, N, &values);
    }

    pub fn fetch(func_ptr: [*]u8) !Self {
        // 4C 8B D1 B8 ?? ??
        const magic: u32 = 0xB8D18B4C;
        const magic_ptr: *u32 = @ptrCast(@alignCast(func_ptr));
        if (magic_ptr.* != magic) return syscallError.BadFunction;

        const syscall_number_ptr: *u16 = @ptrCast(@alignCast(func_ptr[4..]));
        const syscall_number: u16 = syscall_number_ptr.*;
        return Syscall.init(syscall_number);
    }
};

pub fn set_registers(arg1: u64, arg2: u64) void {
    asm volatile (
        \\mov %[val1], %%rcx
        \\mov %[val2], %%rax
        :
        : [val1] "r" (arg1),
          [val2] "r" (arg2),
        : .{ .rcx = true, .rax = true }
    );
}
