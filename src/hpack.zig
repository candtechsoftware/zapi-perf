const std = @import("std");
const http2 = @import("http2.zig");
const huff = @import("huffman.zig");

/// HPACK static table as defined in RFC 7541
pub const StaticTable = struct {
    const Entry = struct {
        name: []const u8,
        value: ?[]const u8,
    };

    const entries = [_]Entry{
        .{ .name = ":authority", .value = null },
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":path", .value = "/index.html" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":status", .value = "200" },
        .{ .name = ":status", .value = "204" },
        .{ .name = ":status", .value = "206" },
        .{ .name = ":status", .value = "304" },
        .{ .name = ":status", .value = "400" },
        .{ .name = ":status", .value = "404" },
        .{ .name = ":status", .value = "500" },
        .{ .name = "accept-charset", .value = null },
        .{ .name = "accept-encoding", .value = "gzip, deflate" },
        .{ .name = "accept-language", .value = null },
        .{ .name = "accept-ranges", .value = null },
        .{ .name = "accept", .value = null },
        .{ .name = "access-control-allow-origin", .value = null },
        .{ .name = "age", .value = null },
        .{ .name = "allow", .value = null },
        .{ .name = "authorization", .value = null },
        .{ .name = "cache-control", .value = null },
        .{ .name = "content-disposition", .value = null },
        .{ .name = "content-encoding", .value = null },
        .{ .name = "content-language", .value = null },
        .{ .name = "content-length", .value = null },
        .{ .name = "content-location", .value = null },
        .{ .name = "content-range", .value = null },
        .{ .name = "content-type", .value = null },
        .{ .name = "cookie", .value = null },
        .{ .name = "date", .value = null },
        .{ .name = "etag", .value = null },
        .{ .name = "expect", .value = null },
        .{ .name = "expires", .value = null },
        .{ .name = "from", .value = null },
        .{ .name = "host", .value = null },
        .{ .name = "if-match", .value = null },
        .{ .name = "if-modified-since", .value = null },
        .{ .name = "if-none-match", .value = null },
        .{ .name = "if-range", .value = null },
        .{ .name = "if-unmodified-since", .value = null },
        .{ .name = "last-modified", .value = null },
        .{ .name = "link", .value = null },
        .{ .name = "location", .value = null },
        .{ .name = "max-forwards", .value = null },
        .{ .name = "proxy-authenticate", .value = null },
        .{ .name = "proxy-authorization", .value = null },
        .{ .name = "range", .value = null },
        .{ .name = "referer", .value = null },
        .{ .name = "refresh", .value = null },
        .{ .name = "retry-after", .value = null },
        .{ .name = "server", .value = null },
        .{ .name = "set-cookie", .value = null },
        .{ .name = "strict-transport-security", .value = null },
        .{ .name = "transfer-encoding", .value = null },
        .{ .name = "user-agent", .value = null },
        .{ .name = "vary", .value = null },
        .{ .name = "via", .value = null },
        .{ .name = "www-authenticate", .value = null },
    };

    pub fn lookup(index: usize) ?Entry {
        if (index == 0 or index > entries.len) return null;
        return entries[index - 1];
    }
};

pub const DynamicTable = struct {
    const Entry = struct {
        name: []const u8,
        value: []const u8,
        size: usize,
    };

    const MAX_SIZE: usize = 4096; // Default maximum size
    const ENTRY_OVERHEAD: usize = 32; // Per RFC 7541

    entries: std.ArrayList(Entry),
    size: usize,
    max_size: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) DynamicTable {
        return .{
            .entries = std.ArrayList(Entry).init(allocator),
            .size = 0,
            .max_size = max_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DynamicTable) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.entries.deinit();
    }

    pub fn add(self: *DynamicTable, name: []const u8, value: []const u8) !void {
        const entry_size = name.len + value.len + ENTRY_OVERHEAD;

        // Evict entries until we have space
        while (self.size + entry_size > self.max_size) {
            if (self.entries.items.len == 0) break;
            try self.evictOldest();
        }

        if (entry_size <= self.max_size) {
            const name_copy = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_copy);
            const value_copy = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(value_copy);

            try self.entries.insert(0, .{
                .name = name_copy,
                .value = value_copy,
                .size = entry_size,
            });
            self.size += entry_size;
        }
    }

    fn evictOldest(self: *DynamicTable) !void {
        if (self.entries.items.len > 0) {
            const last = self.entries.pop();
            self.size -= last.size;
            self.allocator.free(last.name);
            self.allocator.free(last.value);
        }
    }

    pub fn resize(self: *DynamicTable, new_max_size: usize) !void {
        self.max_size = new_max_size;
        while (self.size > self.max_size) {
            try self.evictOldest();
        }
    }

    pub fn getEntry(self: *DynamicTable, index: usize) ?Entry {
        if (index == 0 or index > self.entries.items.len) return null;
        return self.entries.items[index - 1];
    }
};

