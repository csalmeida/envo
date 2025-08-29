/// The lexer module is used specifically to run through the contents
/// of a `.env` file and tokenise sequences of bytes in preparation
/// to parsing (lexical analysis).
///
/// It will parse double or single quoted and unquoted strings values.
/// Unclosed strings will be parsed as `WORD` tokens.
/// Quoted strings will be parsed whether they are the full value of part of an unquoted value.
/// Every escaped character inside a quoted value will not be tokenised, including valid delimiters.
/// Mixed unicode values are supported.
///
/// Edge cases:
/// If someone forgets a closing quote, the tokeniser won't panic. It consumes everything until EOF, which should make the error very apparent to the programmer when they try to use the parsed values. e.g `GREETING="hello world\n` will continue parsing until another `"` is found.
///

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// Describes available token types.
/// Each type gives an indication what a group of bytes is in the file,
/// without giving it any actualy meaning beyond categorization.
pub const TokenType = enum {
  WORD,
  WHITE_SPACE,
  EQUALS,
  NEW_LINE,
  END_OF_FILE,
  DOUBLE_QUOTED_STRING,
  SINGLE_QUOTED_STRING
};

/// Used to represent each symbol found the file.
/// Contains the token type (category) and the actual byte sequence from the source.
/// Assigns the value found with the token type.
pub const Token = struct {
  type: TokenType,
  value: []const u8,
};

/// Types of errors supported during tokenisation.
pub const TokenizationError = error {
    SyntaxError,
    OutOfMemory,
};

/// Defines each kind of supported delimiter.
/// This is useful when two delimiters share the same type of token such as the new line ones.
const DelimiterType = enum {
  LF_NEW_LINE,
  CRLF_NEW_LINE,
  EQUALS,
  WHITE_SPACE,
  HASH_SIGN,
  UNKNOWN,
};

/// The mode is used to understand how the lexer should tokenise
/// delimiters and how to identify strings of characters wrapped in quotes.
const LexerMode = enum {
  NORMAL,
  SKIP,
  SINGLE_QUOTATION,
  DOUBLE_QUOTATION,
};

/// Useful to output where a tokenisation error occurs
/// and maintain the current state of the lexer.
const Lexer = struct {
  line: u16, // Limits itself to u16 as an .env file likely won't have more than 65,536 lines.
  mode: LexerMode,

  /// Matches byte to correct quotation mode.
  /// Otherwise, switches back to normal.
  fn setModeFromByte(self: *Lexer, byte: u8) void {
    switch (byte) {
      '\"' => self.mode = .DOUBLE_QUOTATION,
      '\'' => self.mode = .SINGLE_QUOTATION,
      else => self.mode = .NORMAL
    }
  }

  /// Understands which delimiter we have hit since new line can be one or multiple types.
  fn delimiterType(_: *Lexer, previous_byte: ?u8, current_byte: u8) DelimiterType {
    if (previous_byte) |prev_byte| {
      // If it's a carriage return which takes two bytes, return early:
      if (prev_byte == '\r' and current_byte == '\n') {
        return DelimiterType.CRLF_NEW_LINE;
      }
    }

    // Any other delimiter is classified here:
    switch (current_byte) {
      '\n'      => return DelimiterType.LF_NEW_LINE,
      '='       => return DelimiterType.EQUALS,
      ' ', '\t' => return DelimiterType.WHITE_SPACE, // The space and tab character are both counted as white space.
      '#'       => return DelimiterType.HASH_SIGN,
      else      => return DelimiterType.UNKNOWN,
    }
  }
  /// Determines if a quote character at the given position is escaped by backslashes.
  ///
  /// This function counts consecutive backslashes immediately preceding the quote position.
  /// If there's an odd number of backslashes, the quote is considered escaped and should
  /// be treated as a literal character rather than a string delimiter.
  ///
  /// Examples:
  /// - `\"` - Quote is escaped (1 backslash = odd)
  /// - `\\"` - Quote is NOT escaped (2 backslashes = even, so the backslashes escape each other)
  /// - `\\\"` - Quote is escaped (3 backslashes = odd)
  ///
  /// Arguments:
  /// - `contents`: The full byte sequence being tokenized
  /// - `quote_position`: The index position of the quote character to check
  ///
  /// Returns:
  /// - `true` if the quote is escaped and should be treated as a literal character
  /// - `false` if the quote is not escaped and should be treated as a string delimiter
  fn isQuoteEscaped(_: *Lexer, contents: []const u8, quote_position: usize) bool {
      if (quote_position == 0) return false;

      var backslash_count: usize = 0;
      var position = quote_position - 1;

      // Count consecutive backslashes going backward:
      while (position >= 0 and contents[position] == '\\') {
          backslash_count += 1;
          if (position == 0) break;
          position -= 1;
      }

      // Odd number of backslashes means the quote is escaped
      return (backslash_count % 2) == 1;
  }
};

