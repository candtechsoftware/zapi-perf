const std = @import("std");
const perf = @import("api-perf");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var env = perf.Env.init(allocator);

    try env.load();

    const endpoints = [_]perf.api.Endpoint{
        perf.api.Endpoint{
            .body = "",
            .path = "http://google.com",
            .method = .GET,
            .full_path = "http://google.com",
        },
        perf.api.Endpoint{
            .body = "",
            .path = "http://google.com",
            .method = .POST,
            .full_path = "https://httpbin.org/post",
        },
    };
    var runner = try perf.BenchmarkRunner.init(allocator, 2, 2);
    defer runner.deinit();

    try runner.run(&endpoints, 10);
    try runner.store.printDetailedStats();
}
