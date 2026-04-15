const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const WriterError = Io.Writer.Error;

const parser = @import("parser.zig");
const SongInfo = @import("../song_state/SongInfo.zig");
const Metadata = SongInfo.Metadata;

const Formatter = @This();

fmt: []const Node,
str: []const u8,
eval: std.DynamicBitSetUnmanaged,
songinfo: *const SongInfo,

/// Initialize Fmt
pub fn init(allocator: Allocator, fmt: [:0]const u8, songinfo: *const SongInfo, err_w: *Io.Writer) !Formatter {
    var tok = try parser.Tokenizer.init(fmt);
    const parsed = try parser.parseTokens(allocator, &tok, err_w);
    return Formatter.initRaw(allocator, parsed.fmt, parsed.str, songinfo);
}

/// Initialize from direct resources
pub fn initRaw(allocator: Allocator, fmt: []const Node, str: []const u8, songinfo: *const SongInfo) Allocator.Error!Formatter {
    return .{
        .fmt = fmt,
        .str = str,
        .eval = try .initEmpty(allocator, fmt.len),
        .songinfo = songinfo,
    };
}

/// Deallocate resources
pub fn deinit(self: *Formatter, allocator: std.mem.Allocator) void {
    allocator.free(self.fmt);
    allocator.free(self.str);
    self.eval.deinit(allocator);
}

/// Writer print format
pub fn format(self: Formatter, w: *Io.Writer) WriterError!void {
    var idx: usize = 0;
    while (true) {
        const node = self.fmt[idx];
        node: switch (node) {
            .str => |str| {
                idx += 1;
                try w.print("{s}", .{@as([*:0]const u8, @ptrCast(self.str[str.start..].ptr))});
            },
            .tag => |tag| {
                idx += 1;
                try self.songinfo.writeMetadata(w, tag) orelse continue :node .null;
            },
            .optional => |optional| idx += if (self.eval.isSet(idx)) 1 else optional.len,
            .null => try w.writeByte('?'),
            .end_of_fmt => break,
        }
    }
}

/// Evaluate optionals
pub fn evaluate(self: *Formatter) void {
    var idx: usize = self.fmt.len - 1;
    node_loop: while (idx != std.math.maxInt(usize)) : (idx -%= 1) {
        const node = self.fmt[idx];
        switch (node) {
            .optional => |optional| {
                for (idx + 1..idx + optional.len) |i| {
                    if (self.eval.isSet(i)) {
                        self.eval.set(idx);
                        continue :node_loop;
                    }
                }
                self.eval.unset(idx);
            },
            .tag => |tag| if (self.songinfo.metadataIsNull(tag)) self.eval.set(idx) else self.eval.unset(idx),
            else => {},
        }
    }
}


pub const Node = union(enum) {
    end_of_fmt: void,
    null: void,
    tag: Metadata,
    str: struct { start: u16 },
    optional: struct { len: u16 },
};

test "title format parser" {
    const testing = std.testing;

    const allocator = testing.allocator;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.fs.File.stdout().writer(&stdout_buf);
    var stdout = &stdout_file.interface;

    var al: std.ArrayList(u8) = .empty;
    defer al.deinit(allocator);

    const fmt_texts: [4][:0]const u8 = .{
        "[[%discnumber%.]%tracknumber%. ][%artist% - ]%title%",
        "random str: '\n[]['\n''[abc][%directoryname%/]%filename% - %album% - %title%",
        "%title% / %path%, %directoryname%, %filename%, %filename_ext%",
        "", // empty
    };

    const songs: [3]SongInfo = .{
        .{
            .filepath = "root/dir1/song name.wav",
            .title = "song name",
            .album = "unknown",
            .tracknumber = 10,
            .discnumber = 1,
        },
        .{
            .filepath = "just file.wav",
            .title = "just file",
            .albumartist = "maker",
            .tracknumber = 2,
        },
        .{
            .filepath = "just file noext",
            .trackartist = "artist",
            .composer = "composter",
        },
    };

    const expected: [4][3][]const u8 = .{ .{
        "1.10. song name",
        "02. maker - just file",
        "artist - ?",
    }, .{
        "random str: []['root/dir1/song name - unknown - song name",
        "random str: []['just file - ? - just file",
        "random str: []['just file noext - ? - ?",
    }, .{
        "song name / root/dir1/song name.wav, root/dir1, song name, song name.wav",
        "just file / just file.wav, ?, just file, just file.wav",
        "? / just file noext, ?, just file noext, just file noext",
    }, .{
        "",
        "",
        "",
    } };

    for (fmt_texts, expected) |fmt_text, expects| {
        var fmt: Formatter = try .init(allocator, fmt_text, &songs[0], &stdout);
        defer fmt.deinit(allocator);

        for (songs, expects) |song, expect| {
            fmt.songinfo = &song;
            fmt.evaluate();
            try al.print(allocator, "{f}", .{fmt});
            try testing.expectEqualStrings(expect, al.items);
            al.clearRetainingCapacity();
        }
    }
}