/// Looks at the `.env` file contents and categorizes each piece into symbols.
/// Each symbol will have a `TokenType` and a list of tokens will be returned.
pub fn tokenise(allocator: Allocator, contents: []const u8) TokenizationError!ArrayList(Token) {
  // Mutable lexer as we update it when iterating through contents.
  var lexer = Lexer {
    .line = 1,
    .mode = .NORMAL,
  };

  // Stores all tokens in the order they were found.
  var tokens = ArrayList(Token).init(allocator);

  // Keeps track of a number of bytes to idenfity tokens that are composed of many characters.
  var bytes_accumulator = ArrayList(u8).init(allocator);

  // Contents are UTF-8 sequence of bytes containing character representation.
  // A byte might be a single character of just part of the represenation of a full character, up to 4 bytes.
  for (contents, 0..) |byte, index| {
    // If it is the last byte we want to return to normal mode.
    // In quotation mode if no closing quote was found that just becomes a word.
    const is_last_byte = (contents.len - 1) == index;

    // Previous character, might not be present if it's first character there's no previous character:
    const previous_byte: ?u8 = if (index == 0) null else contents[index - 1];

    // If the current byte is a double / single quote it means it could be a closing quote if it's not escaped.
    const is_quote_escaped: bool = lexer.isQuoteEscaped(contents, index);

    // Determines which type of delimiter we found. This might be unknown which means it's probably part of a `WORD`.
    const delimiter: DelimiterType = lexer.delimiterType(previous_byte, byte);

    // My thinking here is at this point the lexer might already be in quotation mode so we can handle the byte sequence and create a token then, what do you think?
    switch (lexer.mode) {
      .DOUBLE_QUOTATION => {
        if (byte == '\"') {
          // If this quote is being escaped it is part of the current string we are trying to wrap.
          if (is_quote_escaped) {
            try bytes_accumulator.append(byte);
          } else {
            // Add the quote to the accumulator as the first one will be there as well, we are not losing the quotes.
            try bytes_accumulator.append(byte);

            // Create the token and clear the accumulator.
            try tokens.append(Token {
              .type = .DOUBLE_QUOTED_STRING,
              .value = try allocator.dupe(u8, bytes_accumulator.items),
            });

            bytes_accumulator.clearAndFree();

            // We go back to normal as we captured the whole sequence now.
            lexer.mode = .NORMAL;
          }

          continue;
        } else {
          // Check if this is a new line byte inside a quote, just in case because we migh need to count a new line here:
          if (delimiter == .LF_NEW_LINE or delimiter == .CRLF_NEW_LINE) {
            lexer.line = lexer.line + 1;
          }

          // If we are in quotation mode and we do not need to close the string off let's keep adding to the delimiter.
          try bytes_accumulator.append(byte);
          continue;
        }
      },

      .SINGLE_QUOTATION => {
        if (byte == '\'') {
          if (is_quote_escaped) {
            try bytes_accumulator.append(byte);
          } else {
            try bytes_accumulator.append(byte);

            try tokens.append(Token {
              .type = .SINGLE_QUOTED_STRING,
              .value = try allocator.dupe(u8, bytes_accumulator.items)
            });

            bytes_accumulator.clearAndFree();

            lexer.mode = .NORMAL;
          }

          continue;
        } else {
          // Check if this is a new line byte inside a quote, just in case because we migh need to count a new line here:
          if (delimiter == .LF_NEW_LINE or delimiter == .CRLF_NEW_LINE) {
            lexer.line = lexer.line + 1;
          }

          try bytes_accumulator.append(byte);
          continue;
        }
      },

      // If the lexer finds itself in skip mode it's because a comment delimiter was picked up.
      // Here we check if the current delimiter found is a new line, this is where we stop ignoring contents and return to normal mode.
      // As a side effect the delimiter logic will handle adding the new line token to the list.
      .SKIP => {
        if (delimiter == .LF_NEW_LINE or delimiter == .CRLF_NEW_LINE) {
          lexer.mode = .NORMAL;
        } else {
          // For any other delimiter or character skip it.
          continue;
        }
      },

      else => {}
    }

    // Distinguish between tokenisable delimiters and quotes.
    const is_delimiter = (delimiter != .UNKNOWN);
    const is_quote = (byte == '\"' or byte == '\'');

    // If we hit a delimiter that can be tokenised and we are in normal mode we do the following:
    // 1. Check if we have a value in the buffer and turn it into a `WORD` token.
    // 2. Clear the accumulator so that we start collecting for the next potential work or quoted token.
    // 3. In all cases we tokenise the delimiter byte and add it to our tokens list.
    //    We want to ignore tokenising them in quotes mode as they are part of the final value in that case.
    if (is_delimiter and lexer.mode == .NORMAL) {
      if (bytes_accumulator.items.len > 0) {
        try tokens.append(Token {
          .type = .WORD,
          .value = try allocator.dupe(u8, bytes_accumulator.items), // We need to make a copy here, otherwise a free will make these unavailable.
        });

        // Clears the accumulator, not sure if it's still usable after that but we will find out.
        bytes_accumulator.clearAndFree();
      }

      // When we hit a delimiter we create a token and move on to the next iteration.
      // Otherwise add them to the accumulator.
      switch (delimiter) {
        .LF_NEW_LINE,
        .CRLF_NEW_LINE => {
          // Update lexer instance to indicate we have moved to a new line:
          lexer.line = lexer.line + 1;

          // Instantiate Token with TokenType.NEW_LINE and add it to the list when I work out what I can do with the allocator.
          const token = Token {
            .type = .NEW_LINE,
            .value = if (delimiter == .LF_NEW_LINE) "\n" else "\r\n", // We know the value we are just going to assign it.
          };

          // Then call tokens.append(token) and move to the next iteration of the loop
          try tokens.append(token);
          continue;
        },

        .EQUALS => {
          const token = Token {
            .type = .EQUALS,
            .value = "=", // We know the value we are just going to assign it.
          };

          try tokens.append(token);
          continue;
        },

        .WHITE_SPACE => {
          const token = Token {
            .type = .WHITE_SPACE,
            .value = " ",
          };

          try tokens.append(token);
          continue;
        },

        // For comments we would like to skip any characters we find until a new delimiter is found again.
        .HASH_SIGN => {
          lexer.mode = .SKIP;
          continue;
        },

        // Take no action if byte is not a delimiter:
        .UNKNOWN => {},
      }
    }

    // Given it is in normal mode we need to switch modes at that point to quoted unless its escaped:
    const is_beginning_of_quoted_string = is_quote and !is_quote_escaped and lexer.mode == .NORMAL;
    if (is_beginning_of_quoted_string) {
      // Consume any left over bytes as a word token:
      if (bytes_accumulator.items.len > 0) {
        try tokens.append(Token {
          .type = .WORD,
          .value = try allocator.dupe(u8, bytes_accumulator.items), // We need to make a copy here, otherwise a free will make these unavailable.
        });

        // Clears the accumulator, not sure if it's still usable after that but we will find out.
        bytes_accumulator.clearAndFree();
      }

      // Switches to quoted mode:
      lexer.setModeFromByte(byte);
    }

    // It did not hit a delimiter character so we add the character to the accumulator.
    // The delimiters wouldn't get added to the list because the loop does not each this stage due to the continue words right?
    try bytes_accumulator.append(byte);

    // If it's the last byte switch to normal mode.
    if (is_last_byte) {
      lexer.mode = .NORMAL;
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

  return tokens;
}

/// Since the token requires multiple allocations for each token value
/// This helper frees up all values and then the token list allocations.
pub fn freeTokens(allocator: Allocator, tokens: *ArrayList(Token)) void {
  for (tokens.items) |token| {
    switch (token.type) {
      .WORD, .DOUBLE_QUOTED_STRING, .SINGLE_QUOTED_STRING => {
          allocator.free(token.value);
      },
      else => {
        // Don't free string literals for delimiters
      }
    }
  }

  tokens.clearAndFree();
}

// TESTS
const testing = std.testing;

test "empty file" {
  const contents = "";
  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  try testing.expect(tokens.len == 1);
  try testing.expect(tokens[0].type == .END_OF_FILE);
}

test "white space only file" {
  const contents = "     \n      \n   ";
  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Expects 5 white space tokens:
  for (0..4) |index| {
   try testing.expect(tokens[index].type == .WHITE_SPACE);
  }

  try testing.expect(tokens[5].type == .NEW_LINE);

  // Expects another 6 white space tokens:
  for (6..11) |index| {
   try testing.expect(tokens[index].type == .WHITE_SPACE);
  }

  try testing.expect(tokens[12].type == .NEW_LINE);

  // Expects 3 more white space tokens.
  for (13..15) |index| {
   try testing.expect(tokens[index].type == .WHITE_SPACE);
  }
}

test "comments only file skips all comments" {
  const contents = "# Just comments\n# More comments";
  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Comments are completely skipped during tokenization, leaving only
  // the newline between them and EOF
  try testing.expect(tokens.len == 2);
  try testing.expect(tokens[0].type == .NEW_LINE);
  try testing.expect(tokens[1].type == .END_OF_FILE);
}

test "simple unquoted values" {
  const contents =
  \\DATABASE_URL=postgresql://user:pass@localhost:5432/mydb
  \\API_VERSION=v2.1.3
  \\SERVICE_NAME=my-awesome-service
  \\UNQUOTED_WITH_SPACES=this has spaces but no quotes
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // First line:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .WORD);
  try testing.expect(tokens[3].type == .NEW_LINE);

  // Second line:
  try testing.expect(tokens[4].type == .WORD);
  try testing.expect(tokens[5].type == .EQUALS);
  try testing.expect(tokens[6].type == .WORD);
  try testing.expect(tokens[7].type == .NEW_LINE);

  // Third line:
  try testing.expect(tokens[8].type  == .WORD);
  try testing.expect(tokens[9].type  == .EQUALS);
  try testing.expect(tokens[10].type == .WORD);
  try testing.expect(tokens[11].type == .NEW_LINE);

  // Fourth line:
  try testing.expect(tokens[12].type == .WORD);
  try testing.expect(tokens[13].type == .EQUALS);
  try testing.expect(tokens[14].type == .WORD);
  try testing.expect(tokens[15].type == .WHITE_SPACE);
  try testing.expect(tokens[16].type == .WORD);
  try testing.expect(tokens[17].type == .WHITE_SPACE);
  try testing.expect(tokens[18].type == .WORD);
  try testing.expect(tokens[19].type == .WHITE_SPACE);
  try testing.expect(tokens[20].type == .WORD);
  try testing.expect(tokens[21].type == .WHITE_SPACE);
  try testing.expect(tokens[22].type == .WORD);
  try testing.expect(tokens[23].type == .WHITE_SPACE);
  try testing.expect(tokens[24].type == .WORD);
  try testing.expect(tokens[25].type == .END_OF_FILE);
}

test "simple double quoted strings" {
  const contents =
  \\DATABASE_URL="postgresql://user:pass@localhost:5432/mydb"
  \\API_VERSION="v2.1.3"
  \\SERVICE_NAME="my-awesome-service"
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // First line:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[3].type == .NEW_LINE);

  // Second line:
  try testing.expect(tokens[4].type == .WORD);
  try testing.expect(tokens[5].type == .EQUALS);
  try testing.expect(tokens[6].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[7].type == .NEW_LINE);

  // Third line:
  try testing.expect(tokens[8].type  == .WORD);
  try testing.expect(tokens[9].type  == .EQUALS);
  try testing.expect(tokens[10].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[11].type == .END_OF_FILE);
}

test "simple single quoted strings" {
  const contents =
  \\DATABASE_URL='postgresql://user:pass@localhost:5432/mydb'
  \\API_VERSION='v2.1.3'
  \\SERVICE_NAME='my-awesome-service'
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // First line:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .SINGLE_QUOTED_STRING);
  try testing.expect(tokens[3].type == .NEW_LINE);

  // Second line:
  try testing.expect(tokens[4].type == .WORD);
  try testing.expect(tokens[5].type == .EQUALS);
  try testing.expect(tokens[6].type == .SINGLE_QUOTED_STRING);
  try testing.expect(tokens[7].type == .NEW_LINE);

  // Third line:
  try testing.expect(tokens[8].type  == .WORD);
  try testing.expect(tokens[9].type  == .EQUALS);
  try testing.expect(tokens[10].type == .SINGLE_QUOTED_STRING);
  try testing.expect(tokens[11].type == .END_OF_FILE);
}

test "double quoted strings with delimiters" {
  const contents =
  \\DATABASE_URL="postgresql://user:pass@localhost:5432/mydb"
  \\MESSAGE="Hello world with spaces and = equals"
  \\MULTILINE="Line 1
  \\Line 2"
  \\COMMENT_EXAMPLE="This has # hash in it"
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // First line:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[3].type == .NEW_LINE);

  // Second line:
  try testing.expect(tokens[4].type == .WORD);
  try testing.expect(tokens[5].type == .EQUALS);
  try testing.expect(tokens[6].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[7].type == .NEW_LINE);

  // Third line:
  try testing.expect(tokens[8].type == .WORD);
  try testing.expect(tokens[9].type == .EQUALS);
  try testing.expect(tokens[10].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[11].type == .NEW_LINE);

  // Fourth line:
  try testing.expect(tokens[12].type == .WORD);
  try testing.expect(tokens[13].type == .EQUALS);
  try testing.expect(tokens[14].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[15].type == .END_OF_FILE);
}

test "single quoted strings with delimiters" {
  const contents =
  \\DATABASE_URL='postgresql://user:pass@localhost:5432/mydb'
  \\MESSAGE='Hello world with spaces and = equals'
  \\MULTILINE='Line 1
  \\Line 2'
  \\COMMENT_EXAMPLE='This has # hash in it'
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // First line:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .SINGLE_QUOTED_STRING);
  try testing.expect(tokens[3].type == .NEW_LINE);

  // Second line:
  try testing.expect(tokens[4].type == .WORD);
  try testing.expect(tokens[5].type == .EQUALS);
  try testing.expect(tokens[6].type == .SINGLE_QUOTED_STRING);
  try testing.expect(tokens[7].type == .NEW_LINE);

  // Third line:
  try testing.expect(tokens[8].type == .WORD);
  try testing.expect(tokens[9].type == .EQUALS);
  try testing.expect(tokens[10].type == .SINGLE_QUOTED_STRING);
  try testing.expect(tokens[11].type == .NEW_LINE);

  // Fourth line:
  try testing.expect(tokens[12].type == .WORD);
  try testing.expect(tokens[13].type == .EQUALS);
  try testing.expect(tokens[14].type == .SINGLE_QUOTED_STRING);
  try testing.expect(tokens[15].type == .END_OF_FILE);
}

// Should have KEY as WORD, = as EQUALS, unterminated quote as WORD, and EOF:
test "unterminated double quotes result in word token" {
  const contents =
  \\KEY="never closes
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have KEY as WORD, = as EQUALS, unterminated quote as WORD, and EOF:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .WORD);
  try testing.expect(tokens[3].type == .END_OF_FILE);
}

// Should have KEY as WORD, = as EQUALS, unterminated quote as WORD, and EOF:
test "unterminated single quotes result in word token" {
  const contents =
  \\KEY='never closes
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have KEY as WORD, = as EQUALS, unterminated quote as WORD, and EOF:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .WORD);
  try testing.expect(tokens[3].type == .END_OF_FILE);
}

