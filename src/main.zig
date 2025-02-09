const std = @import("std");
const perf = @import("api-perf");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var app = try perf.App.init(allocator);

    try app.run();
}
