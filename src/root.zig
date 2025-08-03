const std = @import("std");

const Allocator = std.mem.Allocator;

// Read a file of a path:
// Caller needs to call `defer allocator.free(contents);` to free memory.
pub fn loadFile(allocator: Allocator, file_path: []const u8) ![]u8 {
  const cwd = std.fs.cwd();

  // To read all the file we need to define the max size for it, pass the path where to look for the file and allocate it to memory.
  const max_file_size: usize = 1_000_000; // 1mb.
  const contents = try cwd.readFileAlloc(allocator, file_path, max_file_size);

  return contents;
}
