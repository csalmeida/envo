const std = @import("std");
const prsr = @import("../parser.zig");

const Parser = prsr.Parser;
const ASTNode = prsr.ASTNode;
const ASTArrayList = prsr.ASTArrayList;
const ParseError = prsr.ParseError;

/// Parses a grammar rule:
/// <FILE_CONTENTS> ::= NEW_LINE* <STATEMENT>* END_OF_FILE
pub fn parseFileContents(parser: *Parser) !ASTNode {
    var children_nodes: ASTArrayList = .empty;

    // Consume any leading blank lines before looking for statements:
    while (parser.currentToken().type == .NEW_LINE) {
        _ = try parser.expect(.NEW_LINE);
    }

    while (parser.currentToken().type != .END_OF_FILE) {
        // Consume leading whitespace
        while (parser.currentToken().type == .WHITE_SPACE) {
            _ = try parser.expect(.WHITE_SPACE);
        }

        // If we hit a newline, it's a whitespace-only line - consume and continue
        if (parser.currentToken().type == .NEW_LINE) {
            _ = try parser.expect(.NEW_LINE);
            continue;
        }

        // Otherwise parse as normal statement
        const statement_ast_node = try parseStatement(parser);
        try children_nodes.append(parser.allocator, statement_ast_node);
    }

    // Once all the potential available statements are done, we expect EOF.
    _ = try parser.expect(.END_OF_FILE);

    return ASTNode {
        .type = .FILE_CONTENTS,
        .value = "",
        .children = children_nodes.items,
    };
}

/// Parses a grammar rule:
/// <STATEMENT> ::= <ASSIGNMENT> (WHITE_SPACE)* NEW_LINE+
fn parseStatement(parser: *Parser) !ASTNode {
  // Attempt to parse an assignment:
  const assignment_ast_node = try parseAssignment(parser);

  // Allocate some memory for the list of children, in this case a single assignment:
  var children = try parser.allocator.alloc(ASTNode, 1);
  children[0] = assignment_ast_node;

  // Ignore any trailing .WHITE_SPACE by advancing until we find a `.NEW_LINE`:
  while (parser.currentToken().type == .WHITE_SPACE) {
    _ = try parser.expect(.WHITE_SPACE);
  }

  // An assignment ends with a new line.
  _ = try parser.expect(.NEW_LINE);

  // Ignores any other new lines:
  while (parser.currentToken().type == .NEW_LINE) {
    _ = try parser.expect(.NEW_LINE);
  }

  return ASTNode {
    .type = .STATEMENT,
    .value = "",
    .children = children,
  };
}

/// Parses a grammar rule:
/// <ASSIGNMENT> ::= <IDENTIFIER> (WHITE_SPACE)* EQUALS (WHITE_SPACE)* <VALUE>
fn parseAssignment(parser: *Parser) !ASTNode {
  const identifier_ast_node = try parseIdentifier(parser);

  // We expect and consume whitespace tokens between the identifier and equals sign.
  // These whitespace tokens are purely syntactic sugar for readability and don't carry
  // semantic meaning in the assignment operation, so they are not included in the AST.
  // The AST focuses on the logical structure (identifier = value) rather than formatting details.
  while (parser.currentToken().type == .WHITE_SPACE) {
    _ = try parser.expect(.WHITE_SPACE);
  }

  // At this point there should be an equal sign if this is an assignment.
  // We don't add the equals to the AST since we know this is an assignment.
  _ = try parser.expect(.EQUALS);

  // There could be more spaces after the equal sign.
  // These are accepted but won't be part of the tree either.
  while (parser.currentToken().type == .WHITE_SPACE) {
    _ = try parser.expect(.WHITE_SPACE);
  }

  // Attempt to parse the value portion of the statement.
  const value_ast_node = try parseValue(parser);

  // Create the children nodes array:
  var children = try parser.allocator.alloc(ASTNode, 2);
  children[0] = identifier_ast_node;
  children[1] = value_ast_node;

  // We return the assignment AST node with the respective identifier and value non-terminal nodes.
  return ASTNode {
    .type = .ASSIGNMENT,
    .value = "",
    .children = children
  };
}

