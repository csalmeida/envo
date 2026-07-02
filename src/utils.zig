const std = @import("std");
const Allocator = std.mem.Allocator;

/// Strips surrounding quotation marks from a string value, if present.\///
/// Removes matching pairs of single quotes (`'...'`) or double quotes (`"..."`)
/// that wrap the entire value. If the value is empty, has no surrounding quotes,
/// or the quotes are mismatched, the original value is returned unchanged.\///
/// Parameters:
///   - `value`: The string slice to potentially strip quotes from.
///
/// Returns: A string slice with the outer quotes removed, or the original slice if no quotes were found.
pub fn stripQuotes(value: []const u8) []const u8 {
    const is_empty_value = value.len == 0;

    if (is_empty_value) {
        return value;
    }

    const is_wrapped_by_quotes =
        (value[0] == '\"' and value[value.len - 1] == '\"') or
        (value[0] == '\'' and value[value.len - 1] == '\'');

    // If there's quotes we grab a slice that excludes the extermeties of the string:
    if (is_wrapped_by_quotes) {
        return value[1 .. value.len - 1];
    }

    // Has no quotes, return value as is.
    return value;
}

const testing = std.testing;

test "strip quotes correctly remove quotes" {
    const content = "\"Envo\"";
    const expected = "Envo";
    const result = stripQuotes(content);
    try testing.expectEqualStrings(expected, result);
}

test "does not strip quotes that wrap characters in a sentence" {
    const content = "\"a\" and \"b\"";
    const result = stripQuotes(content);
    try testing.expectEqualStrings(content, result);
}
