const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const bufPrint = std.fmt.bufPrint;

const global = @import("../global.zig");

const mbz_rg = "https://musicbrainz.org/ws/2/release-group/?";
const caa_rg = "https://coverartarchive.org/release-group/";

var client: ?std.http.Client = null;
var aw: ?Io.Writer.Allocating = null;

pub fn deinit() void {
    if (client != null) client.?.deinit();
    if (aw != null) aw.?.deinit();
}

pub fn search(ally: Allocator, io: Io, signal_queue: *Io.Queue(bool)) void {
    var uri_buf: [1024]u8 = undefined;

    var arena_ally: std.heap.ArenaAllocator = .init(ally);
    defer arena_ally.deinit();
    const arena = arena_ally.allocator();

    if (client == null) client = .{ .allocator = ally, .io = io };
    if (aw == null) aw = .init(ally);
    std.debug.assert(client != null and aw != null);

    // Simply avoid musicbrainz rate limit
    io.sleep(.fromSeconds(1), .boot) catch return;

    aw.?.clearRetainingCapacity();
    const id_fetch = blk: {
        global.songinfo_lock(io) catch return;
        defer global.songinfo_unlock(io);

        if (global.songinfo.album == null) return;

        break :blk client.?.fetch(.{
            .method = .GET,
            .response_writer = &aw.?.writer,
            .location = .{ .uri = std.Uri.parse(bufPrint(
                &uri_buf,
                mbz_rg ++ "query={f}{f}{f}{f}&limit=1&fmt=json",
                .{
                    PercentEncoder{ .str = "release:" },
                    PercentEncoder{ .str = global.songinfo.album },
                    PercentEncoder{ .str = " AND artist:" },
                    PercentEncoder{ .str = global.songinfo.artist() },
                },
            ) catch return) catch return },
        }) catch return;
    };
    if (id_fetch.status.class() != .success) return;

    const parsed: MbzResult =
        std.json.parseFromSliceLeaky(MbzResult, arena, aw.?.written(), .{ .ignore_unknown_fields = true }) catch return;
    if (parsed.@"release-groups".len == 0) return;

    global.addMusicBrainzReleaseGroup(ally, io, parsed.@"release-groups"[0].id) catch return;
    signal_queue.putOne(io, true) catch return;
}

const PercentEncoder = struct {
    str: ?[]const u8,

    pub fn format(self: @This(), w: *Io.Writer) Io.Writer.Error!void {
        if (self.str == null) return;
        for (self.str.?) |c| {
            switch (c) {
                'a'...'z',
                'A'...'Z',
                '0'...'9',
                '-',
                '_',
                '.',
                '~',
                => |char| try w.writeByte(char),
                ' ' => try w.writeByte('+'),
                else => try w.print("%{x:0>2}", .{c}),
            }
        }
    }
};

const MbzResult = struct {
    @"release-groups": []const struct {
        id: []const u8,
    },

    pub fn deinit(self: @This(), ally: Allocator) void {
        for (self.@"release-group") |rg| {
            ally.free(rg.id);
        }
        ally.free(self.@"release-group");
    }
};
