const std = @import("std");

state: State = .stop,
song_id: u32 = std.math.maxInt(u32),
/// In millis
elapsed: u32 = 0,
/// In millis
duration: u32 = 0,

/// Assign song_changed with true when song_id changed
pub fn assign(self: *@This(), key: []const u8, value: []const u8, song_changed: *bool) void {
    if (std.mem.eql(u8, key, "state")) {
        if (self.state == .stop) song_changed.* = true;
        self.state = State.get(value) orelse {
            std.debug.panic("unexpected state \"{s}\" in status.state", .{value}); // TODO properly catch the errors
        };
    } else if (std.mem.eql(u8, key, "songid")) {
        const new_songid = std.fmt.parseInt(u32, value, 10) catch
            std.debug.panic("unexpected unparsable number \"{s}\" in status.songid", .{value}); // TODO properly catch the errors
        if (new_songid == self.song_id) song_changed.* = true;
        self.song_id = new_songid;
    } else if (std.mem.eql(u8, key, "elapsed")) {
        const colon = std.mem.findScalarPos(u8, value, 0, '.') orelse
            std.debug.panic("unexpected colon not found in status.elapsed", .{}); // TODO properly catch the errors

        const sec = std.fmt.parseInt(u32, value[0..colon], 10) catch
            std.debug.panic("unexpected unparsable number \"{s}\" in status.elapsed", .{value}); // TODO properly catch the errors
        const millis = std.fmt.parseInt(u32, value[colon + 1 ..], 10) catch
            std.debug.panic("unexpected unparsable number \"{s}\" in status.elapsed", .{value}); // TODO properly catch the errors

        self.elapsed = (sec * std.time.ms_per_s) + millis;
    } else if (std.mem.eql(u8, key, "duration")) {
        const colon = std.mem.findScalarPos(u8, value, 0, '.') orelse
            std.debug.panic("unexpected colon not found in status.duration", .{}); // TODO properly catch the errors

        const sec = std.fmt.parseInt(u32, value[0..colon], 10) catch
            std.debug.panic("unexpected unparsable number \"{s}\" in status.duration", .{value}); // TODO properly catch the errors
        const millis = std.fmt.parseInt(u32, value[colon + 1 ..], 10) catch
            std.debug.panic("unexpected unparsable number \"{s}\" in status.duration", .{value}); // TODO properly catch the errors

        self.duration = (sec * std.time.ms_per_s) + millis;
    }
}

pub const State = enum {
    play,
    stop,
    pause,

    const str_map: std.StaticStringMap(State) = .initComptime(.{
        .{ "play", .play },
        .{ "stop", .stop },
        .{ "pause", .pause },
    });

    pub fn get(str: []const u8) ?State {
        return str_map.get(str);
    }
};
