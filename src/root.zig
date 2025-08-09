//! Implementation details of c-wsppzig

allocator: mem.Allocator,
host: []u8,
port: u16,
path: []u8,
tls: bool,
mutex: Thread.Mutex, // used to not get interleaved writes, also on Windows we can't read and write at the same time
client: ?websocket.Client = null,
on_open: ?OnOpenCallback = null,
on_close: ?OnCloseCallback = null,
on_message: ?OnMessageCallback = null,
on_error: ?OnErrorCallback = null,
on_pong: ?OnPongCallback = null,
open: bool = false,
open_fired: bool = false,

const builtin = @import("builtin");
const std = @import("std");
const ascii = std.ascii;
const heap = std.heap;
const mem = std.mem;
const websocket = @import("websocket");
const testing = std.testing;
const Uri = std.Uri;
const CallingConvention = std.builtin.CallingConvention;
const Thread = std.Thread;

// TODO: wrap in lib.zig instead
//const conv = if (builtin.target.os.tag == .windows) CallingConvention.winapi else CallingConvention.c;
const conv = CallingConvention.c;

const Self = @This();

const OnOpenCallback = *const fn () callconv(conv) void;
const OnCloseCallback = *const fn () callconv(conv) void;
const OnMessageCallback = *const fn ([*]const u8, u64, i32) callconv(conv) void;
const OnErrorCallback = *const fn ([*:0]const u8) callconv(conv) void;
const OnPongCallback = *const fn ([*]const u8, u64) callconv(conv) void;

pub fn init(allocator: mem.Allocator, uri: Uri) !Self {
    var arena = heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tls = !ascii.eqlIgnoreCase(uri.scheme, "ws");
    const port: u16 = uri.port orelse if (tls) 443 else 80;
    const host = if (uri.host) |host_component|
        try allocator.dupe(u8, try host_component.toRawMaybeAlloc(arena.allocator()))
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(host);
    const path = try allocator.dupe(u8, if (uri.path.isEmpty()) "/" else uri.path.percent_encoded);
    errdefer allocator.free(path);

    return .{
        .allocator = allocator,
        .host = host,
        .port = port,
        .path = path,
        .tls = tls,
        .mutex = .{},
    };
}

pub fn deinit(self: *Self) void {
    if (self.client == null) {
        return;
    }
    // TODO: self.client.?.close(...) if not already closed
    self.client.?.deinit();
    self.allocator.free(self.host);
    self.client = null;
}

pub fn poll(self: *Self) u64 {
    var client = &(self.client orelse {
        if (self.on_error) |f| {
            f("Invalid State");
        }
        return 0;
    });
    if (!self.open_fired) {
        self.open_fired = true;
        if (self.on_open) |f| {
            f();
            return 1; // the handshake
        }
    }
    var events: u64 = 0;
    var locked = false;
    for (0..16) |_| {
        if (comptime builtin.target.os.tag == .windows) {
            // On Windows, we can't read and write at the same time
            self.mutex.lock();
            locked = true;
        }
        defer if (locked) self.mutex.unlock();
        const message = client.read() catch |err| switch (err) {
            error.Closed => {
                // TODO: if onClose not sent, send now maybe?
                if (self.on_error) |f| {
                    f("Invalid state");
                }
                break;
            },
            else => {
                if (self.on_error) |f| {
                    f("Read failed");
                }
                break;
            },
        } orelse {
            break;
        };
        defer client.done(message);
        if (locked) {
            self.mutex.unlock();
            locked = false;
        }
        events += 1;
        switch (message.type) {
            .text => {
                if (self.on_message) |f| {
                    f(message.data.ptr, @intCast(message.data.len), @intFromEnum(websocket.proto.OpCode.text) & 0x7f);
                }
            },
            .binary => {
                if (self.on_message) |f| {
                    f(message.data.ptr, @intCast(message.data.len), @intFromEnum(websocket.proto.OpCode.binary) & 0x7f);
                }
            },
            .close => {
                // TODO: maybe check atomic close_fired
                if (self.on_close) |f| {
                    f();
                }
            },
            .ping => {
                self.mutex.lock();
                defer self.mutex.unlock();
                client.writePong(message.data) catch {};
            },
            .pong => {
                if (self.on_pong) |f| {
                    f(message.data.ptr, @intCast(message.data.len));
                }
            },
        }
    }

    return events;
}

pub fn run(self: *Self) u64 {
    _ = self;
    @panic("ws.run not implemented");
}

pub fn stopped(self: *Self) bool {
    if (self.client) |client| {
        return client._closed;
    }
    return true;
}

pub fn connect(self: *Self) !void {
    const is_default_port = (self.tls and self.port == 443) or (!self.tls and self.port == 80);
    const headers = if (is_default_port)
        try std.fmt.allocPrint(self.allocator, "Host: {s}\r\n", .{self.host})
    else
        try std.fmt.allocPrint(self.allocator, "Host: {s}:{d}\r\n", .{ self.host, self.port });
    defer self.allocator.free(headers);
    // TODO: make this non-blocking (in a thread?)
    self.client = try websocket.Client.init(self.allocator, .{
        .host = self.host,
        .port = self.port,
        .max_size = 100 * 1024 * 1024, // 100MiB should be safe
        .tls = self.tls,
        .compression = .{
            .write_threshold = 16,
            //.client_no_context_takeover = true,
            //.server_no_context_takeover = true,
        },
    });
    var client = &self.client.?;
    errdefer {
        client.deinit();
        self.client = null;
    }
    try client.handshake(self.path, .{
        .timeout_ms = 4500, // less than 5sec for multiclient
        .headers = headers,
    });
    errdefer client.close(.{ .code = 1001, .reason = "Internal Error" }) catch unreachable;
    if (client._compression != null and
        client._compression.?.reset and
        client._compression.?.write_treshold < 150)
    {
        // if there is no context takeover, we don't want to send messages compressed that won't get smaller
        client._compression.?.write_treshold = 150;
    }
    try client.readTimeout(1); // NOTE: this doesn't work on Windows
    self.open = true; // TODO: atomic
}

pub fn close(self: *Self, code: u16, reason: []const u8) !void {
    if (self.client == null) {
        return;
    }
    const err = self.client.?.close(.{
        .code = code,
        .reason = reason,
    });

    // TODO: maybe check atomic close_fired
    if (self.on_close) |f| {
        f();
    }

    return err;
}

pub fn sendText(self: *Self, message: []const u8) !void {
    var client = &(self.client orelse {
        return error.InvalidState;
    });
    // TODO: arena for those dupes?
    const messageCopy = try self.allocator.dupe(u8, message);
    defer self.allocator.free(messageCopy);
    self.mutex.lock();
    defer self.mutex.unlock();
    try client.writeText(messageCopy);
}

pub fn sendBinary(self: *Self, message: []const u8) !void {
    var client = &(self.client orelse {
        return error.InvalidState;
    });
    // TODO: arena for those dupes?
    const messageCopy = try self.allocator.dupe(u8, message);
    defer self.allocator.free(messageCopy);
    self.mutex.lock();
    defer self.mutex.unlock();
    try client.writeBin(messageCopy);
}

pub fn ping(self: *Self, message: []const u8) !void {
    var client = &(self.client orelse {
        return error.InvalidState;
    });
    // TODO: arena for those dupes?
    const messageCopy = try self.allocator.dupe(u8, message);
    defer self.allocator.free(messageCopy);
    self.mutex.lock();
    defer self.mutex.unlock();
    try client.writePing(messageCopy);
}