test "empty double quoted strings" {
  const contents =
  \\KEY=""
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have KEY as WORD, = as EQUALS, empty double quoted string, and EOF:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[3].type == .END_OF_FILE);
}

test "empty single quoted strings" {
  const contents =
  \\KEY=''
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have KEY as WORD, = as EQUALS, empty single quoted string, and EOF:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .SINGLE_QUOTED_STRING);
  try testing.expect(tokens[3].type == .END_OF_FILE);
}

test "escaped double quotes" {
  const contents =
  \\KEY="She said \"hello\""
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have KEY as WORD, = as EQUALS, double quoted string with escaped quotes, and EOF:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[3].type == .END_OF_FILE);
}

test "escaped single quotes" {
  const contents =
  \\KEY='She said \'hello\''
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have KEY as WORD, = as EQUALS, single quoted string with escaped quotes, and EOF:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .SINGLE_QUOTED_STRING);
  try testing.expect(tokens[3].type == .END_OF_FILE);
}

test "escaped backslashes in double quotes" {
  const contents =
  \\KEY="Path\\to\\file"
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have KEY as WORD, = as EQUALS, double quoted string with escaped backslashes, and EOF:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[3].type == .END_OF_FILE);
}

test "escaped backslashes in single quotes" {
  const contents =
  \\KEY='Path\\to\\file'
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have KEY as WORD, = as EQUALS, single quoted string with escaped backslashes, and EOF:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .SINGLE_QUOTED_STRING);
  try testing.expect(tokens[3].type == .END_OF_FILE);
}

