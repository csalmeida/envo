/// A Parser is a software able to decide whether or not a string respects a Grammar rules, and hence belongs or not to a Language.
///
/// Built to receive a token sequence from the `.env` lexer
/// and enforce grammatical rules to make sense of the available tokens and their order.
/// Grammar definition.
///
/// This parser implements a true LL(1) parser:
/// - Reads tokens from left to right.
/// - Left-most non-terminals are expanded first.
/// - Can look one token ahead.
/// - Mathematically LL(1) with no ambiguous productions.
///
/// Full grammar:
/// <FILE_CONTENTS> ::= NEW_LINE* <STATEMENT>* END_OF_FILE
/// <STATEMENT> ::= <ASSIGNMENT> WHITE_SPACE* NEW_LINE+
/// <ASSIGNMENT> ::= <IDENTIFIER> WHITE_SPACE* EQUALS WHITE_SPACE* <VALUE>
/// <IDENTIFIER> ::= WORD
/// <VALUE> ::= <MIXED_CONTENT> | ε
/// <MIXED_CONTENT> ::= <VALUE_TOKEN> (WHITE_SPACE* <VALUE_TOKEN>)*
/// <VALUE_TOKEN> ::= WORD | DOUBLE_QUOTED_STRING | SINGLE_QUOTED_STRING
///
/// LL(1) Properties:
///
/// FIRST sets:
/// - FIRST(<VALUE>) = {WORD, DOUBLE_QUOTED_STRING, SINGLE_QUOTED_STRING, ε}
/// - FIRST(<MIXED_CONTENT>) = {WORD, DOUBLE_QUOTED_STRING, SINGLE_QUOTED_STRING}
///
/// At the <VALUE> decision point:
/// - If current token is WORD, DOUBLE_QUOTED_STRING, or SINGLE_QUOTED_STRING → choose <MIXED_CONTENT>
/// - If current token is anything else (NEW_LINE, END_OF_FILE) → choose ε (empty value)
///
/// This unified approach handles all value types through <MIXED_CONTENT>:
/// - Single quoted strings: KEY="value"
/// - Single unquoted words: KEY=value
/// - Mixed content: KEY=word "quoted" more
///
/// The parser achieves most LL(1) properties: no FIRST set conflicts, single lookahead
/// sufficient for all decisions, no left recursion, and a deterministic parse table.

const std = @import("std");
const lexer = @import("lexer.zig");

const parse_rd = @import("strategies/recursive_descent.zig");
const parse_it = @import("strategies/iterative.zig");

const Allocator = std.mem.Allocator;
pub const ASTArrayList = std.ArrayList(ASTNode);

const Token = lexer.Token;
const TokenType = lexer.TokenType;
const TokenArrayList = std.ArrayList(Token);

const ParseStrategy = enum {
  RECURSIVE_DESCENT,
  ITERATIVE
};

const NoNTerminalSymbol = enum {
  FILE_CONTENTS,
  STATEMENT,
  ASSIGNMENT,
  IDENTIFIER,
  VALUE,
  MIXED_CONTENT,
  VALUE_TOKEN,
};

pub const ASTNodeType = NoNTerminalSymbol;

/// Represents a node in the Abstract Syntax Tree (AST).
///
/// An ASTNode forms the fundamental building block of the parse tree generated
/// during the parsing process. The complete AST is formed as a tree structure
/// of interconnected ASTNodes, accessed from a root node (typically FILE_CONTENTS)
/// which contains children nodes, which in turn may have their own children,
/// creating a hierarchical representation of the parsed input.
///
/// Each node represents a non-terminal symbol from the grammar. While traditional
/// parse trees include both terminal symbols (tokens) and non-terminal symbols,
/// this AST abstracts away the raw terminal tokens and represents only the
/// conceptual grammar rules (non-terminals). However, for convenience, some
/// internal nodes may store the terminal token values directly in their `value`
/// field (such as IDENTIFIER storing the actual identifier text) to provide
/// easier access without requiring traversal to leaf nodes.
///
/// The AST provides a hierarchical representation of the parsed input that
/// abstracts away syntactic details (like whitespace and punctuation) while
/// preserving the semantic structure needed for further processing.
///
/// Tree Structure:
///   - Internal nodes represent grammar rules with one or more children
///   - Leaf nodes represent the lowest-level grammar constructs with no children
///   - All nodes contain only non-terminal symbols from the grammar
///   - Terminal symbols (tokens) are abstracted away but their values preserved
///
/// Fields:
///   type: The grammatical symbol this node represents (from ASTNodeType enum)
///   value: The string content associated with this node (empty for structural nodes,
///          populated for nodes that capture terminal values like IDENTIFIER)
///   children: Array of child nodes (empty for leaf nodes)
///
/// Memory Management:
///   All fields use memory allocated from the parser's arena allocator and
///   should not be manually freed, instead
/// the caller can use their defined area for bulk deallocation when parsing is complete.
pub const ASTNode = struct {
  type: ASTNodeType,
  value: []const u8,
  children: []ASTNode
};

