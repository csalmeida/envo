/// The lexer module is used specifically to run through the contents
/// of a `.env` file and tokenise sequences of bytes in preparation
/// to parsing.

// 1. Re-factor to be able to detect wrappers via an accumulator.
// 2. We have to be able to find an initial \" and peek to find the closing one, this can be on the same line or another line.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Describes available token types.
/// Each type gives an indication what a group of bytes is in the file,
/// without giving it any actualy meaning beyond categorization.
const TokenType = enum {
  WORD,
  WHITE_SPACE,
  EQUALS,
  NEW_LINE,
  END_OF_FILE
};

// Assigns the value found with the token type.
const Token = struct {
  type: TokenType,
  value: []const u8,
};

/// Types of errors supported during tokenisation.
const TokenizationError = error {
    SyntaxError,
    OutOfMemory,
};

/// Useful to output where a tokenisation error occurs.
const Lexer = struct {
  line: u16, // Limits itself to u16 as an .env file likely won't have more than 65,536 lines.
};

/// Looks at the `.env` file contents and categorizes each piece into symbols.
/// Each symbol will have a `TokenType` and a list of tokens will be returned.
pub fn tokenise(allocator: Allocator, contents: []const u8) TokenizationError![]Token {
  // Mutable lexer as we update it when iterating through contents.
  var lexer = Lexer {
    .line = 1,
  };

  // Stores all tokens in the order they were found.
  var tokens = std.ArrayList(Token).init(allocator);

  // Keeps track of a number of bytes to idenfity tokens that are composed of many characters.
  var bytes_accumulator = std.ArrayList(u8).init(allocator);

  // Contents are UTF-8 sequence of bytes containing character representation.
  // A byte might be a single character of just part of the represenation of a full character, up to 4 bytes.
  for (contents) |byte| {
    // TODO: I would like to improve this code in the future but
    // for now it's just a way to say, we want to tokenise the word and flush the accumulator.
    // then we let the if statements below handle the tokenisation of delimiters.
    const is_delimiter = (byte == '\n' or byte == '=' or byte == ' ');
    if (is_delimiter and bytes_accumulator.items.len > 0) {
      try tokens.append(Token {
        .type = .WORD,
        .value = try allocator.dupe(u8, bytes_accumulator.items), // We need to make a copy here, otherwise a free will make these unavailable.
      });

      // Clears the accumulator, not sure if it's still usable after that but we will find out.
      bytes_accumulator.clearAndFree();
    }

    // When we hit a delimiter we create a token and move on to the next iteration.
    // Otherwise add them to the accumulator.
    // TODO: In the future, peek ahead to address `\r` and `\r\n` cases.
    // Don't worry about it now.
    switch (byte) {
      '\n' => {
        // Update lexer instance to indicate we have moved to a new line:
        lexer.line = lexer.line + 1;

        // Instantiate Token with TokenType.NEW_LINE and add it to the list when I work out what I can do with the allocator.
        const token = Token {
          .type = .NEW_LINE,
          .value = "\n", // We know the value we are just going to assign it.
        };

        // Then call tokens.append(token) and move to the next iteration of the loop
        try tokens.append(token);
        continue;
      },

      '=' => {
        const token = Token {
          .type = .EQUALS,
          .value = "=", // We know the value we are just going to assign it.
        };

        try tokens.append(token);
        continue;
      },

      ' ' => {
        const token = Token {
          .type = .WHITE_SPACE,
          .value = " ",
        };

        try tokens.append(token);
        continue;
      },

      // It did not hit a delimiter character so we add the character to the accumulator.
      // The delimiters wouldn't get added to the list because the loop does not each this stage due to the continue words right?
      else => try bytes_accumulator.append(byte),
    }
  }

  // At this point the file probably reached the end, we can check if there's another word in the accumulator and then flush it one last time.
  if (bytes_accumulator.items.len > 0) {
    try tokens.append(Token {
      .type = .WORD,
      .value = try allocator.dupe(u8, bytes_accumulator.items),
    });

    bytes_accumulator.clearAndFree();
  }

  // Once we are done iterating through all characters we add a EOF token and return the list.
  try tokens.append(
    Token{
      .type = TokenType.END_OF_FILE,
      .value = "",
    }
  );

  return tokens.items;
}