test "mixed escapes in double quotes" {
  const contents =
  \\KEY="Line 1\nLine 2\tTabbed"
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have KEY as WORD, = as EQUALS, double quoted string with mixed escapes, and EOF:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[3].type == .END_OF_FILE);
}

test "mixed escapes in single quotes" {
  const contents =
  \\KEY='Line 1\nLine 2\tTabbed'
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have KEY as WORD, = as EQUALS, single quoted string with mixed escapes, and EOF:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .SINGLE_QUOTED_STRING);
  try testing.expect(tokens[3].type == .END_OF_FILE);
}

test "inline comments" {
  const contents =
  \\KEY=value # This is a comment
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);


  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .WORD);
  try testing.expect(tokens[3].type == .WHITE_SPACE);
  try testing.expect(tokens[4].type == .END_OF_FILE);
}

test "comments with quotes" {
  const contents =
  \\# This "quote" is in a comment
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should only have EOF since entire line is a comment:
  try testing.expect(tokens[0].type == .END_OF_FILE);
}

test "hash in double quoted string" {
  const contents =
  \\ PASSWORD="secret#123"
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have WHITE_SPACE, PASSWORD as WORD, = as EQUALS, double quoted string with hash, and EOF:
  try testing.expect(tokens[0].type == .WHITE_SPACE);
  try testing.expect(tokens[1].type == .WORD);
  try testing.expect(tokens[2].type == .EQUALS);
  try testing.expect(tokens[3].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[4].type == .END_OF_FILE);
}

