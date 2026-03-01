const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Stream = Io.net.Stream;

const global = @import("../global.zig");
const config = @import("../config.zig");

pub const MainError = error{ UnexpectedResponse, InvalidMpdAddr } || Allocator.Error;
pub fn main(ally: Allocator, io: Io, queue: *Io.Queue(bool)) MainError!void {
    var conn_retry_printed: bool = false;

    const addr = try classifyAddr(config.get().mpd_addr);

    while (true) {
        const stream = connectAddr(addr, io) catch |err| {
            if (!conn_retry_printed)
                std.log.info("connection to mpd failed: {t}, automatic reconnect every 10 seconds", .{err});
            conn_retry_printed = true;
            io.sleep(.fromSeconds(10), .boot) catch return;
            continue;
        };
        defer stream.close(io);
        conn_retry_printed = false;

        var reader_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &reader_buf);
        var writer = stream.writer(io, &.{});
        const r = &reader.interface;
        const w = &writer.interface;

        if (r.takeDelimiter('\n') catch return MainError.UnexpectedResponse) |line| {
            if (!std.mem.startsWith(u8, line, "OK MPD"))
                return MainError.UnexpectedResponse;
        }

        std.log.info("mpd connected", .{});

        innerMain(ally, io, r, w, queue) catch |err| switch (err) {
            InnerError.OutOfMemory => return InnerError.OutOfMemory,
            InnerError.UnexpectedResponse => return InnerError.UnexpectedResponse,
            InnerError.ReadFailed, InnerError.WriteFailed => {
                std.log.info("mpd disconnected", .{});
                global.reset(io); // so next connection can do everything correctly
                continue;
            },
        };
        return; // not error, is peaceful return
    }
}

const InnerError =
    error{ ReadFailed, WriteFailed, UnexpectedResponse } ||
    Allocator.Error;
fn innerMain(ally: Allocator, io: Io, r: *Io.Reader, w: *Io.Writer, queue: *Io.Queue(bool)) InnerError!void {
    while (true) {
        // PlayInfo / Status
        try w.writeAll("status\n");
        try w.flush();
        const song_changed = global.updatePlayInfos(io, r) catch |err| switch (err) {
            error.Canceled => return,
            else => |e| return e,
        };

        // SongInfo / CurrentSong
        if (song_changed) {
            try w.writeAll("currentsong\n");
            try w.flush();
            global.updateSongInfos(ally, io, r) catch |err| switch (err) {
                error.Canceled => return,
                else => |e| return e,
            };
        }

        queue.putOne(io, true) catch return; // signify PlayInfo and SongInfo is ready, msg_queue should update

        try w.writeAll("idle player\n");
        try w.flush();

        while (r.takeDelimiter('\n') catch return InnerError.UnexpectedResponse) |line| {
            if (std.mem.startsWith(u8, line, "OK")) break;
            if (!std.mem.eql(u8, line, "changed: player")) return InnerError.UnexpectedResponse;
        }
    }
}

fn classifyAddr(addr: []const u8) !Address {
    if (addr.len == 0) return MainError.InvalidMpdAddr;
    if (addr[0] == '/') return .{
        .unix_socket = Io.net.UnixAddress.init(addr) catch return MainError.InvalidMpdAddr,
    };

    const colon = std.mem.findScalarLast(u8, addr, ':');
    const location = addr[0 .. colon orelse addr.len];
    const port: u16 = if (colon) |c|
        std.fmt.parseInt(u16, addr[c + 1 ..], 10) catch return MainError.InvalidMpdAddr
    else
        6600;

    const ip = Io.net.IpAddress.parse(location, port);

    return if (ip) |ip_address| .{
        .ip_address = ip_address,
    } else |_| .{
        .hostname = .{
            .hostname = Io.net.HostName.init(location) catch return MainError.InvalidMpdAddr,
            .port = port,
        },
    };
}

fn connectAddr(addr: Address, io: Io) !Stream {
    return switch (addr) {
        .unix_socket => |a| a.connect(io),
        .ip_address => |a| a.connect(io, .{ .mode = .stream }),
        .hostname => |a| a.hostname.connect(io, a.port, .{ .mode = .stream }),
    };
}

const Address = union(enum) {
    unix_socket: Io.net.UnixAddress,
    ip_address: Io.net.IpAddress,
    hostname: struct { hostname: Io.net.HostName, port: u16 },
};
