const std = @import("std");
const http = std.http;
const Thread = std.Thread;

pub const Endpoint = struct {
    method: http.Method,
    path: []const u8,
    full_path: []const u8,
    body: []const u8,
    headers: Request.Headers = .{},
};

pub const Request = struct {
    method: http.Method,
    url: []const u8,
    body: ?[]const u8,
    headers: Headers = .{},

    pub const Headers = struct {
        authorization: ?[]const u8 = null,
        content_type: ?[]const u8 = null,
        accept: ?[]const u8 = null,
        custom: std.StringHashMap([]const u8) = undefined,

        pub fn init(allocator: std.mem.Allocator) Headers {
            return .{
                .custom = std.StringHashMap([]const u8).init(allocator),
            };
        }
    };

    pub fn deinit(self: *Request) void {
        self.headers.custom.deinit();
    }

    pub fn methodToString(method: http.Method) []const u8 {
        switch (method) {
            http.Method.GET => return "GET",
            http.Method.POST => return "POST",
            else => return "UNKNOWN",
        }
    }
    pub fn methodFromStr(method: []const u8) !http.Method {
        // TODO(Alex): support more methods
        if (std.mem.eql(u8, method, "GET") or std.mem.eql("get")) return http.Method.GET;
        if (std.mem.eql(u8, method, "POST") or std.mem.eql("post")) return http.Method.GET;
        return error.InvalidMethod;
    }
};

pub const Response = struct {
    status: u32,
    body: []const u8,
    headers: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        var header_it = self.headers.iterator();
        while (header_it.next()) |h| {
            self.allocator.free(h.value_ptr.*);
        }

        self.headers.deinit();
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    connection: ?std.net.Stream = null,
    stream: union(enum) {
        plain: std.net.Stream,
    } = .{ .plain = undefined },
    index: usize,

    pub fn init(allocator: std.mem.Allocator, index: usize) Client {
        return .{
            .allocator = allocator,
            .index = index,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.connection) |con| {
            con.close();
        }
    }

    pub fn send(self: *Client, req: Request) !Response {
        const uri = try std.Uri.parse(req.url);
        const host = try std.Uri.Component.toRawMaybeAlloc(uri.host.?, self.allocator);
        const is_https = std.mem.eql(u8, "", "https");
        const port: u16 = uri.port orelse if (is_https) 443 else 80;

        // Create socket connection
        var socket = try std.net.tcpConnectToHost(self.allocator, host, port);
        errdefer socket.close();

        // Setup TLS if needed
        if (is_https) {
            @panic("TLS not supported yet");
        } else {
            self.stream = .{ .plain = socket };
        }

        var conn = self.stream.plain;
        var request_builder = std.ArrayList(u8).init(self.allocator);
        defer request_builder.deinit();

        try request_builder.writer().print("{s} {s} HTTP/1.1\r\n", .{
            Request.methodToString(req.method),
            host,
        });

        try request_builder.writer().print("Host: {s}\r\n", .{host});

        if (req.headers.authorization) |auth| {
            try request_builder.writer().print("Authorization: {s}\r\n", .{auth});
        }
        if (req.headers.content_type) |ct| {
            try request_builder.writer().print("Content-Type: {s}\r\n", .{ct});
        }
        if (req.headers.accept) |accept| {
            try request_builder.writer().print("Accept: {s}\r\n", .{accept});
        }

        var header_it = req.headers.custom.iterator();
        while (header_it.next()) |h| {
            try request_builder.writer().print("{s}: {s}\r\n", .{
                h.key_ptr.*,
                h.value_ptr.*,
            });
        }

        if (req.body) |body| {
            try request_builder.writer().print("Content-Length: {d}\r\n", .{body.len});
            try request_builder.writer().writeAll("\r\n");
            try request_builder.writer().writeAll(body);
        } else {
            try request_builder.writer().writeAll("\r\n");
        }

        // Sending the request
        try conn.writer().writeAll(request_builder.items);

        var res_headers = std.StringHashMap([]const u8).init(self.allocator);
        var buffer: [4096]u8 = undefined;
        var status: u32 = 0;
        var content_len: ?usize = null;

        // Reading the status of the request
        {
            const line = try conn.reader().readUntilDelimiter(&buffer, '\n');
            var parts = std.mem.splitAny(u8, line, " ");
            _ = parts.next(); // HTTP version
            if (parts.next()) |status_str| {
                status = try std.fmt.parseInt(u32, status_str, 10);
            }
        }

        // Reading the headers
        while (try conn.reader().readUntilDelimiterOrEof(&buffer, '\n')) |line| {
            if (line.len <= 2) break; // empty line
            var parts = std.mem.splitAny(u8, line, ":");
            if (parts.next()) |name| {
                if (parts.next()) |value| {
                    const trimmed_value = std.mem.trim(u8, value, " \r");
                    const header_value = try self.allocator.dupe(u8, trimmed_value);
                    try res_headers.put(
                        try self.allocator.dupe(u8, name),
                        header_value,
                    );
                    if (std.mem.eql(u8, name, "Content-Length")) {
                        content_len = try std.fmt.parseInt(
                            usize,
                            trimmed_value,
                            10,
                        );
                    }
                }
            }
        }

        // Reading the body of the request.
        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();

        if (content_len) |len| {
            try body.ensureTotalCapacity(len);
            var remain = len;
            while (remain > 0) {
                const read = try conn.read(buffer[0..@min(remain, buffer.len)]);
                if (read == 0) break;
                try body.appendSlice(buffer[0..read]);
                remain -= read;
            }
        } else {
            while (true) {
                const read = try conn.read(&buffer);
                if (read == 0) break;
                try body.appendSlice(buffer[0..read]);
            }
        }
        return .{
            .status = status,
            .body = try body.toOwnedSlice(),
            .headers = res_headers,
            .allocator = self.allocator,
        };
    }
};

pub const ConnectionPool = struct {
    clients: []Client,
    mutex: Thread.Mutex = .{},
    cond: Thread.Condition = .{},
    available: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize) !ConnectionPool {
        var clients = try allocator.alloc(Client, size);
        var available = std.ArrayList(usize).init(allocator);

        for (0..size) |i| {
            clients[i] = Client.init(allocator, i);
            try available.append(i);
        }

        return .{
            .clients = clients,
            .available = available,
            .allocator = allocator,
        };
    }

    pub fn acquire(self: *ConnectionPool) ?*Client {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.available.items.len == 0) {
            self.cond.wait(&self.mutex);
        }

        const index = self.available.orderedRemove(0);
        std.debug.print("Acquired connection at index: {d}\n", .{index});
        std.debug.print("Clients:::{any}\n", .{self.clients});
        return &self.clients[index];
    }

    pub fn release(self: *ConnectionPool, client: *Client) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.available.append(@intCast(client.index));

        self.cond.signal();
    }

    pub fn deinit(self: *ConnectionPool) void {
        for (self.clients) |*c| {
            c.deinit();
        }

        self.allocator.free(self.clients);
        self.available.deinit();
    }
};
