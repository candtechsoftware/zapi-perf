const std = @import("std");
const hpack = @import("hpack.zig");

pub const H2Error = error{
    FrameError,
    StreamClosed,
    CompressionError,
    ProtocolError,
    FlowControlError,
    SettingsTimeout,
    StreamRefused,
    Cancel,
    InternalError,
};

pub const FrameType = enum(u8) {
    Data = 0x0,
    Headers = 0x1,
    Priority = 0x2,
    RstStream = 0x3,
    Settings = 0x4,
    PushPromise = 0x5,
    Ping = 0x6,
    GoAway = 0x7,
    WindowUpdate = 0x8,
    Continuation = 0x9,
};

pub const FrameFlags = struct {
    pub const EndStream: u8 = 0x1;
    pub const EndHeaders: u8 = 0x4;
    pub const Padded: u8 = 0x8;
    pub const Priority: u8 = 0x20;
    pub const Ack: u8 = 0x1;
};

pub const Settings = struct {
    header_table_size: u32 = 4096,
    enable_push: bool = true,
    max_concurrent_streams: u32 = std.math.maxInt(u32),
    initial_window_size: u32 = 65535,
    max_frame_size: u32 = 16384,
    max_header_list_size: ?u32 = null,
};

pub const Stream = struct {
    id: u32,
    state: State,
    window_size: i32,
    headers: std.ArrayList(Header),
    data: std.ArrayList(u8),

    pub const State = enum {
        Idle,
        Open,
        HalfClosed,
        Closed,
    };

    pub fn init(allocator: std.mem.Allocator, id: u32) !*Stream {
        const self = try allocator.create(Stream);
        self.* = .{
            .id = id,
            .state = .Idle,
            .window_size = 65535,
            .headers = std.ArrayList(Header).init(allocator),
            .data = std.ArrayList(u8).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Stream) void {
        self.headers.deinit();
        self.data.deinit();
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    streams: std.AutoHashMap(u32, *Stream),
    settings: Settings,
    next_stream_id: u32,
    hpack_encoder: HpackEncoder,
    hpack_decoder: HpackDecoder,
    writer: std.fs.File.Writer,
    reader: std.fs.File.Reader,

    pub fn init(allocator: std.mem.Allocator, reader: std.fs.File.Reader, writer: std.fs.File.Writer) !*Connection {
        const self = try allocator.create(Connection);
        self.* = .{
            .allocator = allocator,
            .streams = std.AutoHashMap(u32, *Stream).init(allocator),
            .settings = .{},
            .next_stream_id = 1,
            .hpack_encoder = try HpackEncoder.init(allocator),
            .hpack_decoder = try HpackDecoder.init(allocator),
            .writer = writer,
            .reader = reader,
        };
        return self;
    }

    pub fn deinit(self: *Connection) void {
        var stream_it = self.streams.valueIterator();
        while (stream_it.next()) |stream| {
            stream.*.deinit();
            self.allocator.destroy(stream.*);
        }
        self.streams.deinit();
        self.hpack_encoder.deinit();
        self.hpack_decoder.deinit();
        self.allocator.destroy(self);
    }

    pub fn startStream(self: *Connection) !*Stream {
        const stream = try Stream.init(self.allocator, self.next_stream_id);
        try self.streams.put(self.next_stream_id, stream);
        self.next_stream_id += 2;
        return stream;
    }

    pub fn sendHeaders(self: *Connection, stream: *Stream, headers: []const Header, flags: u8) !void {
        var encoded = try self.hpack_encoder.encode(headers);
        defer encoded.deinit();

        const frame = [_]u8{
            @intFromEnum(FrameType.Headers),
            flags,
            0,
            0,
            0,
            @intCast((stream.id >> 24) & 0xFF), // Stream ID
            @intCast((stream.id >> 16) & 0xFF),
            @intCast((stream.id >> 8) & 0xFF),
            @intCast(stream.id & 0xFF),
        };

        try self.writer.writeAll(&frame);
        try self.writer.writeAll(encoded.items);
    }

    pub fn sendData(self: *Connection, stream: *Stream, data: []const u8, flags: u8) !void {
        const frame = [_]u8{
            @intFromEnum(FrameType.Data), // Type
            flags, // Flags
            @intCast((data.len >> 16) & 0xFF), // Length
            @intCast((data.len >> 8) & 0xFF),
            @intCast(data.len & 0xFF),
            @intCast((stream.id >> 24) & 0xFF), // Stream ID
            @intCast((stream.id >> 16) & 0xFF),
            @intCast((stream.id >> 8) & 0xFF),
            @intCast(stream.id & 0xFF),
        };

        try self.writer.writeAll(&frame);
        try self.writer.writeAll(data);
    }

    pub fn readHeaders(self: *Connection, stream: *Stream) !std.ArrayList(Header) {
        var headers = std.ArrayList(Header).init(self.allocator);
        var frame_header: [9]u8 = undefined;
        _ = try self.reader.readAll(&frame_header);

        const length = (@as(u32, frame_header[0]) << 16) | (@as(u32, frame_header[1]) << 8) | frame_header[2];
        const stream_id = (@as(u32, frame_header[5]) << 24) | (@as(u32, frame_header[6]) << 16) | (@as(u32, frame_header[7]) << 8) | frame_header[8];

        if (stream_id != stream.id) {
            return error.StreamIdMismatch;
        }

        const encoded = try self.allocator.alloc(u8, length);
        defer self.allocator.free(encoded);
        _ = try self.reader.readAll(encoded);

        try self.hpack_decoder.decode(encoded, &headers);
        try stream.headers.appendSlice(headers.items); // Store headers in stream for later use
        return headers;
    }

    pub fn readData(self: *Connection, stream: *Stream) !std.ArrayList(u8) {
        var data = std.ArrayList(u8).init(self.allocator);
        var frame_header: [9]u8 = undefined;

        while (true) {
            _ = try self.reader.readAll(&frame_header);
            const length = (@as(u32, frame_header[0]) << 16) | (@as(u32, frame_header[1]) << 8) | frame_header[2];
            const end_stream = (frame_header[3] & FrameFlags.EndStream) != 0;
            const stream_id = (@as(u32, frame_header[5]) << 24) | (@as(u32, frame_header[6]) << 16) | (@as(u32, frame_header[7]) << 8) | frame_header[8];

            if (stream_id != stream.id) return error.StreamIdMismatch;

            const chunk = try self.allocator.alloc(u8, length);
            defer self.allocator.free(chunk);
            _ = try self.reader.readAll(chunk);
            try data.appendSlice(chunk);

            if (end_stream) break;
        }

        return data;
    }
};

const HpackEncoder = struct {
    encoder: hpack.Encoder,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !HpackEncoder {
        return .{
            .encoder = hpack.Encoder.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HpackEncoder) void {
        self.encoder.deinit();
    }

    pub fn encode(self: *HpackEncoder, headers: []const Header) !std.ArrayList(u8) {
        return self.encoder.encode(headers);
    }
};

const HpackDecoder = struct {
    decoder: hpack.Decoder,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !HpackDecoder {
        return .{
            .decoder = hpack.Decoder.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HpackDecoder) void {
        self.decoder.deinit();
    }

    pub fn decode(self: *HpackDecoder, encoded: []const u8, headers: *std.ArrayList(Header)) !void {
        try self.decoder.decode(encoded, headers);
    }
};
