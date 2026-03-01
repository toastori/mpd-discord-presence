const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const MainSelectResult = @import("../main.zig").MainSelectResult;

const discord = @import("../discord.zig");

const global = @import("../global.zig");
const config = @import("../config.zig");

const MainError =
    error{ UnsupportedClock, NameTooLong } ||
    Io.ConcurrentError ||
    Allocator.Error;
const MainResult = struct {
    sender: Io.Future(Io.Writer.Error!void),
    reader: Io.Future(Io.Reader.Error!void),
};
pub fn main(
    io: Io,
    select: *Io.Select(MainSelectResult),
    envmap: *std.process.Environ.Map,
    client: *discord.Client,
    msg_queue: *Io.Queue(discord.MsgQueueItem),
) MainError!void {
    var idle_work: ?Io.Future(void) = null;
    defer if (idle_work != null) idle_work.?.cancel(io);

    while (true) {
        client.start(io, envmap) catch |err| {
            switch (err) {
                discord.StartError.OutOfMemory => return MainError.OutOfMemory,
                discord.StartError.NameTooLong => return MainError.NameTooLong,
                else => {},
            }
            if (idle_work == null) switch (err) {
                discord.StartError.HandshakeFailed => std.log.info("handshake with discord failed, automatic retry every 10 seconds", .{}),
                discord.StartError.FileNotFound => std.log.info("connection to discord failed, automatic reconnect every 10 seconds", .{}),
                else => unreachable,
            };
            if (idle_work == null) idle_work = try io.concurrent(discord.Client.idler, .{ client, io, msg_queue });
            io.sleep(.fromSeconds(10), .boot) catch |err2| switch (err2) {
                error.Canceled => return undefined,
                // else => return MainError.UnsupportedClock,
            };
            continue;
        };
        if (idle_work != null) {
            idle_work.?.cancel(io);
            idle_work = null;
        }
        break;
    }
    errdefer client.end(io);

    std.log.info("discord rpc connected", .{});

    try select.concurrent(.rpc_sender, discord.Client.sender, .{ client, io, msg_queue });
}
