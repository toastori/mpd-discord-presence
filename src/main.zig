const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const global = @import("global.zig");
const config = @import("config.zig");

const mpd_main = @import("works/mpd.zig").main;
const rpc_main = @import("works/rpc.zig").main;

pub fn main() !void {
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

    try juicy_main(ally, io);
}

fn juicy_main(ally: Allocator, io: Io) !void {
    var queue: Io.Queue(bool) = .init(&.{});
    stop(io, &queue);

    var mpd_work = try io.concurrent(mpd_main, .{ ally, io, &queue });
    defer mpd_work.cancel(io) catch {};
    var rpc_work = try io.concurrent(rpc_main, .{ ally, io, &queue });
    defer rpc_work.cancel(io) catch {};

    switch (io.select(.{
        .mpd = &mpd_work,
        .rpc = &rpc_work,
    }) catch unreachable) {
        .mpd => |ret| ret catch |err| std.log.err("mpd exits with {t}", .{err}),
        .rpc => |ret| ret catch |err| std.log.err("rpc exits with {t}", .{err}),
    }
    std.log.info("exit peacefully", .{});
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
