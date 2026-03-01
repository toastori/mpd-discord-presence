const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const global = @import("global.zig");
const config = @import("config.zig");

const discord = @import("discord.zig");

const mpd_main = @import("works/mpd.zig").main;
const msg_queue_main = @import("works/msg_queue.zig").main;
const rpc_main = @import("works/rpc.zig").main;

const albumart_deinit = @import("works/albumart.zig").deinit;

pub fn main(init: std.process.Init) void {
    const ally = init.gpa;
    const io = init.io;

    // Global
    defer global.deinit(ally, io);

    // Config
    config.init(ally, io, init.environ_map) catch
        std.log.warn("unable to read/get config file, default is used instead.", .{});
    defer config.deinit(ally);

    // Actual code start here
    innerMain(ally, io, init.environ_map) catch |err| {
        if (err == JuicyError.ConcurrencyUnavailable)
            std.log.err("failed to spawn thread, lets wait for zig evented io :)", .{});
        std.process.exit(1);
    };
    std.log.info("exit peacefully", .{});
}

pub const MainSelectResult = union(enum) {
    mpd: @typeInfo(@TypeOf(mpd_main)).@"fn".return_type.?,
    msg_queue: @typeInfo(@TypeOf(msg_queue_main)).@"fn".return_type.?,
    rpc_sender: @typeInfo(@TypeOf(discord.Client.sender)).@"fn".return_type.?,
};

const JuicyError = error{OtherError} || Io.ConcurrentError;
fn innerMain(ally: Allocator, io: Io, envmap: *std.process.Environ.Map) JuicyError!void {
    var signal_queue: Io.Queue(bool) = .init(&.{});
    var msg_queue: Io.Queue(discord.MsgQueueItem) = .init(&.{});

    var select_buf: [4]MainSelectResult = undefined;
    var select: Io.Select(MainSelectResult) = .init(io, &select_buf);
    defer select.cancel();

    if (builtin.mode == .Debug) stop(io, &signal_queue);

    var client: discord.Client = .new(config.get().client_id);

    try select.concurrent(.mpd, mpd_main, .{ ally, io, &signal_queue });
    try select.concurrent(.msg_queue, msg_queue_main, .{ ally, io, &client, &signal_queue, &msg_queue });

    while (true) {
        // The only one spawn to works from one connection, so handle it here
        rpc_main(io, &select, envmap, &client, &msg_queue) catch |err| switch (err) {
            Io.ConcurrentError.ConcurrencyUnavailable => |e| return e,
            else => |e| {
                std.log.err("mpd exits with error {t}", .{e});
                return JuicyError.OtherError;
            },
        };
        defer client.end(io); // defer .end here because client .start in rpc_main

        switch (select.await() catch unreachable) {
            .rpc_sender => |ret| ret catch continue, // the reason to handle them here is they fail softly
            // Following 2 fail hardly
            .mpd => |ret| return ret catch |err| {
                std.log.err("mpd exits with error {t}", .{err});
                return JuicyError.OtherError;
            },
            .msg_queue => |ret| return ret catch |err| {
                std.log.err("msg_queue exits with error {t}", .{err});
                return JuicyError.OtherError;
            },
        }
    }
}

/// Handles Terminate Signal
fn stop(io: Io, queue: *Io.Queue(bool)) void {
    const Handler = struct {
        var _queue: *Io.Queue(bool) = undefined;
        var _io: Io = undefined;

        const quit = if (builtin.os.tag == .windows) quitWindows else quitPosix;

        fn quitPosix(sig: std.c.SIG) callconv(.c) void {
            if (sig == .TERM)
                _queue.putOne(_io, false) catch {};
        }

        fn quitWindows(sig: u32) callconv(.c) c_int {
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
        // std.os.windows.SetConsoleCtrlHandler(Handler.quit, true) catch {
        //     std.log.err("seems like windows cannot handle signals", .{});
        //     std.process.exit(1);
        // };
    } else {
        var handler: std.posix.Sigaction = .{
            .handler = .{ .handler = Handler.quit },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.TERM, &handler, null);
    }
}

test {
    _ = @import("formatter/Formatter.zig");
    _ = @import("formatter/parser.zig");
}