test "hash in single quoted string" {
  const contents =
  \\ PASSWORD='secret#123'
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have WHITE_SPACE, PASSWORD as WORD, = as EQUALS, single quoted string with hash, and EOF:
  try testing.expect(tokens[0].type == .WHITE_SPACE);
  try testing.expect(tokens[1].type == .WORD);
  try testing.expect(tokens[2].type == .EQUALS);
  try testing.expect(tokens[3].type == .SINGLE_QUOTED_STRING);
  try testing.expect(tokens[4].type == .END_OF_FILE);
}

test "unquoted values with double quotes" {
  const contents =
  \\She said "hello" today
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have multiple WORD tokens with WHITE_SPACE and a DOUBLE_QUOTED_STRING:
  try testing.expect(tokens[0].type == .WORD); // She
  try testing.expect(tokens[1].type == .WHITE_SPACE);
  try testing.expect(tokens[2].type == .WORD); // said
  try testing.expect(tokens[3].type == .WHITE_SPACE);
  try testing.expect(tokens[4].type == .DOUBLE_QUOTED_STRING); // "hello"
  try testing.expect(tokens[5].type == .WHITE_SPACE);
  try testing.expect(tokens[6].type == .WORD); // today
  try testing.expect(tokens[7].type == .END_OF_FILE);
}