/// Parses a grammar rule:
/// <IDENTIFIER> ::= WORD
/// On pattern match, one non-terminal .IDENTIFIER node is returned and we abstract the `.WORD` terminal.
fn parseIdentifier(parser: *Parser) !ASTNode {
  const token = try parser.expect(.WORD);

  return ASTNode {
    .type = .IDENTIFIER,
    .value = try parser.allocator.dupe(u8, token.value),
    .children = try parser.emptyChildren()
  };
}

/// Parses a grammar rule:
/// <VALUE> ::= <MIXED_CONTENT> | ε
fn parseValue(parser: *Parser) !ASTNode {
  const token = parser.currentToken();
  switch (token.type) {
    .WORD, .DOUBLE_QUOTED_STRING, .SINGLE_QUOTED_STRING => {
      const mixed_content_ast_node = try parseMixedContent(parser);
      var children = try parser.allocator.alloc(ASTNode, 1);
      children[0] = mixed_content_ast_node;

      return ASTNode {
        .type = .VALUE,
        .value = try parser.allocator.dupe(u8, mixed_content_ast_node.value),
        .children = children
      };
    },
    else => {
      // If it's not either of those it must be an empty value:
      return ASTNode {
        .type = .VALUE,
        .value = "",
        .children = try parser.emptyChildren()
      };
    }
  }
}

/// Parses a grammar rule:
/// <MIXED_CONTENT> ::= <VALUE_TOKEN> (WHITE_SPACE* <VALUE_TOKEN>)*
fn parseMixedContent(parser: *Parser) !ASTNode {
  // We do not want to free complete_value or children now - the arena allocator will be freed later by the caller
  // when they're done with the AST, which will free all tokens, ASTNodes, and other allocated values.
  var complete_value: std.ArrayList(u8) = .empty;

  // A <MIXED_CONTENT> can have multiple <VALUE_TOKEN> ASTNodes:
  var children: std.ArrayList(ASTNode) = .empty;

  // Attempt to find a value token:
  const first_value_token = try parseValueToken(parser);
  // Append it to our final string:
  try complete_value.appendSlice(parser.allocator, first_value_token.value);

  // Add value token as a child:
  try children.append(parser.allocator, first_value_token);

  // Keep parsing the remaining value tokens and white space.
  while (true) {
    // Step 1: While there's spaces after the first word we want to consume those:
    // WHITE_SPACE* ← zero or more spaces
    while (parser.currentToken().type == .WHITE_SPACE) {
      const white_space_token = try parser.expect(.WHITE_SPACE);
      try complete_value.appendSlice(parser.allocator, white_space_token.value);
    }

    // Check if we can parse another VALUE_TOKEN
    const current_token = parser.currentToken();

    const is_value_token_terminal = current_token.type == .WORD or
        current_token.type == .DOUBLE_QUOTED_STRING or
        current_token.type == .SINGLE_QUOTED_STRING;

    if (is_value_token_terminal) {
        // Collect the value token:
        const value_token = try parseValueToken(parser);
        try complete_value.appendSlice(parser.allocator, value_token.value);

        // Add value token as a child:
        try children.append(parser.allocator, value_token);
    } else {
        // No more VALUE_TOKENs, exit the loop
        break;
    }
  }

  // Return the whole unquoted string:
  return ASTNode {
    .type = .MIXED_CONTENT,
    .value = try parser.allocator.dupe(u8, complete_value.items),
    .children = children.items,
  };
}

/// Parses a grammar rule:
/// <VALUE_TOKEN> ::= WORD | DOUBLE_QUOTED_STRING | SINGLE_QUOTED_STRING
fn parseValueToken(parser: *Parser) !ASTNode {
  const token = parser.currentToken();

  switch (token.type) {
    .WORD, .DOUBLE_QUOTED_STRING, .SINGLE_QUOTED_STRING => {
      _ = try parser.expect(token.type);
    },
    else => {
      return ParseError.UnexpectedToken;
    }
  }

  return ASTNode {
    .type = .VALUE_TOKEN,
    .value = try parser.allocator.dupe(u8, token.value),
    .children = try parser.emptyChildren()
  };
}
