const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Stream = Io.net.Stream;

const global = @import("../global.zig");
const config = @import("../config.zig");

pub const MainError = error { UnexpectedResponse, UnsupportedClock } || Allocator.Error;
pub fn main(ally: Allocator, io: Io, queue: *Io.Queue(bool)) MainError!void {
    var conn_retry_printed: bool = false;

    const socket = Io.net.UnixAddress.init(config.get().mpd_addr) catch
        @panic("mpd address too long");
    while (true) {
        const stream = socket.connect(io) catch |err| {
            if (!conn_retry_printed)
                std.log.info("connection to mpd failed: {t}, automatic reconnect every 10 seconds", .{err});
            conn_retry_printed = true;
            io.sleep(.fromSeconds(10), .boot) catch |err2| switch (err2) {
                error.Canceled => return,
                else => return MainError.UnsupportedClock,
            };
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

        inner(ally, io, r, w, queue) catch |err| switch (err) {
                InnerError.OutOfMemory => return InnerError.OutOfMemory,
                InnerError.UnexpectedResponse => return InnerError.UnexpectedResponse,
                InnerError.ReadFailed, InnerError.WriteFailed => {
                    std.log.info("mpd disconnected", .{});
                    continue;
                },
        };
        return; // not error, is peaceful return
    }
}

const InnerError =
    error { ReadFailed, WriteFailed, UnexpectedResponse } ||
    Allocator.Error;
fn inner(ally: Allocator, io: Io, r: *Io.Reader, w: *Io.Writer, queue: *Io.Queue(bool)) InnerError!void {
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

        queue.putOne(io, true) catch return; // signify PlayInfo and SongInfo is ready, rpc should update

        try w.writeAll("idle player\n");
        try w.flush();

        while (r.takeDelimiter('\n') catch return InnerError.UnexpectedResponse) |line| {
            if (std.mem.startsWith(u8, line, "OK")) break;
            if (!std.mem.eql(u8, line, "changed: player")) return InnerError.UnexpectedResponse;
        }
    }
}
