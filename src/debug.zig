const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

const Allocator = std.mem.Allocator;

// Helper function to print AST nodes recursively
pub fn printASTNode(node: parser.ASTNode, indent: u32) void {
  // Print indentation
  for (0..indent) |_| {
    std.debug.print("  ", .{});
  }

  // Print node type and value
  std.debug.print("{s}", .{@tagName(node.type)});
  if (node.value.len > 0) {
    std.debug.print(": \"{s}\"", .{node.value});
  }
  std.debug.print("\n", .{});

  // Print children
  for (node.children) |child| {
    printASTNode(child, indent + 1);
  }
}

pub fn parse(allocator: Allocator, contents: []const u8) !void {
  const ast: parser.ASTNode = try parser.parse(allocator, .ITERATIVE ,contents);

  std.debug.print("\n=== AST ===\n", .{});
  printASTNode(ast, 0);
  std.debug.print("===========\n", .{});
}

pub fn tokenise(allocator: Allocator, contents: []const u8) !void {
  var tokens = try lexer.tokenise(allocator, contents);
  defer lexer.freeTokens(allocator, &tokens);

  for (tokens.items) |token| {
    std.debug.print("\n", .{});
    std.debug.print("Token: {s} = \"{s}\" at line: {any}, at col: {any}", .{ @tagName(token.type), token.value, token.line, token.column });
    std.debug.print("\n", .{});
  }
}
