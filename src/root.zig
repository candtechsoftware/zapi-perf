const std = @import("std");
const http = std.http;

pub usingnamespace @import("env.zig");

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

    pub fn init(allocator: std.mem.Allocator, thread_count: usize, connection_count: usize) !*BenchmarkRunner {
        var runner = try allocator.create(BenchmarkRunner);
        runner.thread_pool = try threads.ThreadPool.init(allocator, thread_count);
        runner.connection_pool = try allocator.create(api.ConnectionPool);
        runner.connection_pool.* = try api.ConnectionPool.init(allocator, connection_count);
        runner.store = try allocator.create(store.ResultStore);
        runner.store.* = store.ResultStore.init(allocator);
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

        for (endpoints) |endpoint| {
            for (0..req_per_endpoint) |_| {
                try self.thread_pool.submit(.{
                    .endpoint = endpoint,
                    .connection_pool = self.connection_pool,
                    .store = self.store,
                });
            }
        }

        while (true) {
            const completed = self.thread_pool.getCompletedTask();
            const progress = @as(f64, @floatFromInt(completed)) / @as(f64, @floatFromInt(total_tasks)) * 100.0;
            std.log.info("\r Progress {d:1}%", .{progress});

            if (completed == total_tasks) break;
            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }
};
