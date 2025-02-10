const std = @import("std");
const http = std.http;
const Thread = std.Thread;
const env = @import("env.zig");
const tls = @import("tls.zig");
const http2 = @import("http2.zig");

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
    http_version: HttpVersion = .HTTP_1_1,

    pub const HttpVersion = enum(u8) {
        HTTP_1_1 = 1,
        HTTP_2_0 = 2,
    };

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
    const H2_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    const H2_FRAME_TYPE = struct {
        const DATA: u8 = 0x0;
        const HEADERS: u8 = 0x1;
        const PRIORITY: u8 = 0x2;
        const RST_STREAM: u8 = 0x3;
        const SETTINGS: u8 = 0x4;
        const PUSH_PROMISE: u8 = 0x5;
        const PING: u8 = 0x6;
        const GOAWAY: u8 = 0x7;
        const WINDOW_UPDATE: u8 = 0x8;
        const CONTINUATION: u8 = 0x9;
    };

    const H2_SETTINGS = struct {
        const HEADER_TABLE_SIZE: u16 = 0x1;
        const ENABLE_PUSH: u16 = 0x2;
        const MAX_CONCURRENT_STREAMS: u16 = 0x3;
        const INITIAL_WINDOW_SIZE: u16 = 0x4;
        const MAX_FRAME_SIZE: u16 = 0x5;
        const MAX_HEADER_LIST_SIZE: u16 = 0x6;
    };

    const H2_FLAGS = struct {
        const END_STREAM: u8 = 0x1;
        const END_HEADERS: u8 = 0x4;
        const PADDED: u8 = 0x8;
        const PRIORITY: u8 = 0x20;
    };

    allocator: std.mem.Allocator,
    connection: ?std.net.Stream = null,
    stream: union(enum) {
        plain: std.net.Stream,
        secure: *tls.TlsStream,
        http2: *Http2Connection,
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
            .http2 => |conn| conn.deinit(),
        }
    }

    fn buildHttpRequest(self: *Client, req: Request) ![]const u8 {
        const uri = try std.Uri.parse(req.url);
        const host = if (uri.host) |h| h.percent_encoded else return error.InvalidUrl;
        const path = if (uri.path.percent_encoded.len == 0) "/" else uri.path.percent_encoded;

        var request_builder = std.ArrayList(u8).init(self.allocator);
        defer request_builder.deinit();

        const full_path = if (uri.query) |q| blk: {
            var path_with_query = std.ArrayList(u8).init(self.allocator);
            try path_with_query.writer().print("{s}?{s}", .{ path, q.percent_encoded });
            break :blk try path_with_query.toOwnedSlice();
        } else path;
        defer if (uri.query != null) self.allocator.free(full_path);

        const method_str = Request.methodToString(req.method);
        try request_builder.writer().print("{s} {s} HTTP/1.1\r\n", .{ // TODO(Alex): support other versions of HTTP atl
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

    fn sendH2(self: *Client, req: Request) !Response {
        try self.stream.http2.connection.writer.writeAll(H2_PREFACE);

        const stream = try self.stream.http2.connection.startStream();

        var headers = std.ArrayList(http2.Header).init(self.allocator);
        defer headers.deinit();

        try headers.append(.{ .name = ":method", .value = Request.methodToString(req.method) });
        try headers.append(.{ .name = ":path", .value = req.url });
        try headers.append(.{ .name = ":scheme", .value = "https" });

        const uri = try std.Uri.parse(req.url);
        const host = if (uri.host) |h| h.percent_encoded else return error.InvalidUrl;
        try headers.append(.{ .name = ":authority", .value = host });

        if (req.headers.authorization) |auth| {
            try headers.append(.{ .name = "authorization", .value = auth });
        }
        if (req.headers.content_type) |ct| {
            try headers.append(.{ .name = "content-type", .value = ct });
        }
        if (req.headers.accept) |accept| {
            try headers.append(.{ .name = "accept", .value = accept });
        }

        var header_it = req.headers.custom.iterator();
        while (header_it.next()) |h| {
            try headers.append(.{
                .name = h.key_ptr.*,
                .value = h.value_ptr.*,
            });
        }

        const flags: u8 = if (req.body == null) http2.FrameFlags.EndStream | http2.FrameFlags.EndHeaders else http2.FrameFlags.EndHeaders;
        try self.stream.http2.connection.sendHeaders(stream, headers.items, flags);

        if (req.body) |body| {
            try self.stream.http2.connection.sendData(stream, body, http2.FrameFlags.EndStream);
        }

        const response_headers = try self.stream.http2.connection.readHeaders(stream);
        const response_data = try self.stream.http2.connection.readData(stream);

        var res_headers = std.StringHashMap([]const u8).init(self.allocator);
        var status: u32 = 200; // Seems ok to have the default status?

        for (response_headers.items) |header| {
            if (std.mem.eql(u8, header.name, ":status")) {
                status = try std.fmt.parseInt(u32, header.value, 10);
            } else if (!std.mem.startsWith(u8, header.name, ":")) {
                try res_headers.put(
                    try self.allocator.dupe(u8, header.name),
                    try self.allocator.dupe(u8, header.value),
                );
            }
        }

        return .{
            .status = status,
            .body = try self.allocator.dupe(u8, response_data.items),
            .headers = res_headers,
            .allocator = self.allocator,
            .sent_bytes = if (req.body) |b| b.len else 0,
            .received_bytes = response_data.items.len,
        };
    }

    pub fn send(self: *Client, req: Request) !Response {
        switch (req.http_version) {
            .HTTP_1_1 => return self.sendH1(req),
            .HTTP_2_0 => return self.sendH2(req),
        }

        // TODO: Add ALPN negotiation for HTTP/2
        // For now, default to HTTP/1.1
        return self.sendH1(req);
    }

    fn sendH1(self: *Client, req: Request) !Response {
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
            .http2 => |conn| try conn.connection.writer.writeAll(http_request),
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
            .http2 => |conn| try conn.connection.reader.readUntilDelimiter(&status_buffer, '\n'),
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
                .http2 => |conn| conn.connection.reader.readUntilDelimiter(&header_buffer, '\n') catch |err| {
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
                    .http2 => |conn| try conn.connection.reader.read(buffer[0..to_read]),
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
                    .http2 => |conn| conn.connection.reader.read(&buffer) catch |err| {
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

const Http2Connection = struct {
    connection: *http2.Connection,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, reader: std.fs.File.Reader, writer: std.fs.File.Writer) !*Http2Connection {
        const self = try allocator.create(Http2Connection);
        self.connection = try http2.Connection.init(allocator, reader, writer);
        self.allocator = allocator;
        return self;
    }

    pub fn deinit(self: *Http2Connection) void {
        self.connection.deinit();
        self.allocator.destroy(self);
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
