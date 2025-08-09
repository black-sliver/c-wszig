//! Sameple usage of c-wspp DLL/so

const builtin = @import("builtin");
const std = @import("std");
const CallingConvention = std.builtin.CallingConvention;
const DynLib = std.DynLib;
const fs = std.fs;
const mem = std.mem;
const meta = std.meta;
const time = std.time;
const Thread = std.Thread;

// const conv = if (builtin.target.os.tag == .windows) CallingConvention.winapi else CallingConvention.c;
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

const State = enum {
    None,
    Open,
    RoomConnected,
    SlotConnecting,
    SlotConnected,
    Pinging,
    GotPong,
    Closed,
    Error,
};

var state: State = .None;
const ping_msg = "test";

fn onOpen() callconv(conv) void {
    std.debug.print("onOpen\n", .{});
    state = .Open;
}

fn onClose() callconv(conv) void {
    std.debug.print("onClose\n", .{});
    state = .Closed;
}

fn onMessage(data: CStr, len: u64, op_code: i32) callconv(conv) void {
    const dataPtr: [*]const u8 = @ptrCast(data);
    const slice = dataPtr[0..@intCast(len)];
    std.debug.print("onMessage ({}): {s}\n", .{ op_code, slice });
    if (state == .Open) {
        state = .RoomConnected;
    }
    if (state == .SlotConnected) {
        state = .SlotConnected;
    }
}

fn onError(msg: CStr) callconv(conv) void {
    std.debug.print("onError: {s}\n", .{msg});
    state = .Error;
}

fn onPong(data: CStr, len: u64) callconv(conv) void {
    const data_ptr: [*]const u8 = @ptrCast(data);
    const slice = data_ptr[0..@intCast(len)];
    std.debug.print("onPong: {s}\n", .{slice});
    if (state == .Pinging) {
        if (mem.eql(u8, ping_msg, slice)) {
            state = .GotPong;
        } else {
            std.debug.print("  expected {s} but got {s}\n", .{ ping_msg, slice });
        }
    }
}

