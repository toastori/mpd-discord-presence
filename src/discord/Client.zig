//! The rpc client
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;

const Activity = @import("Activity.zig");
const Stream = if (builtin.os.tag == .windows) Io.File else Io.net.Stream;

const Client = @This();

/// io stream to rpc server
conn: ?Stream = null,
/// Process id
pid: std.posix.pid_t,
/// Discord Application ID
client_id: u64,
/// buffer for msg
last_msg: MsgQueueItem = .{ .msg = undefined, .len = 0 },

/// Initialize Client members and connection
pub fn new(client_id: u64) Client {
    return .{
        .pid = std.posix.getpid(),
        .client_id = client_id,
    };
}

pub const StartError =
    error{HandshakeFailed} ||
    ConnectError;
pub fn start(self: *Client, ally: Allocator, io: Io) StartError!void {
    self.conn = try connect_rpc(ally, io);
    self.handshake(io) catch return StartError.HandshakeFailed;
}

pub fn end(self: *Client, io: Io) void {
    if (self.conn != null) self.conn.?.close(io);
}

/// Queue an activity update
pub fn updateActivity(self: Client, io: Io, activity: Activity, msg_queue: *Io.Queue(MsgQueueItem)) error{NoSpaceLeft}!void {
    var msg: [4096]u8 = undefined;
    std.mem.writeInt(u32, msg[0..4], 1, .little);
    const slice = try std.fmt.bufPrint(msg[8..],
        \\{{"cmd":"SET_ACTIVITY","nonce":"{b:032}","args":{{"pid":{d},"activity":{f}}}}}
    , .{ nonce(io), self.pid, activity });
    std.mem.writeInt(u32, msg[4..8], @intCast(slice.len), .little);
    msg_queue.putOne(io, .{ .msg = msg, .len = @intCast(slice.len + 8) }) catch {};
}

/// Queue an activity clear
pub fn clearActivity(self: Client, io: Io, msg_queue: *Io.Queue(MsgQueueItem)) void {
    var msg: [4096]u8 = undefined;
    std.mem.writeInt(u32, msg[0..4], 1, .little);
    const slice = std.fmt.bufPrint(msg[8..],
        \\{{"cmd":"SET_ACTIVITY","nonce":"{b:032}","args":{{"pid":{d}}}}}
    , .{ nonce(io), self.pid }) catch unreachable;
    std.mem.writeInt(u32, msg[4..8], @intCast(slice.len), .little);
    msg_queue.putOne(io, .{ .msg = msg, .len = @intCast(slice.len + 8) }) catch {};
}

/// Message sending loop on receiving msg from queue
pub fn sender(client: *Client, io: Io, msg_queue: *Io.Queue(MsgQueueItem)) Writer.Error!void {
    std.debug.assert(client.conn != null);
    errdefer std.log.info("discord rpc disconnected", .{});

    var w_buf: [1024]u8 = undefined;
    var conn_writer = client.conn.?.writer(io, &w_buf);
    const w = &conn_writer.interface;

    // clean up pending msg
    try w.writeAll(client.last_msg.msg[0..client.last_msg.len]);
    try w.flush();

    while (true) {
        client.last_msg = msg_queue.getOne(io) catch return;
        try w.writeAll(client.last_msg.msg[0..client.last_msg.len]);
        try w.flush();
    }
}

pub fn reader(client: *Client, io: Io) Reader.Error!void {
    std.debug.assert(client.conn != null);
    errdefer std.log.info("discord rpc disconnected", .{});

    var r_buf: [1024]u8 = undefined;
    var conn_reader = client.conn.?.reader(io, &r_buf);
    const r = &conn_reader.interface;

    while (true) {
        _ = try r.takeInt(u32, .little); // opcode
        const msg_len = try r.takeInt(u32, .little);
        try r.discardAll(msg_len);
    }
}

/// Used when discord did not connect and need to discard incoming msg queue
pub fn idler(client: *Client, io: Io, msg_queue: *Io.Queue(MsgQueueItem)) void {
    while (true) {
        client.last_msg = msg_queue.getOne(io) catch return;
    }
}

pub const ConnectError =
    error{FileNotFound} ||
    Allocator.Error ||
    Io.net.UnixAddress.InitError;
/// Find the file descriptor and connect
fn connect_rpc(ally: Allocator, io: Io) ConnectError!Stream {
    if (builtin.os.tag == .windows) Stream.openAbsolute(
        \\\\.\pipe\
    ); // TODO

    // Unix
    var env = std.process.getEnvMap(ally) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic("Unexpected error"),
    };
    defer env.deinit();

    const tmp = env.get("XDG_RUNTIME_DIR") orelse
        env.get("TMPDIR") orelse
        env.get("TMP") orelse
        env.get("TEMP") orelse
        "/tmp";

    var path_buffer: [108]u8 = undefined;
    for (0..10) |i| {
        const ua = Io.net.UnixAddress.init(
            std.fmt.bufPrint(&path_buffer, "{s}/discord-ipc-{d}", .{ tmp, i }) catch
                return Io.net.UnixAddress.InitError.NameTooLong,
        ) catch unreachable;
        return ua.connect(io) catch continue;
    }
    return ConnectError.FileNotFound;
}

/// Handshake with discord ipc (right after connection)
fn handshake(self: Client, io: Io) Writer.Error!void {
    std.debug.assert(self.conn != null);
    var buf: [128]u8 = undefined;
    var conn_writer = self.conn.?.writer(io, &buf);
    const w = &conn_writer.interface;

    try w.writeInt(u32, 0, .little);
    try w.writeInt(
        u32,
        @intCast(
            \\{"v":1,"client_id":""}

            .len + (if (self.client_id == 0) 1 else (std.math.log10(self.client_id) + 1))),
        .little,
    );
    try w.print(
        \\{{"v":1,"client_id":"{d}"}}
    , .{self.client_id});
    try w.flush();
}

fn nonce(io: Io) u32 {
    const Static = struct {
        var nonce: u32 = 0;
        var mutex: Io.Mutex = .init;
    };

    Static.mutex.lock(io) catch {};
    defer Static.mutex.unlock(io);

    const result = Static.nonce;
    Static.nonce += 1;
    return result;
}

pub const MsgQueueItem = struct { msg: [4096]u8, len: u16 };
