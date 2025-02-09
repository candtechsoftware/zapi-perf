const std = @import("std");
const Thread = std.Thread;
const store = @import("store.zig");
const api = @import("api.zig");

pub const ThreadPool = struct {
    pub const Task = struct {
        endpoint: api.Endpoint,
        connection_pool: *api.ConnectionPool,
        store: *store.ResultStore,
    };

    pub const TaskQueue = struct {
        mutex: Thread.Mutex = .{},
        cond: Thread.Condition = .{},
        tasks: std.ArrayList(Task),
        shutdown: bool = false,

        pub fn init(allocator: std.mem.Allocator) TaskQueue {
            return .{
                .tasks = std.ArrayList(Task).init(allocator),
            };
        }

        pub fn deinit(self: *TaskQueue) void {
            self.tasks.deinit();
        }

        pub fn push(self: *TaskQueue, task: Task) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.tasks.append(task);
            self.cond.signal();
        }

        pub fn pop(self: *TaskQueue) ?Task {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.tasks.items.len == 0 and !self.shutdown) {
                self.cond.wait(&self.mutex);
            }

            if (self.shutdown and self.tasks.items.len == 0) {
                return null;
            }

            const task = self.tasks.orderedRemove(0);
            return task;
        }
    };

    threads: []Thread,
    task_queue: TaskQueue,
    allocator: std.mem.Allocator,
    completed_tasks: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, thread_count: usize) !*ThreadPool {
        const pool = try allocator.create(ThreadPool);
        pool.* = .{
            .threads = try allocator.alloc(Thread, thread_count),
            .task_queue = TaskQueue.init(allocator),
            .allocator = allocator,
            .completed_tasks = std.atomic.Value(usize).init(0),
        };

        for (pool.threads) |*th| {
            th.* = try std.Thread.spawn(.{}, workerLoop, .{pool});
        }

        return pool;
    }

    fn workerFunc(pool: *ThreadPool) void {
        while (true) {
            if (pool.task_queue.pop()) |task| {
                api.makeRequest(task.endpoint, task.connection_pool) catch |err| {
                    std.log.err("Error in worker endpoint: {s} err: {any} \n", .{ task.endpoint.path, err });
                };
            } else {
                break;
            }
        }
    }

    pub fn deinit(self: *ThreadPool) void {
        self.shutdown();
        self.task_queue.deinit();
        self.allocator.free(self.threads);
        self.allocator.destroy(self);
    }

    fn workerLoop(pool: *ThreadPool) void {
        while (true) {
            if (pool.task_queue.pop()) |*task| {
                processTask(@constCast(task)) catch |err| {
                    std.log.err("Task err: {any}\n", .{err});
                };
                _ = pool.completed_tasks.fetchAdd(1, .monotonic);
            } else {
                break;
            }
        }
    }

    // Task job to be ran in the thread.
    fn processTask(task: *Task) !void {
        const start_time = std.time.milliTimestamp();
        const client = task.connection_pool.acquire() orelse return error.NoAvailableConnection;
        defer task.connection_pool.release(client) catch {};
        const req: api.Request = .{
            .method = task.endpoint.method,
            .url = task.endpoint.url,
            .headers = task.endpoint.headers,
            .body = task.endpoint.body,
        };

        var res = client.send(req) catch |err| {
            try task.store.add(.{
                .url = task.endpoint.url,
                .status = 0,
                .response_time = std.time.milliTimestamp() - start_time,
                .timestamp = std.time.milliTimestamp(),
                .method = task.endpoint.method,
                .err = err,
                .bytes_sent = 0,
                .bytes_received = 0,
            });
            return;
        };
        defer res.deinit();

        const end_time = std.time.milliTimestamp();
        try task.store.add(
            .{
                .url = task.endpoint.url,
                .status = res.status,
                .response_time = end_time - start_time,
                .timestamp = end_time,
                .method = task.endpoint.method,
                .err = null,
                .bytes_sent = res.sent_bytes,
                .bytes_received = res.received_bytes,
            },
        );
    }

    pub fn submit(self: *ThreadPool, task: Task) !void {
        try self.task_queue.push(task);
    }

    pub fn shutdown(self: *ThreadPool) void {
        self.task_queue.mutex.lock();
        self.task_queue.shutdown = true;
        self.task_queue.cond.broadcast();
        self.task_queue.mutex.unlock();

        for (self.threads) |th| {
            th.join();
        }

        self.allocator.free(self.threads);
    }

    pub fn getCompletedTask(self: *ThreadPool) usize {
        return self.completed_tasks.load(.monotonic);
    }
};