pub fn main() !void {
    const relative_dll_name = switch (builtin.target.os.tag) {
        .linux => "../lib/libc-wspp.so",
        .macos => "../lib/libc-wspp.dylib",
        .windows => "..\\bin\\c-wspp.dll",
        else => @panic("unsupported platform"),
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit(); // enable this to find memory leaks, disable this to reduce noise

    const exe_dir = fs.selfExeDirPathAlloc(allocator) catch |err| switch (err) {
        // if exeDir fails Unexpected, we assume testing in wine, which uses unsupported UNC paths
        error.Unexpected => if (builtin.target.os.tag == .windows) try allocator.dupe(u8, ".\\zig-out\\bin") else {
            return err;
        },
        else => return err,
    };
    defer allocator.free(exe_dir);
    var dll_path_parts = [_][]const u8{ exe_dir, relative_dll_name };
    const dll_path = try fs.path.join(allocator, &dll_path_parts);

    defer allocator.free(dll_path);

    std.debug.print("Loading DLL {s}\n", .{dll_path});
    var lib = try Lib.init(dll_path);
    defer lib.deinit();

    var server, var thread = try runTestServer(allocator, 38281);
    defer {
        time.sleep(1 * time.ns_per_ms); // wait for client connection to be dead
        server.stop();
        thread.join();
        server.deinit();
    }
    time.sleep(1 * time.ns_per_ms);

    std.debug.print("Creating socket ...\n", .{});
    const ws = lib.f.new("ws://localhost:38281");
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
    if (connectErr != .OK) {
        return error.CouldNotConnect;
    }

    for (0..100) |_| {
        _ = lib.f.poll(ws);
        if (state == .Error) {
            return error.Error;
        }
        if (state == .RoomConnected) {
            break;
        }
        time.sleep(1 * time.ns_per_ms);
    }

    if (state != .RoomConnected) {
        return error.DidNotReceiveRoomInfo;
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
    if (sendErr != .OK) {
        return error.CouldNotSend;
    }

    for (0..100) |_| {
        _ = lib.f.poll(ws);
        if (state == .Error) {
            return error.Error;
        }
        if (state == .SlotConnected) {
            break;
        }
        time.sleep(1 * time.ns_per_ms);
    }

    _ = lib.f.ping(ws, ping_msg, ping_msg.len);
    state = .Pinging;

    for (0..100) |_| {
        _ = lib.f.poll(ws);
        if (state == .Error) {
            return error.Error;
        }
        if (state == .GotPong) {
            break;
        }
        // TODO: break condition
        time.sleep(1 * time.ns_per_ms);
    }
    if (state != .GotPong) {
        return error.DidNotReceivePong;
    }

    std.debug.print("Is stopped? ", .{});
    const stoppedBeforeClose = lib.f.stopped(ws);
    std.debug.print("{}\n", .{stoppedBeforeClose});
    if (stoppedBeforeClose != 0) {
        return error.StoppedAfterClose;
    }

    std.debug.print("Closing socket ...\n", .{});
    _ = lib.f.close(ws, 1001, "Going Away");

    for (0..100) |_| {
        _ = lib.f.poll(ws);
        if (state == .Closed or state == .Error) {
            break; // onError: Invalid state is fine here
        }
        time.sleep(1 * time.ns_per_ms);
    }

    std.debug.print("Is stopped? ", .{});
    const stoppedAfterClose = lib.f.stopped(ws);
    std.debug.print("{}\n", .{stoppedAfterClose});
    if (stoppedAfterClose == 0) {
        return error.NotStoppedAfterClose;
    }

    std.debug.print("Destroying socket ...\n", .{});
    lib.f.delete(ws);
}

const websocket = @import("websocket");

const TestServer = websocket.Server(TestServerHandler);

fn runTestServer(allocator: mem.Allocator, port: u16) !struct { TestServer, Thread } {
    var server = try TestServer.init(allocator, .{
        .port = port,
        .address = "127.0.0.1",
        .worker_count = 1,
        .handshake = .{
            .max_headers = 0,
        },
    });
    const thread = try server.listenInNewThread(&{});
    return .{ server, thread };
}

const TestServerHandler = struct {
    app: *const void,
    conn: *websocket.Conn,

    pub fn init(h: *websocket.Handshake, conn: *websocket.Conn, app: *const void) !TestServerHandler {
        _ = h; // we're not using this in our simple case

        return .{
            .app = app,
            .conn = conn,
        };
    }

    pub fn afterInit(self: *TestServerHandler) !void {
        try self.conn.write(
            \\[{
            \\  "cmd": "RoomInfo",
            \\  "password": false,
            \\  "games": ["Archipelago"],
            \\  "tags": [],
            \\  "version": {"major": 0, "minor": 6, "build": 3, "class": "Version"},
            \\  "generator_version": {"major": 0, "minor": 6, "build": 3, class "Version"},
            \\  "permission": {},
            \\  "hinst_cost": 100,
            \\  "location_check_points": 1,
            \\  "datapackage_checksums": {"Archipelago", "ac9141e9ad0318df2fa27da5f20c50a842afeecb"},
            \\  "seed_name": "1234",
            \\  "time": 1754753385.6945775
            \\}]
        );
    }

    pub fn clientMessage(self: *TestServerHandler, data: []const u8) !void {
        // for testing we simply assume it was a ConnectSlot and we return Connected
        _ = data;
        try self.conn.write(
            \\[{
            \\  "cmd": "Connected",
            \\  "team": 0,
            \\  "slot": 1,
            \\  "players": [],
            \\  "missing_locations": [],
            \\  "checked_locations": [],
            \\  "slot_data": {},
            \\  "slot_info": {}.
            \\  "hint_points": 0
            \\}]
        );
    }
};
