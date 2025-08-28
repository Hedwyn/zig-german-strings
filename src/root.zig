//! German Strings refer to a string optimization technique
//! see: https://cedardb.com/blog/german_strings/
//! German Strings are a 16 bytes container that's able to store
//! up to 12 bytes of string locally.
//! This allows short string to be processed entirely on the stack
//! First 4 bytes encide the length; if the length is superior to 12 bytes
//! the string is short, and is entirely stored in the remaining 12 bytes
//! of the struct.
//! If it is more, the string is long, and the next bytes are the 4-bytes
//! prefix of the string (to allow faster startwith/contain/equals comparison
//! even on long strings) and the 8 bytes pointer to the actual string
//! in the heap.

const std = @import("std");
const testing = std.testing;

const short_string_max_len = 12;

/// The structure of the German String when it can fit locally.
pub const ShortString = extern struct {
    len: u32,
    content: [short_string_max_len]u8,
};

const long_string_prefix_len = 4;
const german_string_max_len = 0xFFFF_FFFF;

/// The structure of the German String when it's cannot fit locally.
pub const LongString = extern struct {
    len: u32,
    prefix: [long_string_prefix_len]u8,
    ptr: [*]u8,
};

pub const GermanString = extern union {
    short: ShortString,
    long: LongString,

    /// Main init function, from a multivalue pointer
    pub fn init(string: [*]const u8, len: usize) GermanString {
        if (len > german_string_max_len) {
            @panic("German strings max len needs to fit in 32 bits");
        }
        if (len <= short_string_max_len) {
            var short_str: ShortString = undefined;
            short_str.len = @intCast(len);
            for (0..len) |i| {
                short_str.content[i] = string[i];
            }
            return .{ .short = short_str };
        }
        var long_str: LongString = undefined;
        long_str.len = @intCast(len);
        for (0..long_string_prefix_len) |i| {
            long_str.prefix[i] = string[i];
        }
        long_str.ptr = @constCast(string);
        return .{ .long = long_str };
    }

    /// Gets a slice to the actual German String content,
    /// so that it can be used like a normal string.
    /// This should be the main method to interact with the string content
    pub fn toSlice(self: GermanString) []const u8 {
        const short_str = self.short;
        const len = short_str.len;
        if (len <= short_string_max_len) {
            // short
            return short_str.content[0..len];
        }
        // long
        return self.long.ptr[0..len];
    }
    /// Whether this string is a short string
    /// Short strings feat entirely in this container
    pub inline fn isShort(self: GermanString) bool {
        return (self.short.len <= short_string_max_len);
    }

    /// Whether this string is a long string
    /// Long strings are pointing to another memory location
    pub inline fn isLong(self: GermanString) bool {
        return (self.short.len > short_string_max_len);
    }
    /// Equality comparison for german string.
    /// Does NOT consider encoding - only the raw bytes
    pub fn equals(self: GermanString, other: GermanString) bool {
        const len = self.short.len;
        if (len != other.short.len) {
            return false;
        }
        if (len <= short_string_max_len) {
            return (std.mem.eql(u8, std.mem.asBytes(&self), std.mem.asBytes(&other)));
        }
        if (!std.mem.eql(u8, &self.long.prefix, &other.long.prefix)) {
            // if (self.long.prefix != other.long.prefix) {
            return false;
        }
        return std.mem.eql(
            u8,
            self.long.ptr[short_string_max_len..len],
            other.long.ptr[short_string_max_len..len],
        );
    }

    /// Whether this string starts with the given prefix
    pub fn startsWith(self: GermanString, prefix: []const u8) bool {
        // Trivial cases
        if (prefix.len > self.short.len) {
            return false;
        }
        if (prefix.len == 0) {
            return true;
        }
        // short string case
        if (self.isShort()) {
            for (0..prefix.len) |i| {
                if (self.short.content[i] != prefix[i]) {
                    return false;
                }
            }
            return true;
        }
        // long string case: check if local prefix is enough
        for (0..long_string_prefix_len) |i| {
            if (self.long.prefix[i] != prefix[i]) {
                return false;
            }
            if (i == prefix.len - 1) {
                // we matched the whole prefix, done
                return true;
            }
        }

        // If we di not return yet we have to dereference
        // the long string to chech the remaining
        for (long_string_prefix_len..prefix.len) |i| {
            if (self.long.ptr[i] != prefix[i]) {
                return false;
            }
        }
        return true;
    }
};

test "german string size" {
    try testing.expectEqual(@sizeOf(GermanString), 16);
}

test "german string short" {
    const test_case = "Hello World";
    const short = GermanString.init(test_case, test_case.len);
    try testing.expectEqualStrings(short.toSlice(), test_case);
    try testing.expectEqual(@sizeOf(GermanString), 16);
}

test "german string long" {
    const test_case = "This sentence does not fit in a short string";
    const long = GermanString.init(test_case, test_case.len);
    try testing.expectEqualStrings(long.toSlice(), test_case);
}

test "german string long equals" {
    const test_case = "This sentence does not fit in a short string";
    const long = GermanString.init(test_case, test_case.len);
    try testing.expect(long.equals(long));
    const not_equal = "This sentence does not fit in a shor string";
    const other = GermanString.init(not_equal, not_equal.len);
    try testing.expect(!long.equals(other));
}

test "german string short equals" {
    const test_case = "Hello World";
    const short = GermanString.init(test_case, test_case.len);
    try testing.expect(short.equals(short));
    const not_equal = "Hello Worldz";
    const other = GermanString.init(not_equal, not_equal.len);
    try testing.expect(!short.equals(other));
}

test "german long string startswith" {
    const candidate = "This sentence does not fit in a short string";
    const long = GermanString.init(candidate, candidate.len);
    const TestCase = struct { prefix: []const u8, expects: bool };
    const test_cases = [_]TestCase{
        .{ .prefix = "Thiz", .expects = false },
        .{ .prefix = "This", .expects = true },
        // Transition from 4 to 5 characters is prone to errors
        // as we now have to look beyond the prefix
        .{ .prefix = "This ", .expects = true },
        .{ .prefix = "Thiss", .expects = false },

        .{ .prefix = candidate ++ "00", .expects = false },
        .{ .prefix = "", .expects = true },
        .{ .prefix = "This sentence", .expects = true },
        .{ .prefix = "This sentence", .expects = true },
        .{ .prefix = "This sentnce", .expects = false },
    };
    for (test_cases) |test_case| {
        testing.expectEqual(long.startsWith(test_case.prefix), test_case.expects) catch |e| {
            std.debug.print(
                "--> Failed: `{s}`\n with prefix:`{s}`\n: expected {}",
                .{ candidate, test_case.prefix, test_case.expects },
            );
            return e;
        };
    }
}

test "german short string startswith" {
    const candidate = "Hello World";
    const long = GermanString.init(candidate, candidate.len);
    const TestCase = struct { prefix: []const u8, expects: bool };
    const test_cases = [_]TestCase{
        .{ .prefix = "Hello", .expects = true },
        .{ .prefix = "Helzo", .expects = false },
        .{ .prefix = candidate ++ "00", .expects = false },
        .{ .prefix = "", .expects = true },
    };
    for (test_cases) |test_case| {
        testing.expectEqual(long.startsWith(test_case.prefix), test_case.expects) catch |e| {
            std.debug.print(
                "--> Failed: `{s}`\n with prefix:`{s}`\n: expected {}",
                .{ candidate, test_case.prefix, test_case.expects },
            );
            return e;
        };
    }
}
