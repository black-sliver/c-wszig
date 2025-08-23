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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit(); // enable this to find memory leaks, disable this to reduce noise

    const relative_dll_name = switch (builtin.target.os.tag) {
        .linux => "../lib/libc-wspp.so",
        .macos => "../lib/libc-wspp.dylib",
        .windows => "..\\bin\\c-wspp.dll",
        else => @panic("unsupported platform"),
    };

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

    try mtPingTest(allocator, lib);
    try syncAPSample(allocator, lib);

    if (builtin.target.os.tag == .windows) { //and server != null)
        // server worker thread may not stop -> just exit
        std.process.exit(0);
    }
}

var state: State = .None;
var pongs_received: [128]u8 = undefined;
const pt_timeout = 500 * time.ns_per_ms;

fn onPTOpen() callconv(conv) void {
    std.debug.print("onOpen\n", .{});
    state = .Open;
}

fn onPTClose() callconv(conv) void {
    std.debug.print("onClose\n", .{});
    state = .Closed;
}

fn onPTMessage(data: CStr, len: u64, op_code: i32) callconv(conv) void {
    _ = data;
    _ = len;
    _ = op_code;
}

fn onPTError(msg: CStr) callconv(conv) void {
    std.debug.print("onError: {s}\n", .{msg});
    state = .Error;
}

fn onPTPong(data: CStr, len: u64) callconv(conv) void {
    const data_ptr: [*]const u8 = @ptrCast(data);
    const slice = data_ptr[0..@intCast(len)];
    std.debug.assert(len == 1);
    pongs_received[slice[0] % pongs_received.len] += 1;
}

fn ptPing(lib: *const Lib, ws: ?*WS, i: u8) void {
    var data = [_]u8{i};
    Thread.sleep(1 * time.ns_per_ms);
    _ = lib.f.ping(ws, &data, data.len);
    data[0] += pongs_received.len / 2;
    _ = lib.f.ping(ws, &data, data.len);
}

fn ptPoll(lib: *const Lib, ws: ?*WS, timeout: u64) !void {
    var timer = try time.Timer.start();
    while (timer.read() < timeout) {
        _ = lib.f.poll(ws);
        if (lib.f.stopped(ws) != 0) {
            break;
        }
    }
    if (lib.f.stopped(ws) == 0) {
        std.debug.print("timeout\n", .{});
        return error.Timeout;
    }
}

fn mtPingTest(allocator: mem.Allocator, lib: Lib) !void {
    @memset(&pongs_received, 0);
    state = .None;

    var server: ?TestServer = null;
    var server_thread: ?Thread = null;
    server, server_thread = try runTestServer(allocator, 12345);
    defer if (server != null) {
        Thread.sleep(1 * time.ns_per_ms); // wait for client connection to be dead
        if (builtin.target.os.tag != .windows) { // see end of main()
            std.debug.print("Stopping server ...\n", .{});
            server.?.stop();
            server_thread.?.join();
            server.?.deinit();
        }
    };
    Thread.sleep(1 * time.ns_per_ms);

    std.debug.print("Creating socket ...\n", .{});
    const ws = lib.f.new("ws://localhost:12345");
    if (ws == null) {
        return error.CouldNotCreateSocket;
    }
    errdefer lib.f.delete(ws);

    lib.f.setOpenHandler(ws, onPTOpen);
    lib.f.setCloseHandler(ws, onPTClose);
    lib.f.setMessageHandler(ws, onPTMessage);
    lib.f.setErrorHandler(ws, onPTError);
    lib.f.setPongHandler(ws, onPTPong);

    std.debug.print("Opening socket ... ", .{});
    const connectErr = lib.f.connect(ws);
    std.debug.print("{}\n", .{connectErr});
    if (connectErr != .OK) {
        return error.CouldNotConnect;
    }
    errdefer _ = lib.f.close(ws, 1001, "Going Away");

    var timer = try time.Timer.start();

    std.debug.print("Starting poll thread ...\n", .{});
    var poll_thread = try Thread.spawn(.{}, ptPoll, .{ &lib, ws, pt_timeout });
    errdefer poll_thread.join();

    std.debug.print("Starting ping threads ...\n", .{});
    var ping_threads: [64]Thread = undefined;
    for (0..ping_threads.len) |i| {
        ping_threads[i] = try Thread.spawn(.{}, ptPing, .{ &lib, ws, @as(u8, @intCast(i)) });
    }
    defer {
        for (0..ping_threads.len) |i| {
            ping_threads[i].join();
        }
    }

    wait_result: while (true) {
        if (timer.read() > pt_timeout) {
            return error.Timeout;
        }
        Thread.sleep(1 * time.ns_per_ms);
        for (0..pongs_received.len) |i| {
            if (pongs_received[i] > 1) {
                return error.InvalidPongReceived;
            }
            if (pongs_received[i] == 0) {
                continue :wait_result;
            }
        }
        break; // done
    }

    const elapsed = timer.read();
    std.debug.print("Done in {d:.3} ms\n", .{@as(f32, @floatFromInt(elapsed)) / time.ns_per_ms});

    std.debug.print("Closing socket ...\n", .{});
    _ = lib.f.close(ws, 1001, "Going Away");
    poll_thread.join();
    std.debug.print("Destroying socket ...\n", .{});
    _ = lib.f.delete(ws);
    std.debug.print("Socket destroyed.\n", .{});
}