test "unquoted values with single quotes" {
  const contents =
  \\She said 'hello' today
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have multiple WORD tokens with WHITE_SPACE and a SINGLE_QUOTED_STRING:
  try testing.expect(tokens[0].type == .WORD); // She
  try testing.expect(tokens[1].type == .WHITE_SPACE);
  try testing.expect(tokens[2].type == .WORD); // said
  try testing.expect(tokens[3].type == .WHITE_SPACE);
  try testing.expect(tokens[4].type == .SINGLE_QUOTED_STRING); // 'hello'
  try testing.expect(tokens[5].type == .WHITE_SPACE);
  try testing.expect(tokens[6].type == .WORD); // today
  try testing.expect(tokens[7].type == .END_OF_FILE);
}

test "mixed quote types" {
  const contents =
  \\KEY="outer 'inner' quotes"
  ;

  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Should have KEY as WORD, = as EQUALS, double quoted string containing single quotes, and EOF:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[3].type == .END_OF_FILE);
}

test "supports generic unquoted array syntax" {
  const contents =
  \\KEY=["auth", "analytics"]
  ;

  // Setup allocator and tokenise:
  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  // Checks there were tokens generated:
  try testing.expect(tokens.len > 0);

  // Each bracket and comma should be a `WORD` token:
  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);
  try testing.expect(tokens[2].type == .WORD);
  try testing.expect(tokens[3].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[4].type == .WORD);
  try testing.expect(tokens[5].type == .WHITE_SPACE);
  try testing.expect(tokens[6].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[7].type == .WORD);
  try testing.expect(tokens[8].type == .END_OF_FILE);
}

