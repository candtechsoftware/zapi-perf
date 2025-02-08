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
            .path = "https://google.com",
            .method = .GET,
            .full_path = "https://google.com",
        },
    };
    var runner = try perf.BenchmarkRunner.init(allocator, 2, 2);
    defer runner.deinit();

    try runner.run(&endpoints, 10);
    runner.store.print();
}
