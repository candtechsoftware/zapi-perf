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
        bytes_sent: usize,
        bytes_received: usize,
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
            std.debug.print("Result: url: {s} status: {d} response_time: {d} err: {any}\n", .{
                item.url,
                item.status,
                item.response_time,
                item.err,
            });
        }
    }
    fn percentile(p: f64, times: std.ArrayList(f64)) f64 {
        if (p == 100.0) return times.items[times.items.len - 1];
        const idxf: f64 = p / 100.0 * @as(f64, @floatFromInt(times.items.len));
        const idx = @as(
            usize,
            @intFromFloat(idxf),
        );
        return times.items[idx];
    }

    pub fn printDetailedStats(self: *ResultStore) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.results.items.len == 0) {
            std.debug.print("No requests recorded.\n", .{});
            return;
        }

        // Create a map to store results per URL
        var url_results = std.StringHashMap(std.ArrayList(Result)).init(self.allocator);
        defer {
            var it = url_results.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            url_results.deinit();
        }

        // Group results by URL
        for (self.results.items) |res| {
            if (!url_results.contains(res.url)) {
                try url_results.put(res.url, std.ArrayList(Result).init(self.allocator));
            }
            try url_results.getPtr(res.url).?.append(res);
        }

        // Print stats for each URL
        var url_it = url_results.iterator();
        while (url_it.next()) |entry| {
            const url = entry.key_ptr.*;
            const results = entry.value_ptr.*;

            std.debug.print("\nStats for endpoint: {s}\n", .{url});
            std.debug.print("----------------------------------------\n", .{});

            var total_time: f64 = 0;
            var min_time: f64 = std.math.floatMax(f64);
            var max_time: f64 = 0;
            var errors_count: usize = 0;
            var total_bytes_sent: usize = 0;
            var total_bytes_received: usize = 0;

            var times = std.ArrayList(f64).init(self.allocator);
            defer times.deinit();

            for (results.items) |res| {
                const time_ms = @as(f64, @floatFromInt(res.response_time));
                if (res.err != null) errors_count += 1;
                total_time += time_ms;
                if (time_ms < min_time) min_time = time_ms;
                if (time_ms > max_time) max_time = time_ms;
                try times.append(time_ms);
                total_bytes_sent += res.bytes_sent;
                total_bytes_received += res.bytes_received;
            }

            const Context = struct {
                fn lessThan(context: void, a: f64, b: f64) bool {
                    _ = context;
                    return a < b;
                }
            };

            std.sort.insertion(f64, times.items, {}, Context.lessThan);

            const total_requests = results.items.len;
            const avg_time = total_time / @as(f64, @floatFromInt(total_requests));
            const duration_secs = @as(f64, @floatFromInt(results.items[results.items.len - 1].timestamp - results.items[0].timestamp)) / 1000.0;
            const req_per_sec = @as(f64, @floatFromInt(total_requests)) / duration_secs;
            const transfer_per_sec = @as(f64, @floatFromInt(total_bytes_received)) / duration_secs / 1024.0 / 1024.0;

            std.debug.print("Requests/sec:\t\t{d:.2}\n", .{req_per_sec});
            std.debug.print("Transfer/sec:\t\t{d:.2}MB\n", .{transfer_per_sec});
            std.debug.print("Total Requests:\t\t{d}\n", .{total_requests});
            std.debug.print("Failed Requests:\t\t{d}\n", .{errors_count});
            std.debug.print("Fastest Request:\t{d:.3}ms\n", .{min_time});
            std.debug.print("Slowest Request:\t{d:.3}ms\n", .{max_time});
            std.debug.print("Avg Req Time:\t\t{d:.3}ms\n", .{avg_time});
        }
    }
};
