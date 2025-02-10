const std = @import("std");
const http = std.http;
const Thread = std.Thread;
const env = @import("env.zig");
const tls = @import("tls.zig");

pub const Endpoint = struct {
    method: http.Method,
    url: []const u8,
    body: []const u8 = "",
    headers: Request.Headers = .{},

    // TODO(Alex): I don't like this api for this
    // for now it works but need to refactor this to automatically do this for every header
    pub fn extractEnvVar(text: []const u8) ?[]const u8 {
        if (std.mem.indexOf(u8, text, "<")) |start| {
            if (std.mem.indexOf(u8, text[start..], ">")) |end| {
                return text[start + 1 .. start + end];
            }
        }
        return null;
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: []const u8, options: std.json.ParseOptions) !Endpoint {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, options);
        defer parsed.deinit();

        const value = parsed.value;
        if (value != .object) return error.InvalidJson;

        // Extract and validate method and url
        const method = value.object.get("method") orelse return error.MissingMethod;
        const url_value = value.object.get("url") orelse return error.MissingUrl;

        if (method != .string or url_value != .string) return error.InvalidFormat;

        // Create owned copies of strings
        const url_copy = try allocator.dupe(u8, url_value.string);
        errdefer allocator.free(url_copy);

        var headers = Request.Headers.init(allocator);
        errdefer {
            // Clean up headers if we fail after this point
            if (headers.authorization) |auth| allocator.free(auth);
            if (headers.content_type) |ct| allocator.free(ct);
            if (headers.accept) |accept| allocator.free(accept);
            headers.custom.deinit();
        }

        // Parse headers if present
        if (value.object.get("headers")) |h| {
            if (h == .object) {
                var it = h.object.iterator();
                while (it.next()) |header| {
                    if (header.value_ptr.* != .string) continue;
                    const header_value = header.value_ptr.string;

                    if (std.ascii.eqlIgnoreCase(header.key_ptr.*, "authorization")) {
                        headers.authorization = try allocator.dupe(u8, header_value);
                    } else if (std.ascii.eqlIgnoreCase(header.key_ptr.*, "content-type")) {
                        headers.content_type = try allocator.dupe(u8, header_value);
                    } else if (std.ascii.eqlIgnoreCase(header.key_ptr.*, "accept")) {
                        headers.accept = try allocator.dupe(u8, header_value);
                    } else {
                        try headers.custom.put(
                            try allocator.dupe(u8, header.key_ptr.*),
                            try allocator.dupe(u8, header_value),
                        );
                    }
                }
            }
        }

        const body_str = if (value.object.get("body")) |b| blk: {
            var body_string = std.ArrayList(u8).init(allocator);
            errdefer body_string.deinit();
            try std.json.stringify(b, .{}, body_string.writer());
            break :blk try body_string.toOwnedSlice();
        } else "";

        return .{
            .method = try Request.methodFromStr(method.string),
            .url = url_copy,
            .body = body_str,
            .headers = headers,
        };
    }

    pub fn print(self: Endpoint, writer: anytype) !void {
        try writer.print("Endpoint:\n", .{});
        try writer.print("  Method: {s}\n", .{Request.methodToString(self.method)});
        try writer.print("  URL: {s}\n", .{self.url});

        try writer.print("  Headers:\n", .{});
        if (self.headers.authorization) |auth| {
            try writer.print("    Authorization: {s}\n", .{auth});
        }
        if (self.headers.content_type) |ct| {
            try writer.print("    Content-Type: {s}\n", .{ct});
        }
        if (self.headers.accept) |accept| {
            try writer.print("    Accept: {s}\n", .{accept});
        }

        var it = self.headers.custom.iterator();
        while (it.next()) |header| {
            try writer.print("    {s}: {s}\n", .{ header.key_ptr.*, header.value_ptr.* });
        }

        if (self.body.len > 0) {
            try writer.print("  Body: {s}\n", .{self.body});
        }
    }

    pub fn toString(self: Endpoint, allocator: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();
        try self.print(list.writer());
        return list.toOwnedSlice();
    }
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
        if (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "get")) return http.Method.GET;
        if (std.mem.eql(u8, method, "POST") or std.mem.eql(u8, method, "post")) return http.Method.POST;
        return error.InvalidMethod;
    }

    pub fn print(self: Request, writer: anytype) !void {
        try writer.print("Request:\n", .{});
        try writer.print("  Method: {s}\n", .{methodToString(self.method)});
        try writer.print("  URL: {s}\n", .{self.url});

        // Print headers
        try writer.print("  Headers:\n", .{});
        if (self.headers.authorization) |auth| {
            try writer.print("    Authorization: {s}\n", .{auth});
        }
        if (self.headers.content_type) |ct| {
            try writer.print("    Content-Type: {s}\n", .{ct});
        }
        if (self.headers.accept) |accept| {
            try writer.print("    Accept: {s}\n", .{accept});
        }

        var it = self.headers.custom.iterator();
        while (it.next()) |header| {
            try writer.print("    {s}: {s}\n", .{ header.key_ptr.*, header.value_ptr.* });
        }

        if (self.body) |body| {
            try writer.print("  Body: {s}\n", .{body});
        }
    }

    pub fn toString(self: Request, allocator: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();
        try self.print(list.writer());
        return list.toOwnedSlice();
    }
};

