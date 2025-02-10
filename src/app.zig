const std = @import("std");
const Cli = @import("cli.zig").Cli;
const Env = @import("root.zig").Env;
const Runner = @import("root.zig").BenchmarkRunner;
const Endpoint = @import("api.zig").Endpoint;
const json = @import("json.zig");

pub const App = struct {
    runner: *Runner,
    endpoints: []Endpoint,
    config: Config,

    pub const Config = struct {
        file_path: ?[]const u8 = null,
        num_threads: usize = 1,
        connection_count: usize = 1,
        num_requests_per_endpoint: usize = 10,
    };

    pub fn init(allocator: std.mem.Allocator) !App {
        var env = Env.init(allocator);
        try env.load();
        defer env.deinit();

        var parser = json.Parser.init(allocator, env);

        var cli = Cli.init(allocator);

        const parsed_args = try cli.parseArgs();
        var config: Config = undefined;

        for (parsed_args) |command| {
            switch (command) {
                .File => |file_path| {
                    config.file_path = file_path;
                },
                .num_threads => |num_threads| {
                    config.num_threads = num_threads;
                },
                .num_connections => |num_connections| {
                    config.connection_count = num_connections;
                },
                .num_requests_per_endpoint => |num_requests_per_endpoint| {
                    config.num_requests_per_endpoint = num_requests_per_endpoint;
                },
            }
        }

        const file_path = config.file_path orelse return error.MissingArgumentFilePath;
        const endpoints = try parser.parse(file_path);

        const runner = try Runner.init(allocator, config.num_threads, config.connection_count);

        return .{
            .runner = runner,
            .endpoints = endpoints,
            .config = config,
        };
    }

    pub fn run(self: *App) !void {
        try self.runner.run(
            self.endpoints,
            self.config.num_requests_per_endpoint,
        );
        try self.runner.store.printDetailedStats();
    }
};