pub const ParseError = error {
  UnexpectedToken
} || lexer.TokenizationError;

pub const Parser = struct {
  currentTokenPosition: usize, // Current token the parser is looking at.
  tokens: []Token, // Terminal symbols received from lexical analysis.
  allocator: Allocator, // Required to maintain lists.

  /// Initializes a new Parser instance with the provided allocator and tokens.
  ///
  /// The allocator should be an arena allocator that will be used for all memory
  /// allocations during parsing, including AST node creation and string duplication.
  /// Using an arena allocator allows for efficient bulk deallocation of all parser
  /// memory when parsing is complete.
  ///
  /// Parameters:
  ///   allocator: An arena allocator for parser memory management
  ///   tokens: Slice of tokens from the lexical analysis phase
  ///
  /// Returns: A new Parser instance ready to begin parsing
  pub fn init(allocator: Allocator, tokens: []Token) Parser {
      return Parser {
          .currentTokenPosition = 0,
          .tokens = tokens,
          .allocator = allocator
      };
  }

  /// Returns the terminal token at the current parser position.
  /// The current position is tracked by `currentTokenPosition` and advances
  /// as the parser consumes tokens during parsing.
  pub fn currentToken(self: *Parser) Token {
    return self.tokens[self.currentTokenPosition];
  }

  /// Advances the parser to the next token in the sequence.
  ///
  /// This method increments the current token position, allowing the parser
  /// to move forward through the token stream during parsing operations.
  /// After calling this method, `currentToken()` will return the next token
  /// in the sequence.
  fn advance(self: *Parser) void {
    self.currentTokenPosition += 1;
  }

  /// Checks that the expected token is being used in the defined grammar.
  /// When successful it advances the token position for the parser to be able to look at the next token.
  /// Returns an error if token breaks the expected pattern for a production.
  pub fn expect(self: *Parser, expected_token_type: TokenType) ParseError!Token {
    const current_token = self.currentToken();
    if (current_token.type == expected_token_type) {
      // Even though .advance() changes the .currentToken() result we can return current_token it has not changed since.
      self.advance();
      return current_token;
    }

    return ParseError.UnexpectedToken;
  }

  /// Creates an empty children array for AST leaf nodes.
  ///
  /// This method allocates a zero-length slice of ASTNode to represent
  /// an empty children array for leaf nodes in the Abstract Syntax Tree.
  /// Leaf nodes are terminal nodes that have no child nodes beneath them
  /// in the tree structure.
  ///
  /// Returns: An empty slice of ASTNode with zero capacity
  /// Errors: Returns allocation errors if memory allocation fails
  pub fn emptyChildren(self: *Parser) ![]ASTNode {
      return try self.allocator.alloc(ASTNode, 0);
  }

  /// Entry point for the recursive descent parsing strategy.
  ///
  /// This method initiates the recursive descent parsing process by starting
  /// at the top-level grammar rule (FILE_CONTENTS) and recursively parsing
  /// the token stream according to the defined grammar rules.
  ///
  /// Recursive descent parsing works by:
  /// - Starting with the root non-terminal symbol
  /// - For each non-terminal, calling the corresponding parse method
  /// - Each parse method handles one grammar rule and calls other parse methods for sub-rules
  /// - Building the AST from the top down as each method creates its node and adds children
  ///
  /// Uses the call stack but safe to use for most cases.
  ///
  /// Returns: The root ASTNode representing the entire parsed file structure
  /// Errors: Returns ParseError if the token stream doesn't match the grammar
  fn parseRecursiveDescent(self: *Parser) !ASTNode {
    const ast_root_node = try parse_rd.parse(self);
    return ast_root_node;
  }

  /// Entry point for the iterative parsing strategy.
  ///
  /// This method initiates an iterative parsing process by instantiating and managing its own call stack stored on the heap.
  /// It enforces grammar and processes tokens building a tree of ASTNodes.
  fn parseIterative(self: *Parser) !ASTNode {
    const ast_root_node = try parse_it.parse(self);
    return ast_root_node;
  }
};

/// Receives the contents of a file and returns an Abstract Syntax Tree of the input.
/// If the structure is not compatible with the grammar it will fail and throw an error.
pub fn parse(allocator: Allocator, contents: []const u8) !ASTNode {
  // Turns contents into tokens:
  var tokens = try lexer.tokenise(allocator, contents);
  defer lexer.freeTokens(allocator, &tokens);

  var parser = Parser.init(allocator, tokens.items);

  // Pick a strategy from the available ones.
  const strategy = ParseStrategy.ITERATIVE;
  switch (strategy) {
      .RECURSIVE_DESCENT => return try parser.parseRecursiveDescent(),
      .ITERATIVE => return try parser.parseIterative(),
  }
}