const ping_msg = "test";

fn onAPOpen() callconv(conv) void {
    std.debug.print("onOpen\n", .{});
    state = .Open;
}

fn onAPClose() callconv(conv) void {
    std.debug.print("onClose\n", .{});
    state = .Closed;
}

fn onAPMessage(data: CStr, len: u64, op_code: i32) callconv(conv) void {
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

fn onAPError(msg: CStr) callconv(conv) void {
    std.debug.print("onError: {s}\n", .{msg});
    state = .Error;
}

fn onAPPong(data: CStr, len: u64) callconv(conv) void {
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

fn syncAPSample(allocator: mem.Allocator, lib: Lib) !void {
    state = .None;

    var server: ?TestServer = null;
    var server_thread: ?Thread = null;
    server, server_thread = try runTestServer(allocator, 38281);
    defer if (server != null) {
        Thread.sleep(1 * time.ns_per_ms); // wait for client connection to be dead
        if (builtin.target.os.tag != .windows) { // see end of main()
            std.debug.print("Stopping server ...\n", .{});
            server.?.stop();
            server_thread.?.join();
            server.?.deinit();
        }
    };
    Thread.sleep(1 * time.ns_per_ms);

    std.debug.print("Creating socket ...\n", .{});
    const ws = lib.f.new("ws://localhost:38281");
    if (ws == null) {
        return error.CouldNotCreateSocket;
    }
    errdefer lib.f.delete(ws);

    lib.f.setOpenHandler(ws, onAPOpen);
    lib.f.setCloseHandler(ws, onAPClose);
    lib.f.setMessageHandler(ws, onAPMessage);
    lib.f.setErrorHandler(ws, onAPError);
    lib.f.setPongHandler(ws, onAPPong);

    std.debug.print("Opening socket ... ", .{});
    const connectErr = lib.f.connect(ws);
    std.debug.print("{}\n", .{connectErr});
    if (connectErr != .OK) {
        return error.CouldNotConnect;
    }
    errdefer _ = lib.f.close(ws, 1001, "Going Away");

    for (0..100) |_| {
        _ = lib.f.poll(ws);
        if (state == .Error) {
            return error.Error;
        }
        if (state == .RoomConnected) {
            break;
        }
        Thread.sleep(1 * time.ns_per_ms);
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
        Thread.sleep(1 * time.ns_per_ms);
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
        Thread.sleep(1 * time.ns_per_ms);
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
        Thread.sleep(1 * time.ns_per_ms);
    }

    std.debug.print("Is stopped? ", .{});
    const stoppedAfterClose = lib.f.stopped(ws);
    std.debug.print("{}\n", .{stoppedAfterClose});
    if (stoppedAfterClose == 0) {
        return error.NotStoppedAfterClose;
    }

    std.debug.print("Destroying socket ...\n", .{});
    lib.f.delete(ws);
    std.debug.print("Socket destroyed.\n", .{});
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
