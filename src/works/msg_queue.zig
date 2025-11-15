const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const discord = @import("../discord.zig");
const Formatter = @import("../formatter/Formatter.zig");

const global = @import("../global.zig");
const config = @import("../config.zig");

const albumart_search = @import("albumart.zig").search;

pub const MainError =
    error { UnsupportedClock, FormatterInitFailed } ||
    Allocator.Error;
pub fn main(
    ally: Allocator,
    io: Io,
    client: *discord.Client,
    signal_queue: *Io.Queue(bool),
    msg_queue: *Io.Queue(discord.MsgQueueItem),
) MainError!void {
    var details: Formatter, var state: Formatter = blk: {
        var stderr_buf: [512]u8 = undefined;
        var stderr = std.fs.File.stderr().writer(&stderr_buf);

        var first = Formatter.init(ally, config.get().details, &global.songinfo, &stderr.interface) catch |err| switch (err) {
            error.BufTooLong, error.ParseError => null,
            error.OutOfMemory => return MainError.OutOfMemory,
        };
        errdefer if (first != null) first.?.deinit(ally);
        var second = Formatter.init(ally, config.get().state, &global.songinfo, &stderr.interface) catch |err| switch (err) {
            error.BufTooLong, error.ParseError => null,
            error.OutOfMemory => return MainError.OutOfMemory,
        };
        errdefer if (second != null) second.?.deinit(ally);

        stderr.interface.flush() catch {};
        if (first == null or second == null) return MainError.FormatterInitFailed;
        break :blk .{ first.?, second.? };
    };
    defer details.deinit(ally);
    defer state.deinit(ally);

    while (true) {
        inner(ally, io, client, &details, &state, signal_queue, msg_queue) catch |err| switch (err) {
            QueueingError.UnsupportedClock, QueueingError.Unexpected => return MainError.UnsupportedClock,
            QueueingError.NoSpaceLeft => {
                std.log.warn("activity too long to write, skipped", .{});
                continue;
            },
        };
        return; // no error, is peaceful return
    }
}

const QueueingError =
error{ UnsupportedClock, Unexpected } ||
    std.fmt.BufPrintError;
fn inner(
    ally: Allocator,
    io: Io,
    client: *discord.Client,
    details: *Formatter,
    state: *Formatter,
    signal_queue: *Io.Queue(bool),
    msg_queue: *Io.Queue(discord.MsgQueueItem),
) QueueingError!void {
    var details_buf: [1024]u8 = undefined;
    var state_buf: [1024]u8 = undefined;
    var large_img_buf: [512]u8 = undefined;

    var albumart_work: ?Io.Future(void) = null;
    defer if (albumart_work) |*work| work.cancel(io);
    var albumart_searching_id: ?u32 = null;

    while (signal_queue.getOne(io) catch return) {
        const playinfo = blk: {
            global.playinfo_lock(io) catch return;
            defer global.playinfo_unlock(io);

            break :blk global.playinfo;
        };
        global.songinfo_lock(io) catch return;
        defer global.songinfo_unlock(io);

        if (albumart_work) |*work| {
            std.debug.assert(albumart_searching_id != null);
            if (albumart_searching_id.? != playinfo.song_id) {
                work.cancel(io);
                albumart_work = null;
                albumart_searching_id = null;
            }
        }

        if (playinfo.state == .stop) {
            client.clearActivity(io, msg_queue);
            continue;
        }

        const now = try std.posix.clock_gettime(.REALTIME);
        const start: u64 = @intCast(now.sec * std.time.ms_per_s - playinfo.elapsed);
        const end: u64 = start + playinfo.duration;

        details.evaluate();
        const details_str = try std.fmt.bufPrint(&details_buf, "{f}", .{details});
        state.evaluate();
        const state_str = try std.fmt.bufPrint(&state_buf, "{f}", .{state});

        const activity: discord.Activity = .{
            .details = details_str,
            .state = state_str,
            .activity_type = .listening,
            .status_display_type = .state,
            .timestamps = .{ .start = start, .end = end },
            .large_image = if (global.songinfo.musicbrainz) |mbz| switch (mbz) {
                .release => |id| std.fmt.bufPrint(&large_img_buf, "https://coverartarchive.org/release/{s}/front", .{id}) catch unreachable,
                .release_group => |id| std.fmt.bufPrint(&large_img_buf, "https://coverartarchive.org/release-group/{s}/front", .{id}) catch unreachable,
            } else null,
        };

        if (activity.large_image == null and albumart_work == null) {
            albumart_work = io.concurrent(albumart_search, .{ally, io, signal_queue}) catch null;
            albumart_searching_id = playinfo.song_id;
        }

        try client.updateActivity(io, activity, msg_queue);

    }
}