pub const Encoder = struct {
    dynamic_table: DynamicTable,
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    bits_left: u8 = 8,

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{
            .dynamic_table = DynamicTable.init(allocator, 4096),
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.dynamic_table.deinit();
        self.buffer.deinit();
    }

    pub fn encode(self: *Encoder, headers: []const http2.Header) !std.ArrayList(u8) {
        self.buffer.clearRetainingCapacity();

        for (headers) |header| {
            // First try static table
            var found = false;
            for (StaticTable.entries, 1..) |entry, i| {
                if (std.mem.eql(u8, entry.name, header.name)) {
                    if (entry.value) |value| {
                        if (std.mem.eql(u8, value, header.value)) {
                            try self.encodeInteger(&self.buffer, i, 7, 0x80);
                            found = true;
                            break;
                        }
                    }
                }
            }

            if (!found) {
                // Not found in static table, encode as new literal
                try self.encodeLiteralWithIndexing(&self.buffer, header);
            }
        }

        return self.buffer;
    }

    fn encodeLiteralWithIndexing(self: *Encoder, buf: *std.ArrayList(u8), header: http2.Header) !void {
        try buf.append(0x40); // Literal with incremental indexing
        try self.encodeString(buf, header.name);
        try self.encodeString(buf, header.value);
        try self.dynamic_table.add(header.name, header.value);
    }

    fn encodeString(self: *Encoder, buf: *std.ArrayList(u8), str: []const u8) !void {
        var huffman = HuffmanEncoder.init(self.allocator);
        defer huffman.deinit();

        try huffman.encode(str);
        const compressed = huffman.output.items;

        try self.encodeInteger(buf, compressed.len, 7, 0x80); // Set H bit to indicate Huffman encoding
        try buf.appendSlice(compressed);
    }

    fn encodeInteger(self: *Encoder, buf: *std.ArrayList(u8), value: usize, n: u3, prefix: u8) !void {
        _ = self;
        const mask = (@as(u8, 1) << n) - 1;
        if (value < mask) {
            try buf.append(@intCast(prefix | @as(u8, @truncate(value))));
        } else {
            try buf.append(prefix | mask);
            var remaining = value - mask;
            while (remaining >= 128) {
                try buf.append(@intCast((remaining & 0x7f) | 0x80));
                remaining >>= 7;
            }
            try buf.append(@intCast(remaining));
        }
    }
};

