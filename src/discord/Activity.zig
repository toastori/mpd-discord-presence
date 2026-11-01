//! Presence Activity struct
const std = @import("std");
const Writer = std.Io.Writer;

const Activity = @This();

/// What the player is currently doing
details: []const u8,
/// User's current party status, or text used for a custom status
state: []const u8,
state_line2: ?[]const u8,
/// Start and end time of activity in unix time millis
timestamps: struct { start: u64, end: u64 },
/// Activity type
activity_type: Type = .playing,
/// Controls field being displayed in user status text in member list
status_display_type: StatusDisplayType = .name,
/// Asset Large Image
large_image: ?[]const u8,

pub fn format(self: Activity, w: *Writer) Writer.Error!void {
    try w.writeByte('{');
    try w.print(\\"details":"{f}{s}"
        , .{EscapeParser{ .str = self.details }, if (self.details.len < 2) "  " else ""});
    try w.print(\\,"state":"{f}"
        , .{EscapeParser{ .str = self.state }});
    try w.print(\\,"timestamps":{{"start":{d},"end":{d}}}
        , .{self.timestamps.start, self.timestamps.end});
    try w.print(\\,"type":{d}
        , .{@backingInt(self.activity_type)});
    try w.print(\\,"status_display_type":{d}
        , .{@backingInt(self.status_display_type)});
    if (self.large_image != null or self.state_line2 != null) {
        try w.writeAll(\\,"assets":{
            );
        if (self.large_image) |large_image| try w.print(\\"large_image":"{s}"
            , .{large_image});
        if (self.large_image != null and self.state_line2 != null) try w.writeByte(',');
        if (self.state_line2) |state_line2| try w.print(\\"large_text":"{s}"
            , .{state_line2});
        try w.writeByte('}');
    }
    try w.writeByte('}');
}

const EscapeParser = struct {
    str: []const u8,

    pub fn format(self: EscapeParser, w: *Writer) Writer.Error!void {
        for (self.str) |c| {
            if (c == '"' or c == '\\')
                try w.writeByte('\\');
            try w.writeByte(c);
        }
    }
};

/// Activity type
pub const Type = enum(u8) {
    playing = 0,
    streaming = 1,
    listening = 2,
    watching = 3,
    custom = 4,
    competing = 5,
};

/// Controls field being displayed in user status text in member list
pub const StatusDisplayType = enum(u8) {
    name,
    state,
    details,
};
