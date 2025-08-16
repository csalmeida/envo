/// The lexer module is used specifically to run through the contents
/// of a `.env` file and tokenise sequences of bytes in preparation
/// to parsing.
///
/// It will parse double or single quoted and unquoted strings values.
/// Unclosed strings will be parsed as `WORD` tokens.
/// Quoted strings will be parsed whether they are the full value of part of an unquoted value.
/// Every escaped character inside a quoted value will not be tokenised, including valid delimiters.
///
/// Edge cases:
/// If someone forgets a closing quote, the tokeniser won't panic. It consumes everything until EOF, which should make the error very apparent to the programmer when they try to use the parsed values. e.g `GREETING="hello world\n` will continue parsing until another `"` is found.
///

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
  END_OF_FILE,
  DOUBLE_QUOTED_STRING,
  SINGLE_QUOTED_STRING
};

/// Used to represent each symbol found the file.
/// Contains the token type (category) and the actual byte sequence from the source.
/// Assigns the value found with the token type.
const Token = struct {
  type: TokenType,
  value: []const u8,
};

/// Types of errors supported during tokenisation.
const TokenizationError = error {
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
      '\n' => return DelimiterType.LF_NEW_LINE,
      '=' =>  return DelimiterType.EQUALS,
      ' ' =>  return DelimiterType.WHITE_SPACE,
      '#' =>  return DelimiterType.HASH_SIGN,
      else => return DelimiterType.UNKNOWN,
    }
  }
};

/// Looks at the `.env` file contents and categorizes each piece into symbols.
/// Each symbol will have a `TokenType` and a list of tokens will be returned.
pub fn tokenise(allocator: Allocator, contents: []const u8) TokenizationError![]Token {
  // Mutable lexer as we update it when iterating through contents.
  var lexer = Lexer {
    .line = 1,
    .mode = .NORMAL,
  };

  // Stores all tokens in the order they were found.
  var tokens = std.ArrayList(Token).init(allocator);

  // Keeps track of a number of bytes to idenfity tokens that are composed of many characters.
  var bytes_accumulator = std.ArrayList(u8).init(allocator);

  // Contents are UTF-8 sequence of bytes containing character representation.
  // A byte might be a single character of just part of the represenation of a full character, up to 4 bytes.
  for (contents, 0..) |byte, index| {
    // If it is the last byte we want to return to normal mode.
    // In quotation mode if no closing quote was found that just becomes a word.
    const is_last_byte = (contents.len - 1) == index;
    if (is_last_byte) {
      // If it's not a quote switch back to normal mode.
      lexer.mode = .NORMAL;
    }

    // Previous character, might not be present if it's first character there's no previous character:
    const previous_byte: ?u8 = if (index == 0) null else contents[index - 1];

    // If the current byte is a double / single quote it means it could be a closing quote if it's not escaped.
    const previous_character_is_backslash: bool = if (previous_byte) |prev_byte| prev_byte == '\\' else false;

    // Determines which type of delimiter we found. This might be unknown which means it's probably part of a `WORD`.
    const delimiter: DelimiterType = lexer.delimiterType(previous_byte, byte);

    // My thinking here is at this point the lexer might already be in quotation mode so we can handle the byte sequence and create a token then, what do you think?
    switch (lexer.mode) {
      .DOUBLE_QUOTATION => {
        if (byte == '\"') {
          // If this quote is being escaped it is part of the current string we are trying to wrap.
          if (previous_character_is_backslash) {
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
          // If we are in quotation mode and we do not need to close the string off let's keep adding to the delimiter.
          try bytes_accumulator.append(byte);
          continue;
        }
      },

      .SINGLE_QUOTATION => {
        if (byte == '\'') {
          if (previous_character_is_backslash) {
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

    // TODO: I would like to improve this code in the future but
    // for now it's just a way to say, we want to tokenise the word and flush the accumulator.
    // then we let the if statements below handle the tokenisation of delimiters.
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
    const is_beginning_of_quoted_string = is_quote and !previous_character_is_backslash and lexer.mode == .NORMAL;
    if (is_beginning_of_quoted_string) {
      // Switches back to normal mode:
      lexer.setModeFromByte(byte);
    }

    // It did not hit a delimiter character so we add the character to the accumulator.
    // The delimiters wouldn't get added to the list because the loop does not each this stage due to the continue words right?
    try bytes_accumulator.append(byte);
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
