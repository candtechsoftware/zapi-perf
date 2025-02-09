const std = @import("std");

const ENV_FILE = ".env";

pub const Env = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap([]const u8), // Changed to StringHashMap

    pub fn init(allocator: std.mem.Allocator) Env {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Env) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn load(self: *Env) !void {
        const file = try std.fs.cwd().openFile(ENV_FILE, .{ .mode = .read_only });
        defer file.close();

        var buffered_reader = std.io.bufferedReader(file.reader());
        var reader = buffered_reader.reader();

        var buffer: [256]u8 = undefined;

        while (true) {
            var line_list = std.ArrayList(u8).init(self.allocator);
            defer line_list.deinit();

            var found_newline = false;
            while (!found_newline) {
                const read_count = try reader.read(&buffer);
                if (read_count == 0) {
                    if (line_list.items.len == 0) break; // no more data
                    found_newline = true;
                    break;
                }
                for (buffer[0..read_count], 0..) |c, i| {
                    if (c == '\n') {
                        try line_list.appendSlice(buffer[0..i]);
                        found_newline = true;
                        break; // discard remaining bytes in this chunk
                    }
                }
                if (!found_newline) {
                    try line_list.appendSlice(buffer[0..read_count]);
                }
            }
            if (line_list.items.len == 0) break;

            const trimmed_line = std.mem.trim(u8, line_list.items, "\t\r");
            if (trimmed_line.len == 0 or std.mem.startsWith(u8, trimmed_line, "#")) continue;

            var parts = std.mem.splitAny(u8, trimmed_line, "=");
            const key = parts.first();
            const value = parts.next() orelse return error.InvalidEnvVar;
            if (parts.next() != null) return error.InvalidEnvVar;

            // Duplicate strings before storing them
            const key_owned = try self.allocator.dupe(u8, key);
            const value_owned = try self.allocator.dupe(u8, value);
            try self.map.put(key_owned, value_owned);
        }
    }

    pub fn get(self: *Env, key: []const u8) ![]const u8 {
        if (self.map.get(key)) |value| {
            return try self.allocator.dupe(u8, value);
        }

        if (std.process.getEnvVarOwned(self.allocator, key)) |value| {
            return value;
        } else |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return error.EnvVarNotFound;
            }
            return err;
        }
    }
};
