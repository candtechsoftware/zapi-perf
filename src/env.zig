const std = @import("std");

const ENV_FILE = ".env";

pub const Env = struct {
    map: std.StringArrayHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Env {
        return .{
            .map = std.StringArrayHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Env) void {
        self.map.deinit();
    }

    pub fn load(self: *Env) !void {
        const file = try std.fs.cwd().openFile(ENV_FILE, .{ .mode = .read_only });
        defer file.close();

        const reader = file.reader();
        var line_buffer: [1024]u8 = undefined;

        while (true) {
            const line = try reader.readUntilDelimiterOrEof(&line_buffer, '\n');
            if (line == null or line.?.len == 0) break;

            const trimmed_line = std.mem.trim(u8, line.?, "\t\r\n");
            if (trimmed_line.len == 0 or std.mem.startsWith(u8, trimmed_line, "#")) continue; // skip empty lines and comments

            var parts = std.mem.splitAny(u8, trimmed_line, "=");
            const key = parts.first();
            const value = parts.next() orelse {
                return error.InvalidEnvVar;
            };

            if (parts.next() != null) {
                return error.InvalidEnvVar;
            }

            try self.map.put(key, value);
        }
    }
};