pub const Response = struct {
    status: u32,
    body: []const u8,
    headers: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    sent_bytes: usize,
    received_bytes: usize,

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
        secure: *tls.TlsStream,
    } = .{ .plain = undefined },
    index: usize,

    pub fn init(allocator: std.mem.Allocator, index: usize) Client {
        return .{
            .allocator = allocator,
            .index = index,
        };
    }

    pub fn deinit(self: *Client) void {
        switch (self.stream) {
            .plain => |conn| conn.close(),
            .secure => |conn| conn.deinit(),
        }
    }

    fn buildHttpRequest(self: *Client, req: Request) ![]const u8 {
        const uri = try std.Uri.parse(req.url);
        const host = if (uri.host) |h| h.percent_encoded else return error.InvalidUrl;
        const path = if (uri.path.percent_encoded.len == 0) "/" else uri.path.percent_encoded;

        var request_builder = std.ArrayList(u8).init(self.allocator);
        defer request_builder.deinit();

        // Build path with query parameters
        const full_path = if (uri.query) |q| blk: {
            var path_with_query = std.ArrayList(u8).init(self.allocator);
            try path_with_query.writer().print("{s}?{s}", .{ path, q.percent_encoded });
            break :blk try path_with_query.toOwnedSlice();
        } else path;
        defer if (uri.query != null) self.allocator.free(full_path);

        const method_str = Request.methodToString(req.method);
        try request_builder.writer().print("{s} {s} HTTP/1.1\r\n", .{
            method_str,
            full_path,
        });

        try request_builder.writer().print("Host: {s}\r\n", .{host});
        if (req.headers.authorization) |auth| {
            if (std.mem.containsAtLeast(u8, auth, 1, "<")) {
                @panic("Basic auth not supported yet");
            }
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
            try request_builder.writer().print("{s}: {s}\r\r", .{
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
        return try request_builder.toOwnedSlice();
    }

    pub fn send(self: *Client, req: Request) !Response {
        const uri = try std.Uri.parse(req.url);
        // Don't free host here since it's a slice of req.url which is owned by the Endpoint
        const host = if (uri.host) |h| h.percent_encoded else return error.InvalidUrl;

        const is_https = std.mem.startsWith(u8, req.url, "https");
        const port: u16 = uri.port orelse if (is_https) 443 else 80;

        var socket = try std.net.tcpConnectToHost(self.allocator, host, port);
        errdefer socket.close();

        if (is_https) {
            var tls_stream = try tls.TlsStream.init(self.allocator, socket);
            errdefer tls_stream.deinit();
            try tls_stream.connect(host);
            self.stream = .{ .secure = tls_stream };
        } else {
            self.stream = .{ .plain = socket };
        }

        const http_request = try self.buildHttpRequest(req);
        const sent_len = http_request.len;

        switch (self.stream) {
            .plain => |*conn| try conn.writer().writeAll(http_request),
            .secure => |conn| try conn.writer().writeAll(http_request),
        }

        var total_received: usize = 0;
        var buffer: [4096]u8 = undefined;
        var status: u32 = 0;
        var content_len: ?usize = null;
        var res_headers = std.StringHashMap([]const u8).init(self.allocator);

        // Reading the status of the request
        var status_buffer: [128]u8 = undefined;
        const status_line = switch (self.stream) {
            .plain => |*conn| try conn.reader().readUntilDelimiter(&status_buffer, '\n'),
            .secure => |conn| try conn.reader().readUntilDelimiter(&status_buffer, '\n'),
        };
        total_received += status_line.len;
        var parts = std.mem.splitAny(u8, status_line, " ");
        _ = parts.next(); // HTTP version
        if (parts.next()) |status_str| {
            status = try std.fmt.parseInt(u32, status_str, 10);
        }

        // Reading the headers with larger buffer
        var header_buffer: [8192]u8 = undefined;

        while (true) {
            const line = switch (self.stream) {
                .plain => |*conn| conn.reader().readUntilDelimiter(&header_buffer, '\n') catch |err| {
                    if (err == error.StreamTooLong) {
                        std.log.warn("Header too long, truncating", .{});
                        continue;
                    }
                    return err;
                },
                .secure => |conn| conn.reader().readUntilDelimiter(&header_buffer, '\n') catch |err| {
                    if (err == error.StreamTooLong) {
                        std.log.warn("Header too long, truncating", .{});
                        continue;
                    }
                    return err;
                },
            };
            total_received += line.len;
            if (line.len <= 2) break; // empty line

            var header_parts = std.mem.splitAny(u8, line, ":");
            if (header_parts.next()) |name| {
                if (header_parts.next()) |value| {
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

        // Reading the body with chunked handling
        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();

        if (content_len) |len| {
            try body.ensureTotalCapacity(len);
            var remain = len;
            while (remain > 0) {
                const to_read = @min(remain, buffer.len);
                const read = switch (self.stream) {
                    .plain => |*conn| try conn.reader().read(buffer[0..to_read]),
                    .secure => |conn| try conn.reader().read(buffer[0..to_read]),
                };
                if (read == 0) break;
                try body.appendSlice(buffer[0..read]);
                remain -= read;
                total_received += read;
            }
        } else {
            while (true) {
                const read = switch (self.stream) {
                    .plain => |*conn| conn.reader().read(&buffer) catch |err| {
                        if (err == error.ConnectionResetByPeer) break;
                        return err;
                    },
                    .secure => |conn| conn.reader().read(&buffer) catch |err| {
                        if (err == error.ConnectionResetByPeer) break;
                        return err;
                    },
                };
                if (read == 0) break;
                try body.appendSlice(buffer[0..read]);
                total_received += read;
            }
        }

        return .{
            .status = status,
            .body = try body.toOwnedSlice(),
            .headers = res_headers,
            .allocator = self.allocator,
            .sent_bytes = sent_len,
            .received_bytes = total_received,
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
