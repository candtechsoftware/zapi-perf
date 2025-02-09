const std = @import("std");
const api = @import("api.zig");

pub const Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .allocator = allocator,
        };
    }

    pub fn parse(self: *Parser, file_path: []const u8) ![]api.Endpoint {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const file_content = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(file_content);

        var endpoints = std.ArrayList(api.Endpoint).init(self.allocator);
        errdefer endpoints.deinit();

        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            file_content,
            .{},
        );
        defer parsed.deinit();

        const array = parsed.value.array;
        for (array.items) |item| {
            const endpoint_json = try std.json.stringifyAlloc(self.allocator, item, .{});
            defer self.allocator.free(endpoint_json);

            const endpoint = try api.Endpoint.jsonParse(self.allocator, endpoint_json, .{});
            try endpoints.append(endpoint);
        }

        return endpoints.toOwnedSlice();
    }
};
