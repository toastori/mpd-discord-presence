//! Song metadata collection
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const DIR_SEPARATOR = if (builtin.os.tag == .windows) '\\' else '/';

filepath: []const u8,
trackartist: ?[]const u8 = null,
albumartist: ?[]const u8 = null,
composer: ?[]const u8 = null,
performer: ?[]const u8 = null,
album: ?[]const u8 = null,
label: ?[]const u8 = null,
title: ?[]const u8 = null,
genre: ?[]const u8 = null,
date: ?[]const u8 = null,
tracknumber: ?u16 = null,
discnumber: ?u16 = null,
bits: ?Bits = null,
channels: ?u16 = null,
samplerate: ?u32 = null,
musicbrainz: ?MusicBrainzID = null,

pub fn artist(self: @This()) ?[]const u8 {
    return self.trackartist orelse self.albumartist orelse self.composer orelse self.performer;
}

pub fn filename(self: @This()) []const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, self.filepath, DIR_SEPARATOR)) |s| s + 1 else 0;
    const end = (std.mem.lastIndexOfScalar(u8, self.filepath[start..], '.') orelse self.filepath.len) + start;
    return self.filepath[start..end];
}

pub fn filename_ext(self: @This()) []const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, self.filepath, DIR_SEPARATOR)) |s| s + 1 else 0;
    return self.filepath[start..];
}

pub fn dirname(self: @This()) ?[]const u8 {
    const end = std.mem.lastIndexOfScalar(u8, self.filepath, DIR_SEPARATOR) orelse 0;
    return if (end == 0) null else self.filepath[0..end];
}

pub const GetMetadataResult = union(enum) {
    nullable_str: ?[]const u8,
    nullable_u16: struct { value: ?u16, width: ?usize },
    nullable_u32: struct { value: ?u32, width: ?usize },
    str: []const u8,
};
pub fn getMetadata(self: @This(), metadata: Metadata) GetMetadataResult {
    return switch (metadata) {
        // str
        .path => .{ .str = self.filepath },
        .filename => .{ .str = self.filename() },
        .filename_ext => .{ .str = self.filename_ext() },
        // nullable_str
        .artist => .{ .nullable_str = self.trackartist orelse
            self.albumartist orelse
            self.composer orelse
            self.performer },
        .@"track artist" => .{ .nullable_str = self.trackartist },
        .@"album artist" => .{ .nullable_str = self.albumartist },
        .composer => .{ .nullable_str = self.composer },
        .performer => .{ .nullable_str = self.performer },
        .album => .{ .nullable_str = self.album },
        .label => .{ .nullable_str = self.label },
        .title => .{ .nullable_str = self.title },
        .genre => .{ .nullable_str = self.genre },
        .date => .{ .nullable_str = self.date },
        .directoryname => .{ .nullable_str = self.dirname() },
        .bits => .{ .nullable_str = if (self.bits) |bits| bits.format() else null },
        .musicbrainz_releaseid,
        .musicbrainz_releasegroupid,
        => |id| .{ .nullable_str = if (self.musicbrainz) |mbz| switch (mbz) {
            .release => |str| if (id == .musicbrainz_releaseid) str else null,
            .release_group => |str| if (id == .musicbrainz_releasegroupid) str else null,
        } else null },
        // nullable_u16
        .tracknumber => .{ .nullable_u16 = .{ .value = self.tracknumber, .width = 2 } },
        .discnumber => .{ .nullable_u16 = .{ .value = self.discnumber, .width = null } },
        .channels => .{ .nullable_u16 = .{ .value = self.channels, .width = null } },
        // nullable_u32
        .samplerate => .{ .nullable_u32 = .{ .value = self.samplerate, .width = null } },
    };
}

pub fn writeMetadata(self: @This(), w: *Writer, metadata: Metadata) !?void {
    switch (self.getMetadata(metadata)) {
        .str => |str| try w.writeAll(str),
        .nullable_str => |nullable_str| try w.writeAll(nullable_str orelse return null),
        .nullable_u16 => |nullable_u16| try w.printInt(
            nullable_u16.value orelse return null,
            10,
            .lower,
            .{ .alignment = .right, .fill = '0', .width = nullable_u16.width },
        ),
        .nullable_u32 => |nullable_u32| try w.printInt(
            nullable_u32.value orelse return null,
            10,
            .lower,
            .{ .alignment = .right, .fill = '0', .width = nullable_u32.width },
        ),
    }
}

pub fn metadataIsNull(self: @This(), metadata: Metadata) bool {
    return switch (self.getMetadata(metadata)) {
        .str => true,
        .nullable_u16 => |nullable_u16| nullable_u16.value != null,
        .nullable_u32 => |nullable_u32| nullable_u32.value != null,
        .nullable_str => |nullable_str| nullable_str != null,
    };
}

