const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;
const ASTNode = parser.ASTNode;
const ParseStrategy = parser.ParseStrategy;
const EnvHashMap = std.StringHashMap([]const u8);

/// Reads the entire contents of a file at the given path into a newly allocated buffer
///
/// Parameters:
///   - `allocator`: The memory allocator used for allocating the file contents buffer.
///   - `file_path`: The relative or absolute path to the file to read.
///
/// Returns: A byte slice containing the full contents of the file.
///
/// Errors: Returns an error if the file cannot be opened, read, or exceeds the maximum file size (1 MB).
///
/// Note: The caller is responsible for freeing the returned buffer with `defer allocator.free(contents);`.
pub fn loadFile(io: std.Io, allocator: Allocator, file_path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();

    // To read all the file we need to define the max size for it, pass the path where to look for the file and allocate it to memory.
    const max_file_size: usize = 1024 * 1024; // 1mb.
    const contents = try cwd.readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(max_file_size));

    return contents;
}

/// Parses the given source contents using the specified strategy and returns a raw AST (Abstract Syntax Tree).
///
/// Parameters:
///   - `allocator`: The memory allocator used for allocating AST nodes and intermediate parse data.
///   - `strategy`: The parsing strategy to use (determines how the input is interpreted).
///   - `contents`: The raw source contents to parse.
///
/// Returns: An `ASTNode` representing the root of the parsed abstract syntax tree.
///\/// Errors: Returns an error if parsing fails (e.g., due to invalid syntax in `contents`).
pub fn ast(allocator: Allocator, strategy: ParseStrategy, contents: []const u8) !ASTNode {
    const abstract_syntax_tree: ASTNode = try parser.parse(allocator, strategy, contents);
    return abstract_syntax_tree;
}

/// Parses the given source contents using the specified strategy and returns a hash map of environment key-value pairs.
///\/// Parameters:
///   - `allocator`: The memory allocator used for allocating AST nodes, intermediate parse data, and duplicated key-value strings.
///   - `strategy`: The parsing strategy to use (determines how the input is interpreted).
///   - `contents`: The raw source contents to parse.
///
/// Returns: An `EnvHashMap` (`StringHashMap([]const u8)`) containing the parsed environment variable key-value pairs.
///
/// Errors: Returns an error if parsing fails (e.g., due to invalid syntax in `contents`) or if memory allocation fails.
///
/// Note: The caller is responsible for freeing the returned hash map and its allocated keys/values.
pub fn parse(allocator: Allocator, strategy: ParseStrategy, contents: []const u8) !EnvHashMap {
    const abstract_syntax_tree: ASTNode = try parser.parse(allocator, strategy, contents);
    var env_data = std.StringHashMap([]const u8).init(allocator);

    // Iterate through each statement node in the tree.
    // Access the first assignment node and get the identifier (key) and value.
    // These need to be reallocated so we can access them later and added to the hash map.
    for (abstract_syntax_tree.children) |ast_node| {
        const identifier = try allocator.dupe(u8, ast_node.children[0].children[0].value);
        const value = try allocator.dupe(u8, ast_node.children[0].children[1].value);

        // Add the pair to the hash map.
        // It will transform quoted values as a side effect.
        try env_data.put(identifier, utils.stripQuotes(value));
    }

    return env_data;
}