test "supports generic unquoted object syntax" {
  const contents =
  \\OBJECT_VAL={ "VAR1": "VAL1", "VAR2": "VAL2", "VA31": "VAL3" }
  ;

  // Setup allocator and tokenise:
  const allocator = testing.allocator;
  var tokenList = try tokenise(allocator, contents);
  const tokens = tokenList.items;
  defer freeTokens(allocator, &tokenList);

  try testing.expect(tokens[0].type == .WORD);
  try testing.expect(tokens[1].type == .EQUALS);

  try testing.expect(tokens[2].type == .WORD); // {

  try testing.expect(tokens[3].type == .WHITE_SPACE);
  try testing.expect(tokens[4].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[5].type == .WORD);
  try testing.expect(tokens[6].type == .WHITE_SPACE);
  try testing.expect(tokens[7].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[8].type == .WORD); // ,

  try testing.expect(tokens[9].type == .WHITE_SPACE);
  try testing.expect(tokens[10].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[11].type == .WORD);
  try testing.expect(tokens[12].type == .WHITE_SPACE);
  try testing.expect(tokens[13].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[14].type == .WORD); // ,

  try testing.expect(tokens[15].type == .WHITE_SPACE);
  try testing.expect(tokens[16].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[17].type == .WORD);
  try testing.expect(tokens[18].type == .WHITE_SPACE);
  try testing.expect(tokens[19].type == .DOUBLE_QUOTED_STRING);
  try testing.expect(tokens[20].type == .WHITE_SPACE);

  try testing.expect(tokens[21].type == .WORD); // }
  try testing.expect(tokens[22].type == .END_OF_FILE);
}
