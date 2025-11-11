const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const discord = @import("../discord.zig");
const Formatter = @import("../formatter/Formatter.zig");

const global = @import("../global.zig");
const config = @import("../config.zig");

pub const MainError =
    error{ FormatterInitFailed, UnsupportedClock } ||
    DiscordWorkError;
pub fn main(ally: Allocator, io: Io, signal_queue: *Io.Queue(bool)) !void {
    stop(io, signal_queue);

    var client = discord.Client.new(config.get().client_id);
    var msg_queue: Io.Queue(discord.MsgQueueItem) = .init(&.{});

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

    var discord_work = try io.concurrent(discordWork, .{ ally, io, &client, &msg_queue });
    defer discord_work.cancel(io) catch {};
    var inner_work = try io.concurrent(queueingWork, .{ io, &client, &details, &state, signal_queue, &msg_queue });
    defer inner_work.cancel(io) catch {};

    switch (io.select(.{
        .discord = &discord_work,
        .inner = &inner_work,
    }) catch return) {
        .discord => |ret| return ret,
        .inner => |ret| return ret catch MainError.UnsupportedClock,
    }
}

const DiscordWorkError =
    error{ UnsupportedClock, NameTooLong } ||
    Io.ConcurrentError ||
    Allocator.Error;
fn discordWork(
    ally: Allocator,
    io: Io,
    client: *discord.Client,
    msg_queue: *Io.Queue(discord.MsgQueueItem),
) DiscordWorkError!void {
    var conn_retry_printed: bool = false;
    var idle_work: ?Io.Future(void) = null;
    defer if (idle_work != null) idle_work.?.cancel(io);

    while (true) {
        client.start(ally, io) catch |err| {
            switch (err) {
                discord.StartError.OutOfMemory => return DiscordWorkError.OutOfMemory,
                discord.StartError.NameTooLong => return DiscordWorkError.NameTooLong,
                else => {},
            }
            if (!conn_retry_printed) switch (err) {
                discord.StartError.HandshakeFailed => std.log.info("handshake with discord failed, automatic retry every 10 seconds", .{}),
                discord.StartError.FileNotFound => std.log.info("connection to discord failed, automatic reconnect every 10 seconds", .{}),
                else => unreachable,
            };
            if (idle_work != null) idle_work = try io.concurrent(discord.Client.idler, .{ client, io, msg_queue });
            conn_retry_printed = true;
            io.sleep(.fromSeconds(10), .boot) catch |err2| switch (err2) {
                error.Canceled => return,
                else => return MainError.UnsupportedClock,
            };
            continue;
        };
        defer client.end(io);
        conn_retry_printed = false;
        if (idle_work != null) idle_work.?.cancel(io);

        std.log.info("discord rpc connected", .{});

        var sender = try io.concurrent(discord.Client.sender, .{client, io, msg_queue});
        defer sender.cancel(io) catch {};
        var reader = try io.concurrent(discord.Client.reader, .{client, io});
        defer reader.cancel(io) catch {};

        switch (io.select(.{
            .sender = &sender,
            .reader = &reader,
        }) catch return) {
            .sender => |ret| if (!std.meta.isError(ret)) return,
            .reader => |ret| if (!std.meta.isError(ret)) return,
        }
        std.log.info("discord rpc disconnected", .{});
    }
}

fn queueingWork(
    io: Io,
    client: *discord.Client,
    details: *Formatter,
    state: *Formatter,
    signal_queue: *Io.Queue(bool),
    msg_queue: *Io.Queue(discord.MsgQueueItem),
) error{ UnsupportedClock, Unexpected }!void {
    while (true) {
        queueing(io, client, details, state, signal_queue, msg_queue) catch |err| switch (err) {
            QueueingError.UnsupportedClock, QueueingError.Unexpected => |e| return e,
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
fn queueing(
    io: Io,
    client: *discord.Client,
    details: *Formatter,
    state: *Formatter,
    signal_queue: *Io.Queue(bool),
    msg_queue: *Io.Queue(discord.MsgQueueItem),
) QueueingError!void {
    var details_buf: [1024]u8 = undefined;
    var state_buf: [1024]u8 = undefined;

    while (signal_queue.getOne(io) catch return) {
        const playinfo = blk: {
            global.playinfo_lock(io) catch return;
            defer global.playinfo_unlock(io);

            break :blk global.playinfo;
        };
        global.songinfo_lock(io) catch return;
        defer global.songinfo_unlock(io);

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
        };

        try client.updateActivity(io, activity, msg_queue);
    }
}

fn stop(io: Io, queue: *Io.Queue(bool)) void {
    const Handler = struct {
        var _queue: *Io.Queue(bool) = undefined;
        var _io: Io = undefined;

        const quit = if (builtin.os.tag == .windows) quit_windows else quit_posix;

        fn quit_posix(sig: std.c.SIG) callconv(.c) void {
            if (sig == .TERM)
                _queue.putOne(_io, false) catch {};
        }

        fn quit_windows(sig: u32) callconv(.c) c_int {
            const signal: std.posix.SIG = @enumFromInt(sig);
            while (signal != .TERM and signal != .BREAK) {} else {
                _queue.putOne(_io, false) catch {};
                return 0;
            }
        }
    };

    Handler._queue = queue;
    Handler._io = io;

    if (builtin.os.tag == .windows) {
        std.os.windows.SetConsoleCtrlHandler(Handler.quit, true) catch {
            std.log.err("seems like windows cannot handle signals", .{});
            std.process.exit(1);
        };
    } else {
        var handler: std.posix.Sigaction = .{
            .handler = .{ .handler = Handler.quit },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.TERM, &handler, null);
    }
}
