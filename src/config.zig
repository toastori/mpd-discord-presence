const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zon = std.zon;

const StausDisplayType = @import("discord/Activity.zig").StatusDisplayType;

var config: Config = .default;
var zon_parsed: bool = false;

const Config = struct {
    mpd_addr: []const u8,
    client_id: u64 = 1435159974421725214,
    details: [:0]const u8,
    state: [:0]const u8,
    discord_display_type: StausDisplayType,

    pub const default: Config = @import("default_config.zon");
};

pub fn init(ally: Allocator, io: Io) !void {
    var read_buf: [4096:0]u8 = undefined;

    const config_file = try readConfigFile(ally, io, &read_buf);
    const config_file_z: [:0]const u8 = if (config_file.len == 4096) &read_buf else blk: {
        std.debug.assert(config_file.len < 4096);
        read_buf[config_file.len] = 0;
        break :blk @ptrCast(read_buf[0..config_file.len]);
    };

    var diag: zon.parse.Diagnostics = .{};
    defer diag.deinit(ally);

    config = zon.parse.fromSliceAlloc(Config, ally, config_file_z, &diag, .{}) catch |err| switch (err) {
        error.ParseZon => std.debug.panic("{f}\n", .{diag}),
        else => return err,
    };
    zon_parsed = true;
}

pub fn deinit(ally: Allocator) void {
    if (!zon_parsed) return;
    ally.free(config.mpd_addr);
    ally.free(config.details);
    ally.free(config.state);
}

pub fn get() Config {
    return config;
}

fn readConfigFile(ally: Allocator, io: Io, file_buf: []u8) ![]const u8 {
    const app_name = "mpd_discord_presence";
    const config_name = "config.zon";
    const default_conf: []const u8 = @embedFile("default_config.zon");

    var envmap = std.process.getEnvMap(ally) catch |err| switch (err) {
        Allocator.Error.OutOfMemory => return Allocator.Error.OutOfMemory,
        else => @panic("unexpected error"),
    };
    defer envmap.deinit();

    const config_home = if (builtin.os.tag == .windows) blk: {
        if (envmap.get("APPDATA")) |path|
            break :blk try Io.Dir.cwd().openDir(io, path, .{});
        return error.ConfigHomeNotFound;
    } else if (builtin.os.tag == .macos) blk: {
        if (envmap.get("HOME")) |path| {
            const home = try Io.Dir.cwd().openDir(io, path, .{});
            defer home.close(io);
            break :blk try home.openDir(io, "Library/Preferences/", .{});
        }
        return error.ConfigHomeNotFound;
    } else blk: {
        if (envmap.get("XDG_CONFIG_HOME")) |path| {
            break :blk try Io.Dir.cwd().openDir(io, path, .{});
        } else if (envmap.get("HOME")) |path| {
            const home = try Io.Dir.cwd().openDir(io, path, .{});
            defer home.close(io);
            break :blk try home.openDir(io, ".config/", .{});
        }
        return error.ConfigHomeNotFound;
    };
    defer config_home.close(io);

    const app_config_dir = try config_home.makeOpenPath(io, app_name, .{});
    defer app_config_dir.close(io);

    return app_config_dir.readFile(io, config_name, file_buf) catch |err| switch (err) {
        Io.Dir.ReadFileError.FileNotFound => {
            // TODO wait for zig update
            const new_file: std.fs.File = .{ .handle = (try app_config_dir.createFile(io, config_name, .{})).handle };
            defer new_file.close();

            try new_file.writeAll(default_conf);

            // try app_config_dir.writeFile(io, .{ .sub_path = config_name, .data = default_conf, .flags = .{} });
            return std.fmt.bufPrint(file_buf, "{s}", .{default_conf});
        },
        else => return err,
    };
}
