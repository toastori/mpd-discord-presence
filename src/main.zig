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

pub fn main() void {
    var debug_ally = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}).init else void{};
    defer if (@TypeOf(debug_ally) == std.heap.DebugAllocator(.{}))
        if (debug_ally.deinit() == .leak) std.debug.print("debug allocator: {d} leaks found\n", .{debug_ally.detectLeaks()});
    const base_ally = if (builtin.mode == .Debug) debug_ally.allocator() else std.heap.smp_allocator;

    var threadsafe_ally = std.heap.ThreadSafeAllocator{ .child_allocator = base_ally };
    const ally = threadsafe_ally.allocator();

    var threaded = std.Io.Threaded.init(ally);
    defer threaded.deinit();
    const io = threaded.io();

    defer global.deinit(ally, io);

    config.init(ally, io) catch
        std.log.warn("unable to read/get config file, default is used instead.", .{});
    defer config.deinit(ally);

    juicy_main(ally, io) catch std.log.err("failed to spawn thread, lets wait for zig evented io :)", .{});
    std.log.info("exit peacefully", .{});
}

fn juicy_main(ally: Allocator, io: Io) Io.ConcurrentError!void {
    var signal_queue: Io.Queue(bool) = .init(&.{});
    var msg_queue: Io.Queue(discord.MsgQueueItem) = .init(&.{});

    stop(io, &signal_queue);

    var client: discord.Client = .new(config.get().client_id);

    var mpd_work = try io.concurrent(mpd_main, .{ ally, io, &signal_queue });
    defer mpd_work.cancel(io) catch {};
    var msg_queue_work = try io.concurrent(msg_queue_main, .{ ally, io, &client, &signal_queue, &msg_queue });
    defer msg_queue_work.cancel(io) catch {};

    while (true) {
        // The only one spawn to works from one connection, so handle it here
        var rpc_works = rpc_main(ally, io, &client, &msg_queue) catch |err| switch (err) {
            Io.ConcurrentError.ConcurrencyUnavailable => |e| return e,
            else => |e| return std.log.err("mpd exits with error {t}", .{e}),
        };
        defer client.end(io); // defer .end here because client .start in rpc_main
        defer rpc_works.sender.cancel(io) catch {};
        defer rpc_works.reader.cancel(io) catch {};

        switch (io.select(.{
            .rpc_sender = &rpc_works.sender,
            .rpc_reader = &rpc_works.reader,
            .mpd = &mpd_work,
            .msg_queue = &msg_queue_work,
        }) catch unreachable) {
            .rpc_sender => |ret| ret catch continue, // the reason to handle them here is they fail softly
            .rpc_reader => |ret| ret catch continue, // the reason to handle them here is they fail softly
            // Following 2 fail hardly
            .mpd => |ret| return ret catch |err| std.log.err("mpd exits with error {t}", .{err}),
            .msg_queue => |ret| return ret catch |err| std.log.err("msg_queue exits with error {t}", .{err}),
        }
    }
}

/// Handles Terminate Signal
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

test {
    _ = @import("formatter/Formatter.zig");
    _ = @import("formatter/parser.zig");
}
