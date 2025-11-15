//! Presence Activity struct
const std = @import("std");
const Writer = std.Io.Writer;

const Activity = @This();

/// What the player is currently doing
details: []const u8,
/// User's current party status, or text used for a custom status
state: []const u8,
/// Start and end time of activity in unix time millis
timestamps: struct { start: u64, end: u64 },
/// Activity type
activity_type: Type = .playing,
/// Controls field being displayed in user status text in member list
status_display_type: StatusDisplayType = .name,
/// Asset Large Image
large_image: ?[]const u8,

pub fn format(self: Activity, w: *Writer) Writer.Error!void {
    try w.print(
        \\{{"details":"{s}{s}","state":"{s}","timestamps":{{"start":{d},"end":{d}}},"type":{d},"status_display_type":{d}{s}{s}{s}}}
    , .{
        self.details,                           if (self.details.len < 2) "  " else "",
        self.state,                             self.timestamps.start,
        self.timestamps.end,                    @intFromEnum(self.activity_type),
        @intFromEnum(self.status_display_type), if (self.large_image != null) ",\"assets\":{\"large_image\":\"" else "",
        self.large_image orelse "",             if (self.large_image != null) "\"}" else "",
    });
}

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