pub fn assign(self: *@This(), ally: Allocator, str_buf: *std.ArrayList(u8), key: []const u8, value: []const u8) Allocator.Error!void {
    const Keys = enum { Artist, AlbumArtist, Composer, Performer, Album, Label, Title, Genre, Date, Track, Disc, Format, file, musicbrainz_albumid, musicbrainz_releasegroupid };

    const key_enum = std.meta.stringToEnum(Keys, key) orelse return;
    switch (key_enum) {
        .Format => {
            const colon1 = std.mem.findScalarPos(u8, value, 0, ':') orelse
                @panic("unexpected colon not found in songinfo.format"); // TODO properly catch the errors
            const colon2 = std.mem.lastIndexOfScalar(u8, value, ':') orelse unreachable;

            const samplerate: ?[]const u8, const bits: []const u8, const channels: []const u8 =
                if (colon1 == colon2)
                    .{ null, value[0..colon1], value[colon1 + 1 ..] }
                else
                    .{ value[0..colon1], value[colon1 + 1 .. colon2], value[colon2 + 1 ..] };

            if (value[colon1 + 1] != '*') self.bits = Bits.get(bits);
            if (value[colon2 + 1] != '*') self.channels = std.fmt.parseInt(u16, channels, 10) catch null;

            if (samplerate) |str| {
                if (value[0] != '*') {
                    self.samplerate = std.fmt.parseInt(u32, str, 10) catch null;
                    if (self.bits != null and self.bits == .dsd and self.samplerate != null)
                        self.samplerate.? *= 8; // MPD samplerate return in bytes for dsd
                }
            } else if (self.bits != null and self.bits.?.isValuedDsd()) {
                self.samplerate = self.bits.?.transformSamplerate();
            } else @panic("unexpected unparsable samplerate in songinfo.format"); // TODO properly catch the errors
        },
        .Track => self.tracknumber = std.fmt.parseInt(u16, value, 10) catch null,
        .Disc => self.discnumber = std.fmt.parseInt(u16, value, 10) catch null,
        else => {
            const start = str_buf.items.len;
            try str_buf.appendSlice(ally, value);

            switch (key_enum) {
                .file => self.filepath = str_buf.items[start..],
                .Artist => self.trackartist = str_buf.items[start..],
                .AlbumArtist => self.albumartist = str_buf.items[start..],
                .Composer => self.composer = str_buf.items[start..],
                .Performer => self.performer = str_buf.items[start..],
                .Album => self.album = str_buf.items[start..],
                .Label => self.label = str_buf.items[start..],
                .Title => self.title = str_buf.items[start..],
                .Genre => self.genre = str_buf.items[start..],
                .Date => self.date = str_buf.items[start..],
                .musicbrainz_albumid => self.musicbrainz = .{ .release = str_buf.items[start..] },
                .musicbrainz_releasegroupid => self.musicbrainz = .{ .release_group = str_buf.items[start..] },
                else => unreachable,
            }
        },
    }
}

pub const Bits = enum(u8) {
    @"8",
    @"16",
    @"24",
    @"32",
    f,
    dsd,
    dsd64 = 8,
    dsd128 = 16,
    dsd256 = 32,
    dsd512 = 64,

    pub fn format(self: Bits) []const u8 {
        return switch (self) {
            .f => "float32",
            else => @tagName(self),
        };
    }

    pub fn get(str: []const u8) ?Bits {
        return std.meta.stringToEnum(Bits, str);
    }

    pub fn isValuedDsd(self: Bits) bool {
        return switch (self) {
            .dsd64, .dsd128, .dsd256, .dsd512 => true,
            else => false,
        };
    }

    pub fn transformSamplerate(self: Bits) u32 {
        std.debug.assert(self.isValuedDsd());
        return @as(u32, @intFromEnum(self)) * 8 * 44100;
    }
};

pub const Metadata = enum {
    artist, // %artist%
    @"track artist", // %track artist%
    @"album artist", // %album artist%
    composer, // %composer%
    performer, // %performer%
    album, // %album%
    label, // %label%
    title, // %title%
    genre, // %genre%
    date, // %date%
    tracknumber, // %tracknumber%
    discnumber, // %discnumber%
    bits, // %bitdepth%
    channels, // %channels%
    samplerate, // %samplerate%
    filename, // %filename%
    filename_ext, // %filename_ext%
    directoryname, // %directoryname%
    path, // %path%
    musicbrainz_releaseid, // %musicbrainz_releaseid%
    musicbrainz_releasegroupid, // %musicbrainz_releasegroupid%

    pub fn get(str: []const u8) ?Metadata {
        return std.meta.stringToEnum(Metadata, str[1 .. str.len - 1]);
    }
};

pub const MusicBrainzID = union(enum) {
    release: []const u8,
    release_group: []const u8,
};
