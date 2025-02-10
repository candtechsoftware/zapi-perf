const std = @import("std");

pub const TlsStream = struct {
    allocator: std.mem.Allocator,
    inner: std.net.Stream,
    connected: bool = false,
    read_buffer: std.ArrayList(u8),
    sequence_number: u64 = 0,

    pub const TlsError = error{
        NotConnected,
        UnexpectedMessage,
        HandshakeFailed,
        TlsError,
        OutOfMemory,
    } || std.net.Stream.ReadError || std.net.Stream.WriteError;

    const TlsRecord = struct {
        content_type: u8,
        version: u16,
        length: u16,
        data: []const u8,
    };

    const TLS_VERSION = 0x0303; // TLS 1.2
    const RECORD_TYPE_HANDSHAKE = 0x16;
    const RECORD_TYPE_APPLICATION_DATA = 0x17;
    const HANDSHAKE_TYPE_CLIENT_HELLO = 0x01;
    const HANDSHAKE_TYPE_SERVER_HELLO = 0x02;

    pub fn init(allocator: std.mem.Allocator, socket: std.net.Stream) !*TlsStream {
        const self = try allocator.create(TlsStream);
        self.* = .{
            .allocator = allocator,
            .inner = socket,
            .read_buffer = std.ArrayList(u8).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *TlsStream) void {
        self.read_buffer.deinit();
        self.inner.close();
        self.allocator.destroy(self);
    }

    fn writeRecord(self: *TlsStream, record_type: u8, data: []const u8) !void {
        var header = [_]u8{
            record_type,
            @intCast((TLS_VERSION >> 8) & 0xFF),
            @intCast(TLS_VERSION & 0xFF),
            @intCast((data.len >> 8) & 0xFF),
            @intCast(data.len & 0xFF),
        };
        try self.inner.writeAll(&header);
        try self.inner.writeAll(data);
    }

    fn readRecord(self: *TlsStream) TlsError!TlsRecord {
        var header: [5]u8 = undefined;
        _ = try self.inner.readAll(&header);

        const length = (@as(u16, header[3]) << 8) | header[4];
        const data = self.allocator.alloc(u8, length) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return err,
        };
        errdefer self.allocator.free(data);

        _ = try self.inner.readAll(data);

        return TlsRecord{
            .content_type = header[0],
            .version = (@as(u16, header[1]) << 8) | header[2],
            .length = length,
            .data = data,
        };
    }

    pub fn connect(self: *TlsStream, hostname: []const u8) !void {
        var client_random: [32]u8 = undefined;
        std.crypto.random.bytes(&client_random);

        var client_hello = std.ArrayList(u8).init(self.allocator);
        defer client_hello.deinit();

        try client_hello.appendSlice(&[_]u8{
            HANDSHAKE_TYPE_CLIENT_HELLO,
            0x00, 0x00, 0x00, // Length placeholder
        });

        // Client version
        try client_hello.appendSlice(&[_]u8{
            @intCast((TLS_VERSION >> 8) & 0xFF),
            @intCast(TLS_VERSION & 0xFF),
        });

        try client_hello.appendSlice(&client_random);

        try client_hello.append(0);

        try client_hello.appendSlice(&[_]u8{
            0x00, 0x02, // Length of cipher suites
            0x00, 0x9C, // TLS_RSA_WITH_AES_128_GCM_SHA256
        });

        // Compression methods (none)
        try client_hello.appendSlice(&[_]u8{ 0x01, 0x00 });

        // Extensions (minimal SNI)
        if (hostname.len > 0) {
            // SNI extension
            const sni_len = hostname.len + 5;
            const ext_len = sni_len + 4;
            try client_hello.appendSlice(&[_]u8{
                0x00,                     @intCast(ext_len >> 8),
                @intCast(ext_len & 0xFF), 0x00,
                0x00,                     @intCast(sni_len >> 8),
                @intCast(sni_len & 0xFF), 0x00,
            });
            try client_hello.appendSlice(hostname);
        }

        const msg_len = client_hello.items.len - 4;
        client_hello.items[1] = @intCast((msg_len >> 16) & 0xFF);
        client_hello.items[2] = @intCast((msg_len >> 8) & 0xFF);
        client_hello.items[3] = @intCast(msg_len & 0xFF);

        try self.writeRecord(RECORD_TYPE_HANDSHAKE, client_hello.items);

        const server_hello = try self.readRecord();
        defer self.allocator.free(server_hello.data);

        if (server_hello.content_type != RECORD_TYPE_HANDSHAKE) {
            std.debug.print("Unexpected message type: {d} (ASCII: {c})\n", .{ server_hello.content_type, server_hello.content_type });
            return error.UnexpectedMessage;
        }

        // Process ServerHello
        if (server_hello.data[0] != HANDSHAKE_TYPE_SERVER_HELLO) {
            std.debug.print("Unexpected handshake type: {d}\n", .{server_hello.data[0]});
            return error.UnexpectedMessage;
        }

        // TODO(Alex): Verify server certificate

        self.connected = true;
    }

    pub const Reader = std.io.Reader(*TlsStream, TlsError, read);
    pub const Writer = std.io.Writer(*TlsStream, TlsError, write);

    pub fn reader(self: *TlsStream) Reader {
        return .{ .context = self };
    }

    pub fn writer(self: *TlsStream) Writer {
        return .{ .context = self };
    }

    fn read(self: *TlsStream, buffer: []u8) TlsError!usize {
        if (!self.connected) return error.NotConnected;

        const record = try self.readRecord();
        defer self.allocator.free(record.data);

        if (record.content_type != RECORD_TYPE_APPLICATION_DATA) {
            return error.UnexpectedMessage;
        }

        const len = @min(buffer.len, record.data.len);
        @memcpy(buffer[0..len], record.data[0..len]);
        return len;
    }

    fn write(self: *TlsStream, data: []const u8) TlsError!usize {
        if (!self.connected) return error.NotConnected;
        try self.writeRecord(RECORD_TYPE_APPLICATION_DATA, data);
        return data.len;
    }
};
