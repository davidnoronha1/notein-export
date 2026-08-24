const std = @import("std");

pub const Value = union(enum) {
    null,
    bool: bool,
    number: f64,
    string: []const u8,
    array: []Value,
    object: []Member,

    pub fn get(self: Value, key: []const u8) ?Value {
        if (self != .object) return null;
        for (self.object) |m| {
            if (std.mem.eql(u8, m.key, key)) return m.value;
        }
        return null;
    }

    pub fn asF32(self: Value) f32 {
        return switch (self) {
            .number => |n| @floatCast(n),
            else => 0,
        };
    }

    pub fn asI64(self: Value) i64 {
        return switch (self) {
            .number => |n| @intFromFloat(n),
            else => 0,
        };
    }

    pub fn asStr(self: Value) []const u8 {
        return switch (self) {
            .string => |s| s,
            else => "",
        };
    }
};

pub const Member = struct { key: []const u8, value: Value };

pub const Error = error{ UnexpectedEnd, UnexpectedChar, InvalidNumber, InvalidEscape } || std.mem.Allocator.Error;

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    alloc: std.mem.Allocator,

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn skipWs(self: *Parser) void {
        while (self.pos < self.src.len) : (self.pos += 1) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => break,
            }
        }
    }

    fn expect(self: *Parser, c: u8) Error!void {
        if (self.peek() != c) return Error.UnexpectedChar;
        self.pos += 1;
    }

    fn parseValue(self: *Parser) Error!Value {
        self.skipWs();
        const c = self.peek() orelse return Error.UnexpectedEnd;
        return switch (c) {
            '{' => self.parseObject(),
            '[' => self.parseArray(),
            '"' => .{ .string = try self.parseString() },
            't' => {
                if (!std.mem.startsWith(u8, self.src[self.pos..], "true")) return Error.UnexpectedChar;
                self.pos += 4;
                return .{ .bool = true };
            },
            'f' => {
                if (!std.mem.startsWith(u8, self.src[self.pos..], "false")) return Error.UnexpectedChar;
                self.pos += 5;
                return .{ .bool = false };
            },
            'n' => {
                if (!std.mem.startsWith(u8, self.src[self.pos..], "null")) return Error.UnexpectedChar;
                self.pos += 4;
                return .null;
            },
            '-', '0'...'9' => .{ .number = try self.parseNumber() },
            else => Error.UnexpectedChar,
        };
    }

    fn parseObject(self: *Parser) Error!Value {
        try self.expect('{');
        var members = std.array_list.Managed(Member).init(self.alloc);
        self.skipWs();
        if (self.peek() == '}') {
            self.pos += 1;
            return .{ .object = try members.toOwnedSlice() };
        }
        while (true) {
            self.skipWs();
            const key = try self.parseString();
            self.skipWs();
            try self.expect(':');
            const value = try self.parseValue();
            try members.append(.{ .key = key, .value = value });
            self.skipWs();
            const sep = self.peek() orelse return Error.UnexpectedEnd;
            if (sep == ',') {
                self.pos += 1;
                continue;
            } else if (sep == '}') {
                self.pos += 1;
                break;
            } else return Error.UnexpectedChar;
        }
        return .{ .object = try members.toOwnedSlice() };
    }

    fn parseArray(self: *Parser) Error!Value {
        try self.expect('[');
        var items = std.array_list.Managed(Value).init(self.alloc);
        self.skipWs();
        if (self.peek() == ']') {
            self.pos += 1;
            return .{ .array = try items.toOwnedSlice() };
        }
        while (true) {
            const v = try self.parseValue();
            try items.append(v);
            self.skipWs();
            const sep = self.peek() orelse return Error.UnexpectedEnd;
            if (sep == ',') {
                self.pos += 1;
                continue;
            } else if (sep == ']') {
                self.pos += 1;
                break;
            } else return Error.UnexpectedChar;
        }
        return .{ .array = try items.toOwnedSlice() };
    }

    fn parseString(self: *Parser) Error![]const u8 {
        try self.expect('"');
        const start = self.pos;
        var has_escape = false;
        while (true) {
            const c = self.peek() orelse return Error.UnexpectedEnd;
            if (c == '"') break;
            if (c == '\\') {
                has_escape = true;
                self.pos += 2;
                continue;
            }
            self.pos += 1;
        }
        const raw = self.src[start..self.pos];
        self.pos += 1; // closing quote

        if (!has_escape) return raw;
        return try unescape(self.alloc, raw);
    }

    fn parseNumber(self: *Parser) Error!f64 {
        const start = self.pos;
        if (self.peek() == '-') self.pos += 1;
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        if (self.peek() == '.') {
            self.pos += 1;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        }
        if (self.peek() == 'e' or self.peek() == 'E') {
            self.pos += 1;
            if (self.peek() == '+' or self.peek() == '-') self.pos += 1;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        }
        return std.fmt.parseFloat(f64, self.src[start..self.pos]) catch Error.InvalidNumber;
    }
};

fn unescape(alloc: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    var out = try std.array_list.Managed(u8).initCapacity(alloc, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            const esc = raw[i + 1];
            switch (esc) {
                'n' => try out.append('\n'),
                't' => try out.append('\t'),
                'r' => try out.append('\r'),
                '"' => try out.append('"'),
                '\\' => try out.append('\\'),
                '/' => try out.append('/'),
                else => try out.append(esc),
            }
            i += 2;
        } else {
            try out.append(raw[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice();
}

pub fn parse(alloc: std.mem.Allocator, src: []const u8) Error!Value {
    var p = Parser{ .src = src, .alloc = alloc };
    return p.parseValue();
}

test "parse object with nested array and numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\{"id":"abc","width":5.5,"points":[{"x":1,"y":-2.5,"p":0.1,"action":0}]}
    );
    try std.testing.expectEqualStrings("abc", v.get("id").?.asStr());
    try std.testing.expectEqual(@as(f32, 5.5), v.get("width").?.asF32());
    const pts = v.get("points").?.array;
    try std.testing.expectEqual(@as(usize, 1), pts.len);
    try std.testing.expectEqual(@as(f32, 1), pts[0].get("x").?.asF32());
    try std.testing.expectEqual(@as(f32, -2.5), pts[0].get("y").?.asF32());
}

test "parse negative integer color" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "{\"color\":-1}");
    try std.testing.expectEqual(@as(i64, -1), v.get("color").?.asI64());
}

test "parse array of x/y points (shape style)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "[{\"x\":-0.2,\"y\":771.3},{\"x\":509.8,\"y\":771.3}]");
    try std.testing.expectEqual(@as(usize, 2), v.array.len);
}

test "parse flat object (bounds style)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "{\"bottom\":345.9175,\"left\":54.151577,\"right\":1181.6858,\"top\":233.9638}");
    try std.testing.expectEqual(@as(f32, 345.9175), v.get("bottom").?.asF32());
}

test "parse empty object and array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v1 = try parse(arena.allocator(), "{}");
    try std.testing.expectEqual(@as(usize, 0), v1.object.len);
    const v2 = try parse(arena.allocator(), "[]");
    try std.testing.expectEqual(@as(usize, 0), v2.array.len);
}
