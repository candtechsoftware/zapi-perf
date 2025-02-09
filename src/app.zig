const std = @import("std");
const Cli = @import("cli.zig").Cli;
const Env = @import("root.zig").Env;
const Runner = @import("root.zig").BenchmarkRunner;

pub const App = struct {
    cli: Cli,
    runner: *Runner,

    pub fn init(allocator: std.mem.Allocator) !App {
        var env = Env.init(allocator);
        try env.load();
        defer env.deinit();

        const runner = try Runner.init(allocator, 2, 2);
        const cli = Cli.init(allocator);
        return .{
            .cli = cli,
            .runner = runner,
        };
    }

    pub fn run(self: *App) !void {
        const endpoints = try self.cli.parseArgs();
        try self.runner.run(endpoints, 10);
        try self.runner.store.printDetailedStats();
    }
};