pub const Decoder = struct {
    dynamic_table: DynamicTable,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Decoder {
        return .{
            .dynamic_table = DynamicTable.init(allocator, 4096),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.dynamic_table.deinit();
    }

    pub fn decode(self: *Decoder, encoded: []const u8, headers: *std.ArrayList(http2.Header)) !void {
        var pos: usize = 0;
        while (pos < encoded.len) {
            const first_byte = encoded[pos];
            if ((first_byte & 0x80) != 0) {
                // Indexed Header Field
                const index = try self.decodeInteger(encoded, &pos, 7);
                if (StaticTable.lookup(index)) |entry| {
                    try headers.append(.{
                        .name = try self.allocator.dupe(u8, entry.name),
                        .value = if (entry.value) |v|
                            try self.allocator.dupe(u8, v)
                        else
                            try self.allocator.dupe(u8, ""),
                    });
                }
            } else {
                // Literal Header Field
                try self.decodeLiteral(encoded, &pos, headers);
            }
        }
    }

    fn decodeLiteral(self: *Decoder, encoded: []const u8, pos: *usize, headers: *std.ArrayList(http2.Header)) !void {
        const first_byte = encoded[pos.*];
        pos.* += 1;

        const name = try self.decodeString(encoded, pos);
        const value = try self.decodeString(encoded, pos);

        try headers.append(.{
            .name = name,
            .value = value,
        });

        if ((first_byte & 0x40) != 0) {
            try self.dynamic_table.add(name, value);
        }
    }

    fn decodeString(self: *Decoder, encoded: []const u8, pos: *usize) ![]const u8 {
        const first_byte = encoded[pos.*];
        const is_huffman = (first_byte & 0x80) != 0;
        const length = try self.decodeInteger(encoded, pos, 7);

        if (is_huffman) {
            var decoder = try HuffmanDecoder.init(self.allocator);
            defer decoder.deinit();
            const result = try decoder.decode(encoded[pos.* .. pos.* + length]);
            pos.* += length;
            return result;
        } else {
            const result = try self.allocator.dupe(u8, encoded[pos.* .. pos.* + length]);
            pos.* += length;
            return result;
        }
    }

    fn decodeInteger(self: *Decoder, encoded: []const u8, pos: *usize, n: u3) !usize {
        _ = self;
        const mask = (@as(u8, 1) << n) - 1;
        var value = @as(usize, encoded[pos.*] & mask);
        pos.* += 1;

        if (value == mask) {
            var m: u6 = 0;
            while (pos.* < encoded.len) : (pos.* += 1) {
                const b = encoded[pos.*];
                value += @as(usize, b & 0x7f) << m;
                m += 7;
                if ((b & 0x80) == 0) break;
            }
        }

        return value;
    }
};

pub const HuffmanEncoder = struct {
    bits: u64 = 0,
    bits_left: u8 = 64,
    output: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) HuffmanEncoder {
        return .{
            .output = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn encode(self: *HuffmanEncoder, str: []const u8) !void {
        for (str) |c| {
            const huf = if (c < huff.huffman_table.len and huff.huffman_table[c].bits != 0)
                huff.huffman_table[c]
            else
                huff.calculateHuffmanCode(c);

            try self.appendBits(huf.code, huf.bits);
        }
        // Pad with 1's per spec
        if (self.bits_left < 64) {
            try self.appendBits(0x7F, 7);
        }
    }

    fn appendBits(self: *HuffmanEncoder, bits: u32, num_bits: u8) !void {
        // Ensure we don't overflow our 64-bit buffer
        const shift = @as(u8, @intCast(@min(64 - self.bits_left, num_bits)));
        self.bits |= @as(u64, bits) << @as(u6, @intCast(64 - shift - self.bits_left));
        self.bits_left -|= shift; // Saturating subtraction to prevent underflow

        while (self.bits_left <= 56) {
            try self.output.append(@truncate(self.bits >> 56));
            self.bits <<= 8;
            self.bits_left = @min(64, self.bits_left + 8);
        }
    }

    pub fn deinit(self: *HuffmanEncoder) void {
        self.output.deinit();
    }
};

pub const HuffmanDecoder = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    state: u32 = 0,
    bits_left: u8 = 0,

    const DecodingTable = struct {
        value: u8,
        bits: u8,
        state: u8,
    };

    const decoding_table = [_]DecodingTable{
        // Numbers (0-9) - 8-bit encoding
        .{ .value = '0', .bits = 8, .state = 0 },
        .{ .value = '1', .bits = 8, .state = 0 },
        .{ .value = '2', .bits = 8, .state = 0 },
        .{ .value = '3', .bits = 8, .state = 0 },
        .{ .value = '4', .bits = 8, .state = 0 },
        .{ .value = '5', .bits = 8, .state = 0 },
        .{ .value = '6', .bits = 8, .state = 0 },
        .{ .value = '7', .bits = 8, .state = 0 },
        .{ .value = '8', .bits = 8, .state = 0 },
        .{ .value = '9', .bits = 8, .state = 0 },

        // Common special characters
        .{ .value = '-', .bits = 10, .state = 0 },
        .{ .value = '.', .bits = 10, .state = 0 },
        .{ .value = '/', .bits = 5, .state = 0 },
        .{ .value = ':', .bits = 8, .state = 0 },
        .{ .value = ';', .bits = 8, .state = 0 },
        .{ .value = '=', .bits = 8, .state = 0 },
        .{ .value = ' ', .bits = 8, .state = 0 },
        .{ .value = '_', .bits = 13, .state = 0 },

        // Lowercase letters (a-z) - 6-bit encoding
        .{ .value = 'a', .bits = 6, .state = 0 },
        .{ .value = 'b', .bits = 6, .state = 0 },
        .{ .value = 'c', .bits = 6, .state = 0 },
        .{ .value = 'd', .bits = 6, .state = 0 },
        .{ .value = 'e', .bits = 6, .state = 0 },
        .{ .value = 'f', .bits = 6, .state = 0 },
        .{ .value = 'g', .bits = 6, .state = 0 },
        .{ .value = 'h', .bits = 6, .state = 0 },
        .{ .value = 'i', .bits = 6, .state = 0 },
        .{ .value = 'j', .bits = 6, .state = 0 },
        .{ .value = 'k', .bits = 6, .state = 0 },
        .{ .value = 'l', .bits = 6, .state = 0 },
        .{ .value = 'm', .bits = 6, .state = 0 },
        .{ .value = 'n', .bits = 6, .state = 0 },
        .{ .value = 'o', .bits = 6, .state = 0 },
        .{ .value = 'p', .bits = 6, .state = 0 },
        .{ .value = 'q', .bits = 6, .state = 0 },
        .{ .value = 'r', .bits = 6, .state = 0 },
        .{ .value = 's', .bits = 6, .state = 0 },
        .{ .value = 't', .bits = 6, .state = 0 },
        .{ .value = 'u', .bits = 6, .state = 0 },
        .{ .value = 'v', .bits = 6, .state = 0 },
        .{ .value = 'w', .bits = 6, .state = 0 },
        .{ .value = 'x', .bits = 6, .state = 0 },
        .{ .value = 'y', .bits = 6, .state = 0 },
        .{ .value = 'z', .bits = 6, .state = 0 },

        // Uppercase letters (A-Z) - 11-bit encoding
        .{ .value = 'A', .bits = 11, .state = 0 },
        .{ .value = 'B', .bits = 11, .state = 0 },
        .{ .value = 'C', .bits = 12, .state = 0 },
        .{ .value = 'D', .bits = 12, .state = 0 },
        .{ .value = 'E', .bits = 11, .state = 0 },
        .{ .value = 'F', .bits = 12, .state = 0 },
        .{ .value = 'G', .bits = 11, .state = 0 },
        .{ .value = 'H', .bits = 11, .state = 0 },
        .{ .value = 'I', .bits = 11, .state = 0 },
        .{ .value = 'J', .bits = 12, .state = 0 },
        .{ .value = 'K', .bits = 13, .state = 0 },
        .{ .value = 'L', .bits = 13, .state = 0 },
        .{ .value = 'M', .bits = 13, .state = 0 },
        .{ .value = 'N', .bits = 13, .state = 0 },
        .{ .value = 'O', .bits = 13, .state = 0 },
        .{ .value = 'P', .bits = 13, .state = 0 },
        .{ .value = 'Q', .bits = 13, .state = 0 },
        .{ .value = 'R', .bits = 13, .state = 0 },
        .{ .value = 'S', .bits = 13, .state = 0 },
        .{ .value = 'T', .bits = 13, .state = 0 },
        .{ .value = 'U', .bits = 13, .state = 0 },
        .{ .value = 'V', .bits = 13, .state = 0 },
        .{ .value = 'W', .bits = 13, .state = 0 },
        .{ .value = 'X', .bits = 13, .state = 0 },
        .{ .value = 'Y', .bits = 13, .state = 0 },
        .{ .value = 'Z', .bits = 13, .state = 0 },

        // Special characters for HTTP headers
        .{ .value = '*', .bits = 11, .state = 0 },
        .{ .value = ',', .bits = 11, .state = 0 },
        .{ .value = '%', .bits = 11, .state = 0 },
        .{ .value = '&', .bits = 10, .state = 0 },
        .{ .value = '+', .bits = 11, .state = 0 },
        .{ .value = '!', .bits = 11, .state = 0 },
        .{ .value = '#', .bits = 15, .state = 0 },
        .{ .value = '$', .bits = 10, .state = 0 },
        .{ .value = '@', .bits = 8, .state = 0 },
        .{ .value = '[', .bits = 13, .state = 0 },
        .{ .value = ']', .bits = 13, .state = 0 },

        // Fill remaining indices (from the last used index up to 255) with the unknown character entry
    } ++ [_]DecodingTable{.{ .value = 0xFF, .bits = 8, .state = 0 }} ** (256 - 74);

    pub fn init(allocator: std.mem.Allocator) !HuffmanDecoder {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn decode(self: *HuffmanDecoder, input: []const u8) ![]u8 {
        self.buffer.clearRetainingCapacity();
        self.state = 0;
        self.bits_left = 0;

        for (input) |byte| {
            try self.decodeByte(byte);
        }

        if (self.bits_left > 0) {
            const padding: u5 = @intCast((8 - self.bits_left) % 8);
            if (padding > 0) {
                const remaining = (self.state << padding) & 0xFF;
                // Use fixed-width types and comptime operations
                const base_mask: u8 = 0x7F;
                const shift_amount: u3 = @intCast(@min(7, padding));
                const shifted_mask: u8 = base_mask >> shift_amount;

                if (remaining != shifted_mask) {
                    return error.InvalidHuffmanPadding;
                }
            }
        }

        return try self.buffer.toOwnedSlice();
    }

    fn decodeByte(self: *HuffmanDecoder, byte: u8) !void {
        self.state = (self.state << 8) | byte;
        self.bits_left += 8;

        while (self.bits_left >= 5) {
            const shift_amount = @as(u5, @truncate(self.bits_left - 8));
            const index = @as(u8, @truncate((self.state >> shift_amount) & 0xFF));
            const entry = decoding_table[index];

            if (entry.bits <= self.bits_left) {
                try self.buffer.append(entry.value);
                // Fix the shift operation by using a fixed-width integer type
                const mask_shift = @as(u5, @truncate(self.bits_left - entry.bits));
                const mask = (@as(u32, 1) << mask_shift) - 1;
                self.state = self.state & mask;
                self.bits_left -= entry.bits;
            } else {
                break;
            }
        }
    }

    pub fn deinit(self: *HuffmanDecoder) void {
        self.buffer.deinit();
    }
};
