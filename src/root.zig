const std = @import("std");
const http = std.http;

pub usingnamespace @import("env.zig");
pub usingnamespace @import("cli.zig");
pub usingnamespace @import("json.zig");
pub usingnamespace @import("app.zig");

pub const api = @import("api.zig");
pub const threads = @import("thread_pool.zig");
pub const store = @import("store.zig");

pub const BenchmarkTask = struct {
    endpoint: api.Endpoint,
    connection_pool: *api.ConnectionPool,
    store: *store.ResultStore,
};
pub const BenchmarkRunner = struct {
    thread_pool: *threads.ThreadPool,
    connection_pool: *api.ConnectionPool,
    store: *store.ResultStore,
    allocator: std.mem.Allocator,
    completed_tasks: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, thread_count: usize, connection_count: usize) !*BenchmarkRunner {
        var runner = try allocator.create(BenchmarkRunner);
        runner.thread_pool = try threads.ThreadPool.init(allocator, thread_count);
        runner.connection_pool = try allocator.create(api.ConnectionPool);
        runner.connection_pool.* = try api.ConnectionPool.init(allocator, connection_count);
        runner.store = try allocator.create(store.ResultStore);
        runner.store.* = store.ResultStore.init(allocator);
        runner.completed_tasks = std.atomic.Value(usize).init(0);
        runner.allocator = allocator;
        return runner;
    }

    pub fn deinit(self: *BenchmarkRunner) void {
        self.thread_pool.shutdown();
        self.connection_pool.deinit();
        self.store.deinit();
        self.allocator.destroy(self.store);
        self.allocator.destroy(self);
    }

    pub fn run(self: *BenchmarkRunner, endpoints: []const api.Endpoint, req_per_endpoint: usize) !void {
        const total_tasks = endpoints.len * req_per_endpoint;
        const bar_width = 50;
        const stdout_file = std.io.getStdOut();
        var buffered_writer = std.io.bufferedWriter(stdout_file.writer());
        const stdout = buffered_writer.writer();

        // Submit all tasks first
        for (endpoints) |endpoint| {
            for (0..req_per_endpoint) |_| {
                try self.thread_pool.submit(.{
                    .endpoint = endpoint,
                    .connection_pool = self.connection_pool,
                    .store = self.store,
                });
            }
        }

        var last_completed: usize = 0;
        while (true) {
            const completed = self.thread_pool.getCompletedTasks();
            if (completed != last_completed) {
                last_completed = completed;
                const progress = (completed * 100) / total_tasks;
                const filled = (completed * bar_width) / total_tasks;

                try stdout.print("\r[", .{});
                try stdout.writeByteNTimes('=', filled);
                try stdout.writeByteNTimes(' ', bar_width - filled);
                try stdout.print("] {d}%", .{progress});
                try buffered_writer.flush();
            }

            if (completed >= total_tasks) {
                try stdout.print("\n", .{});
                try buffered_writer.flush();
                break;
            }
            std.time.sleep(10 * std.time.ns_per_ms); // Sleep for 10ms for more responsive updates
        }
    }

    pub fn getCompletedTasks(self: *BenchmarkRunner) usize {
        return self.completed_tasks.load(.monotonic);
    }

    pub fn incrementCompletedTasks(self: *BenchmarkRunner) void {
        _ = self.completed_tasks.fetchAdd(1, .monotonic);
    }
};
