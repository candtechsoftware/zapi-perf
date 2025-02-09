const std = @import("std");
const api = @import("api.zig");
const Env = @import("env.zig").Env;
const Endpoint = @import("api.zig").Endpoint;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    env: Env,

    pub fn init(allocator: std.mem.Allocator, env: Env) Parser {
        return .{
            .allocator = allocator,
            .env = env,
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

            var endpoint = try api.Endpoint.jsonParse(self.allocator, endpoint_json, .{});
            if (endpoint.headers.authorization) |auth| {
                if (Endpoint.extractEnvVar(auth)) |var_name| {
                    const new_auth = try self.env.get(var_name);
                    const token = try self.allocator.dupe(u8, new_auth);
                    const parts = [_][]const u8{ "Bearer", token };
                    endpoint.headers.authorization = try std.mem.join(self.allocator, " ", &parts);
                }
            }

            try endpoints.append(endpoint);
        }

        return endpoints.toOwnedSlice();
    }
};
