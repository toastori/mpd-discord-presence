const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const SongInfo = @import("song_state/SongInfo.zig");
const PlayInfo = @import("song_state/PlayInfo.zig");

pub var playinfo: PlayInfo = .{};
var playinfo_mutex: std.Io.Mutex = .init;

pub var songinfo: SongInfo = .{ .filepath = undefined };
var songinfo_mutex: std.Io.Mutex = .init;
var str_buf: std.ArrayList(u8) = .empty;

/// Reinitialize
pub fn deinit(ally: Allocator, io: Io) void {
    songinfo_mutex.lock(io) catch {};
    defer songinfo_mutex.unlock(io);

    songinfo = .{ .filepath = undefined };
    str_buf.deinit(ally);
}

pub fn playinfo_lock(io: Io) !void {
    try playinfo_mutex.lock(io);
}
pub fn playinfo_unlock(io: Io) void {
    playinfo_mutex.unlock(io);
}

pub const UpdatePlayInfoError =
    error{ Canceled, UnexpectedResponse, ReadFailed };
/// Return true if song changes
pub fn updatePlayInfos(io: Io, r: *Io.Reader) UpdatePlayInfoError!bool {
    try playinfo_lock(io);
    defer playinfo_unlock(io);

    var song_changed: bool = false;

    while (r.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return UpdatePlayInfoError.UnexpectedResponse,
        error.ReadFailed => return UpdatePlayInfoError.ReadFailed,
    }) |line| {
        if (std.mem.startsWith(u8, line, "ACK ")) @panic(line);
        if (std.mem.startsWith(u8, line, "OK")) break;
        updatePlayInfoSingle(line, &song_changed);
    }
    return song_changed;
}

/// Take mpd output line and update PlayInfo data
fn updatePlayInfoSingle(line: []const u8, song_changed: *bool) void {
    const colon = std.mem.findScalarPos(u8, line, 0, ':') orelse
        @panic("unexpected colon not found finding PlayInfo key\n");

    playinfo.assign(line[0..colon], line[colon + 2 ..], song_changed);
}

pub fn songinfo_lock(io: Io) !void {
    try songinfo_mutex.lock(io);
}
pub fn songinfo_unlock(io: Io) void {
    songinfo_mutex.unlock(io);
}

pub const UpdateSongInfoError =
    error{ Canceled, ReadFailed } || Allocator.Error;
pub fn updateSongInfos(ally: Allocator, io: Io, r: *Io.Reader) UpdateSongInfoError!void {
    songinfo_lock(io) catch return;
    defer songinfo_unlock(io);

    // reset
    str_buf.clearRetainingCapacity();
    songinfo = .{ .filepath = undefined };

    var maybe_too_long_use: [512]u8 = undefined;

    while (r.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => blk: {
            const short = maybe_too_long_use[0..try r.readSliceShort(&maybe_too_long_use)];
            _ = try r.discardDelimiterExclusive('\n');
            break :blk short;
        },
        error.ReadFailed => return UpdateSongInfoError.ReadFailed,
    }) |line| {
        if (std.mem.startsWith(u8, line, "ACK ")) @panic(line);
        if (std.mem.startsWith(u8, line, "OK")) break;
        try updateSongInfoSingle(ally, line);
    }
}

fn updateSongInfoSingle(ally: Allocator, line: []const u8) Allocator.Error!void {
    const colon = std.mem.findScalarPos(u8, line, 0, ':') orelse
        @panic("unexpected colon not found finding SongInfo key\n");

    try songinfo.assign(ally, &str_buf, line[0..colon], line[colon + 2 ..]);
}

pub fn addMusicBrainzReleaseGroup(ally: Allocator, io: Io, id: []const u8) (Allocator.Error || Io.Cancelable)!void {
    try songinfo_lock(io);
    defer songinfo_unlock(io);

    const start = str_buf.items.len;
    try str_buf.appendSlice(ally, id);
    songinfo.musicbrainz = .{ .release_group = str_buf.items[start..] };
}
