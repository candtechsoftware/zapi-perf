const std = @import("std");
const Parser = @import("json.zig").Parser;
const Endpoint = @import("api.zig").Endpoint;

pub const Cli = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Cli {
        return .{
            .allocator = allocator,
        };
    }

    fn printUsage() void {
        std.debug.print("Usage: [options]\n", .{});
        std.debug.print("Options:\n", .{});
        std.debug.print("  -h, --help      Print this help message\n", .{});
    }

    pub fn parseArgs(self: *Cli) ![]Endpoint {
        var args = try std.process.argsWithAllocator(self.allocator);
        defer args.deinit();
        _ = args.skip(); // Skipping the name of the program

        while (args.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--file") or std.mem.startsWith(u8, arg, "-f")) {
                var parts = std.mem.splitAny(u8, arg, "=");
                _ = parts.first(); // Skipping the flag name
                const file_path = parts.next() orelse return error.InvalidArgument;
                var parser = Parser.init(self.allocator);
                const endpoints = try parser.parse(file_path);
                return endpoints;
            } else if (std.mem.startsWith(u8, arg, "--help") or std.mem.startsWith(u8, arg, "-h")) {
                printUsage();
                return error.Help;
            } else {
                std.log.err("Unknown argument: {s}\n", .{arg});
                printUsage();
                return error.InvalidArgument;
            }
        }
        return error.NoArguments;
    }
};
