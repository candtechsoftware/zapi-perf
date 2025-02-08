const std = @import("std");

pub const ResultStore = struct {
    mutex: std.Thread.Mutex = .{},
    results: std.ArrayList(Result),
    allocator: std.mem.Allocator,

    pub const Result = struct {
        url: []const u8,
        status: u32,
        response_time: i64,
        timestamp: i64,
        method: std.http.Method,
        err: ?anyerror,
    };

    pub fn init(allocator: std.mem.Allocator) ResultStore {
        return .{
            .results = std.ArrayList(Result).init(allocator),
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *ResultStore) void {
        self.results.deinit();
    }

    pub fn add(self: *ResultStore, result: Result) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.results.append(result);
    }

    pub fn print(self: *ResultStore) void {
        for (self.results.items) |item| {
            std.debug.print("Result: url: {s} status: {d} response_time: {d} err: {any}", .{
                item.url,
                item.status,
                item.response_time,
                item.err,
            });
        }
    }
};
