const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

const Allocator = std.mem.Allocator;
const ASTNode = parser.ASTNode;
const ParseStrategy = parser.ParseStrategy;

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
pub fn loadFile(allocator: Allocator, file_path: []const u8) ![]u8 {
  const cwd = std.fs.cwd();

  // To read all the file we need to define the max size for it, pass the path where to look for the file and allocate it to memory.
  const max_file_size: usize = 1024 * 1024; // 1mb.
  const contents = try cwd.readFileAlloc(allocator, file_path, max_file_size);

  return contents;
}

/// Parses the given source contents using the specified strategy and returns an AST (Abstract Syntax Tree).
///
/// Parameters:
///   - `allocator`: The memory allocator used for allocating AST nodes and intermediate parse data.
///   - `strategy`: The parsing strategy to use (determines how the input is interpreted).
///   - `contents`: The raw source contents to parse.
///
/// Returns: An `ASTNode` representing the root of the parsed abstract syntax tree.
///
/// Errors: Returns an error if parsing fails (e.g., due to invalid syntax in `contents`).
pub fn parse(allocator: Allocator, strategy: ParseStrategy, contents: []const u8) !ASTNode {
  const ast: ASTNode = try parser.parse(allocator, strategy, contents);
  return ast;
}
