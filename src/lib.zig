//! C bindings for zig websockets

const builtin = @import("builtin");
const std = @import("std");
const WS = @import("ws");
const ascii = std.ascii;
const mem = std.mem;
const Uri = std.Uri;
const CallingConvention = std.builtin.CallingConvention;

//const conv = if (builtin.target.os.tag == .windows) CallingConvention.winapi else CallingConvention.c;
const conv = CallingConvention.c;

const CStr = [*c]const u8;

var opt_gpa: ?std.heap.DebugAllocator(.{}) = null;

const WsppError = enum(c_int) {
    OK = 0,
    InvalidState = 1,
    InvalidArgument = 2,
    Unknown = -1,
};

fn wspp_init() callconv(conv) void {
    if (opt_gpa == null) {
        opt_gpa = std.heap.DebugAllocator(.{}){};
    }
}

fn wspp_deinit() callconv(conv) void {
    if (opt_gpa) |gpa| {
        gpa.deinit();
        opt_gpa = null;
    }
}

pub export fn wspp_new(uriString: CStr) callconv(conv) ?*WS {
    // parse uri
    // set tls
    // set hostname
    if (uriString == null) {
        return null;
    }
    wspp_init();
    const allocator = opt_gpa.?.allocator();
    const ws = allocator.create(WS) catch return null;
    const uri = Uri.parse(mem.span(uriString)) catch {
        allocator.destroy(ws);
        return null;
    };
    if (uri.host == null) {
        // scheme missing (scheme probably is set to what host should be)
        // TODO: insert default scheme instead?
        allocator.destroy(ws);
        return null;
    }
    ws.* = WS.init(allocator, uri) catch {
        allocator.destroy(ws);
        return null;
    };
    return ws;
}

pub export fn wspp_delete(wspp: ?*WS) callconv(conv) void {
    if (wspp) |ptr| {
        if (opt_gpa == null) {
            return; // panic?
        }
        const allocator = opt_gpa.?.allocator();
        _ = wspp_close(ptr, 1001, "Going Away");
        allocator.destroy(ptr);
    }
}

/// Handle received bytes and dispatch events; blocks for 1ms.
/// Returns number of messages handled?
pub export fn wspp_poll(wspp: ?*WS) callconv(conv) u64 {
    if (wspp) |ptr| {
        return ptr.poll();
    }
    return 0;
}

/// Handle received bytes and dispatch events. Blocks until shutdown.
/// Returns number of messages handled?
pub export fn wspp_run(wspp: ?*WS) callconv(conv) u64 {
    if (wspp) |ptr| {
        return ptr.run();
    }
    return 0;
}

pub export fn wspp_stopped(wspp: ?*WS) callconv(conv) c_int {
    if (wspp) |ptr| {
        return if (ptr.stopped()) 1 else 0;
    }
    return 1; // null socket is stopped
}

pub export fn wspp_connect(wspp: ?*WS) callconv(conv) c_int {
    if (wspp) |ptr| {
        ptr.connect() catch |err| switch (err) {
            else => return @intFromEnum(WsppError.Unknown),
        };
        return @intFromEnum(WsppError.OK);
    }
    return @intFromEnum(WsppError.InvalidState);
}

pub export fn wspp_close(wspp: ?*WS, code: u16, reason: CStr) callconv(conv) c_int {
    if (wspp) |ptr| {
        ptr.close(code, mem.span(reason)) catch |err| switch (err) {
            else => return @intFromEnum(WsppError.Unknown),
        };
        return @intFromEnum(WsppError.OK);
    }
    return @intFromEnum(WsppError.InvalidState);
}

pub export fn wspp_send_text(wspp: ?*WS, message: CStr) callconv(conv) c_int {
    if (wspp) |ptr| {
        ptr.sendText(mem.span(message)) catch |err| switch (err) {
            else => return @intFromEnum(WsppError.Unknown),
        };
        return @intFromEnum(WsppError.OK);
    }
    return @intFromEnum(WsppError.InvalidState);
}

pub export fn wspp_send_binary(wspp: ?*WS, message: CStr, length: u64) callconv(conv) c_int {
    // TODO: error out if length > usize_max
    if (wspp) |ptr| {
        const msgPtr: [*]const u8 = @ptrCast(message);
        const slice = msgPtr[0..@intCast(length)];
        ptr.sendBinary(slice) catch |err| switch (err) {
            else => return @intFromEnum(WsppError.Unknown),
        };
        return @intFromEnum(WsppError.OK);
    }
    return @intFromEnum(WsppError.InvalidState);
}

pub export fn wspp_ping(wspp: ?*WS, message: CStr, length: u64) callconv(conv) c_int {
    if (wspp) |ptr| {
        if (length > 125) {
            return @intFromEnum(WsppError.InvalidArgument);
        }
        const msgPtr: [*]const u8 = @ptrCast(message);
        const slice = msgPtr[0..@intCast(length)];
        ptr.ping(slice) catch |err| switch (err) {
            else => return @intFromEnum(WsppError.Unknown),
        };
        return @intFromEnum(WsppError.OK);
    }
    return @intFromEnum(WsppError.InvalidState);
}

pub export fn wspp_set_open_handler(wspp: ?*WS, f: ?*anyopaque) callconv(conv) void {
    if (wspp) |ptr| {
        ptr.on_open = @ptrCast(f);
    }
}

pub export fn wspp_set_close_handler(wspp: ?*WS, f: ?*anyopaque) callconv(conv) void {
    if (wspp) |ptr| {
        ptr.on_close = @ptrCast(f);
    }
}

pub export fn wspp_set_message_handler(wspp: ?*WS, f: ?*anyopaque) callconv(conv) void {
    if (wspp) |ptr| {
        ptr.on_message = @ptrCast(f);
    }
}

pub export fn wspp_set_error_handler(wspp: ?*WS, f: ?*anyopaque) callconv(conv) void {
    if (wspp) |ptr| {
        ptr.on_error = @ptrCast(f);
    }
}

pub export fn wspp_set_pong_handler(wspp: ?*WS, f: ?*anyopaque) callconv(conv) void {
    if (wspp) |ptr| {
        ptr.on_pong = @ptrCast(f);
    }
}
