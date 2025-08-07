//! Sameple usage of c-wspp DLL/so

const std = @import("std");
const DynLib = std.DynLib;
const meta = std.meta;
const CallingConvention = std.builtin.CallingConvention;

//const conv = if (builtin.target.os.tag == .windows) CallingConvention.winapi else CallingConvention.c;
const conv = CallingConvention.c;

const WS = opaque {};

const WsppError = enum(c_int) {
    OK = 0,
    InvalidState = 1,
    InvalidArgument = 2,
    Unknown = -1,
    _,
};

const CStr = [*c]const u8;

fn @"🐍"(comptime name: []const u8) []const u8 {
    var res: []const u8 = "";
    for (name) |c| {
        if (c >= 'A' and c <= 'Z') {
            res = res ++ "_" ++ .{c - 'A' + 'a'};
        } else {
            res = res ++ .{c};
        }
    }
    return res;
}

const Lib = struct {
    lib: DynLib,
    f: Funcs,

    const Funcs = struct {
        new: *const fn ([*c]const u8) callconv(conv) ?*WS,
        delete: *const fn (?*WS) callconv(conv) void,
        poll: *const fn (?*WS) callconv(conv) u64,
        run: *const fn (?*WS) callconv(conv) u64,
        stopped: *const fn (?*WS) callconv(conv) c_int,
        connect: *const fn (?*WS) callconv(conv) WsppError,
        close: *const fn (?*WS, u16, CStr) callconv(conv) WsppError,
        sendText: *const fn (?*WS, CStr) callconv(conv) WsppError,
        sendBinary: *const fn (?*WS, *anyopaque, u64) callconv(conv) WsppError,
        ping: *const fn (?*WS, *const anyopaque, u64) callconv(conv) WsppError,
        setOpenHandler: *const fn (?*WS, *const fn () callconv(conv) void) callconv(conv) void,
        setCloseHandler: *const fn (?*WS, *const fn () callconv(conv) void) callconv(conv) void,
        setMessageHandler: *const fn (?*WS, *const fn (CStr, u64, i32) callconv(conv) void) callconv(conv) void,
        setErrorHandler: *const fn (?*WS, *const fn (CStr) callconv(conv) void) callconv(conv) void,
        setPongHandler: *const fn (?*WS, *const fn (CStr, u64) callconv(conv) void) callconv(conv) void,
    };

    fn init(path: []const u8) !Lib {
        var lib = try DynLib.open(path);
        return .{
            .lib = lib,
            .f = initFuncs(&lib) catch |err| {
                lib.close();
                return err;
            },
        };
    }

    fn initFuncs(lib: *DynLib) !Funcs {
        var res: Funcs = undefined;
        inline for (@typeInfo(Funcs).@"struct".fields) |f| {
            const symbol = "wspp_" ++ comptime @"🐍"(f.name);
            @field(res, f.name) = lib.lookup(f.type, symbol) orelse return error.MethodNotFound;
        }
        return res;
    }

    fn deinit(self: *Lib) void {
        self.lib.close();
    }
};

fn onOpen() callconv(conv) void {
    std.debug.print("onOpen\n", .{});
}

fn onClose() callconv(conv) void {
    std.debug.print("onClose\n", .{});
}

fn onMessage(data: CStr, len: u64, op_code: i32) callconv(conv) void {
    const dataPtr: [*]const u8 = @ptrCast(data);
    const slice = dataPtr[0..@intCast(len)];
    std.debug.print("onMessage ({}): {s}\n", .{ op_code, slice });
}

fn onError(msg: CStr) callconv(conv) void {
    std.debug.print("onError: {s}\n", .{msg});
}

fn onPong(data: CStr, len: u64) callconv(conv) void {
    const dataPtr: [*]const u8 = @ptrCast(data);
    const slice = dataPtr[0..@intCast(len)];
    std.debug.print("onPong: {s}\n", .{slice});
}

pub fn main() !void {
    // run with LD_LIBRARY_PATH=...
    // e.g. LD_LIBRARY_PATH=zig-out/lib/ zig build run -Doptimize=ReleaseSmall
    // TODO: std.fs.selfExePathAlloc
    std.debug.print("Loading DLL\n", .{});
    var lib = try Lib.init("zig-out/lib/libc-wspp.so");
    defer lib.deinit();

    std.debug.print("Creating socket ...\n", .{});
    const ws = lib.f.new("wss://archipelago.gg:49186");
    if (ws == null) {
        return error.CouldNotCreateSocket;
    }
    lib.f.setOpenHandler(ws, onOpen);
    lib.f.setCloseHandler(ws, onClose);
    lib.f.setMessageHandler(ws, onMessage);
    lib.f.setErrorHandler(ws, onError);
    lib.f.setPongHandler(ws, onPong);

    std.debug.print("Opening socket ... ", .{});
    const connectErr = lib.f.connect(ws);
    std.debug.print("{}\n", .{connectErr});

    for (0..100) |_| {
        _ = lib.f.poll(ws);
    }

    std.debug.print("Sending stuff ... ", .{});
    const sendErr = lib.f.sendText(ws,
        \\[{
        \\  "cmd": "Connect",
        \\  "name": "Player1",
        \\  "password": "",
        \\  "game": "Secret of Evermore",
        \\  "items_handling": 0,
        \\  "uuid": "",
        \\  "version": {"major": 0, "minor": 6, "build": 2, "class": "Version"},
        \\  "tags": []
        \\}]
    );
    std.debug.print("{}\n", .{sendErr});

    for (0..100) |_| {
        _ = lib.f.poll(ws);
    }

    const msg = "test";
    _ = lib.f.ping(ws, msg, msg.len);

    for (0..100) |_| {
        _ = lib.f.poll(ws);
    }

    std.debug.print("Is stopped ? ", .{});
    const stoppedBeforeClose = lib.f.stopped(ws);
    std.debug.print("{}\n", .{stoppedBeforeClose});

    std.debug.print("Closing socket ...\n", .{});
    _ = lib.f.close(ws, 1001, "Going Away");

    _ = lib.f.poll(ws); // should give onError: Invalid state

    std.debug.print("Is stopped ? ", .{});
    const stoppedAfterClose = lib.f.stopped(ws);
    std.debug.print("{}\n", .{stoppedAfterClose});

    std.debug.print("Destroying socket ...\n", .{});
    lib.f.delete(ws);
}
