const std = @import("std");
const Parser = @import("json.zig").Parser;
const Endpoint = @import("api.zig").Endpoint;
const Config = @import("app.zig").App.Config;
const Env = @import("env.zig").Env;

const Command = union(enum) {
    File: []const u8,
    num_threads: usize,
    num_connections: usize,
    num_requests_per_endpoint: usize,
};

pub const Cli = struct {
    allocator: std.mem.Allocator,

    const Result = struct {
        endpoints: []Endpoint,
        config: Config,
    };

    pub fn init(allocator: std.mem.Allocator) Cli {
        return .{
            .allocator = allocator,
        };
    }

    fn printUsage() void {
        std.debug.print("Usage: [options]\n", .{});
        std.debug.print("Options:\n", .{});
        std.debug.print("  -h, --help                Print this help message\n", .{});
        std.debug.print("  -f, --file=<path>         JSON file containing endpoints\n", .{});
        std.debug.print("  --thread-count=<num>      Number of threads to use\n", .{});
        std.debug.print("  --connection-count=<num>   Number of connections to use\n", .{});
        std.debug.print("  --request-count=<num>      Number of requests per endpoint\n", .{});
    }

    fn parseConfigValue(value: []const u8) !usize {
        return std.fmt.parseInt(usize, value, 10);
    }

    pub fn parseArgs(self: *Cli) ![]Command {
        var args = try std.process.argsWithAllocator(self.allocator);
        defer args.deinit();
        _ = args.skip(); // Skipping the name of the program

        var commands = std.ArrayList(Command).init(self.allocator);

        while (args.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--file=") or std.mem.startsWith(u8, arg, "-f=")) {
                var parts = std.mem.splitAny(u8, arg, "=");
                _ = parts.first(); // Skipping the flag name
                const file_path = parts.next() orelse return error.InvalidArgument;
                try commands.append(.{ .File = file_path });
            } else if (std.mem.startsWith(u8, arg, "--thread-count=")) {
                var parts = std.mem.splitAny(u8, arg, "=");
                _ = parts.first();
                const value = parts.next() orelse return error.InvalidArgument;
                try commands.append(.{ .num_threads = (try parseConfigValue(value)) });
            } else if (std.mem.startsWith(u8, arg, "--connection-count=")) {
                var parts = std.mem.splitAny(u8, arg, "=");
                _ = parts.first();
                const value = parts.next() orelse return error.InvalidArgument;
                try commands.append(.{ .num_connections = (try parseConfigValue(value)) });
            } else if (std.mem.startsWith(u8, arg, "--request-count=")) {
                var parts = std.mem.splitAny(u8, arg, "=");
                _ = parts.first();
                const value = parts.next() orelse return error.InvalidArgument;
                try commands.append(.{ .num_requests_per_endpoint = (try parseConfigValue(value)) });
            } else if (std.mem.startsWith(u8, arg, "--help") or std.mem.startsWith(u8, arg, "-h")) {
                printUsage();
                return error.Help;
            } else {
                std.log.err("Unknown argument: {s}\n", .{arg});
                printUsage();
                return error.InvalidArgument;
            }
        }

        // Validate that the --file argument was provided
        var has_file = false;
        for (commands.items) |it| {
            if (it != .File) {
                has_file = true;
                break;
            }
        }

        if (!has_file) {
            std.log.err("Missing required argument: --file\n", .{});
            printUsage();
            return error.InvalidArgument;
        }

        return commands.toOwnedSlice();
    }
};
