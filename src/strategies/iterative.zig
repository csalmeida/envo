/// The iterative parsing strategy for the `.env` parser. 
/// Builds an Abstract Syntax Tree using a managed call stack
/// allocated to the heap.
///
/// The call stack holds managed stack frames that hold the state of the parsing.
/// Handler functions validate tokens and results in ASTNodes.
///
/// Allocating to the heap should allow much larger files to be processed.
///
/// ## Grammar Rules
/// - `<FILE_CONTENTS>` ::= NEW_LINE* `<STATEMENT>`* END_OF_FILE
/// - `<STATEMENT>` ::= `<ASSIGNMENT>` (WHITE_SPACE)* NEW_LINE+
/// - `<ASSIGNMENT>` ::= `<IDENTIFIER>` (WHITE_SPACE)* EQUALS (WHITE_SPACE)* `<VALUE>`
/// - `<IDENTIFIER>` ::= WORD
/// - `<VALUE>` ::= `<MIXED_CONTENT>` | ε
/// - `<MIXED_CONTENT>` ::= `<VALUE_TOKEN>` (WHITE_SPACE* `<VALUE_TOKEN>`)*
/// - `<VALUE_TOKEN>` ::= WORD | DOUBLE_QUOTED_STRING | SINGLE_QUOTED_STRING
///
/// ## Core Components
/// - `StackFrame`: Represents the state of a single production being parsed,
///    including step tracking, accumulated bytes, child nodes, and a value slice. 
/// - `CallStack`: Manages the stack of `StackFrame`s, handling push/pop operations
///    and storing the root `ASTNode` result once parsing completes.
/// - `parse`: The entry point that initializes the stack with a `FILE_CONTENTS` frame
///    and iteratively dispatches each production to its handler until the stack is empty.

const std = @import("std");
const prsr = @import("../parser.zig");

const Allocator = std.mem.Allocator;

// Types used in parsing, shared across strategies.
const Parser = prsr.Parser;
const ASTNode = prsr.ASTNode;
const ASTArrayList = prsr.ASTArrayList;
const ParseError = prsr.ParseError;
const ASTNodeType = prsr.ASTNodeType;

/// A `StackFrame` is used to manually keep the state of parsing a production.
/// The step tracking is useful when required to jump to another frame and then come back to it.
/// The nodes list form a tree that will ultimately result in the final output of the parsing stage.
/// There also needs to be a bytes accumulator to collect values to include in the ASTNodes because
/// those include the key/value pairs available in the `.env` file.
///
/// ## Properties
/// - `allocator`: The memory allocator used for managing frame data.
/// - `production`: The `ASTNodeType` representing which grammar production this frame is parsing.
/// - `step`: A step counter (`u8`) used to track progress within a multi-step production rule,
///    allowing the frame to be resumed after jumping to another frame and back.
/// - `value`: A byte slice holding the accumulated value for the resulting `ASTNode` when the frame is popped.
/// - `nodes`: An `ASTArrayList` of child `ASTNode`s collected during parsing, forming the subtree for this production.
/// - `bytes_accumulated`: A `std.ArrayList(u8)` used to incrementally collect bytes across multiple tokens,
///    which is especially useful for productions like `MIXED_CONTENT` that span several value tokens.
///
/// ## Methods
/// - `init(allocator, production)`: Creates a new `StackFrame` for the given production type with
///    step set to `0`, an empty value, no child nodes, and an empty byte accumulator.
const StackFrame = struct {
  allocator: Allocator,

  production: ASTNodeType,
  step: u8,
  value: []const u8, // ASTNode value for when the frame pops.
  nodes: ASTArrayList,
  bytes_accumulated: std.ArrayList(u8),

  pub fn init(allocator: Allocator, production: ASTNodeType) StackFrame {
      return StackFrame {
          .allocator = allocator,

          .production = production,
          .step = 0,
          .value = "",
          .nodes = .empty,
          .bytes_accumulated = .empty,
      };
  }
};

/// The `CallStack` manages the `StackFrame`s used during iterative parsing.
/// It is able to push (add) and pop (remove) frames from the stack;
/// however, it does not handle any parsing logic itself.
///
/// Each time a frame is removed from the stack, it means it has finished parsing
/// and as a result an `ASTNode` is created. If a parent frame exists, the node
/// is appended to the parent's children; otherwise, it is stored as the root
/// `result`.
///
/// ## Properties
/// - `allocator`: The memory allocator used for managing frames and nodes. 
/// - `frames`: The list of active `StackFrame`s representing the current call stack.
/// - `result`: The root `ASTNode` produced once all frames have been processed, or `null` if parsing is still in progress.
const CallStack = struct {
  allocator: Allocator,

  frames: std.ArrayList(StackFrame),
  result: ?ASTNode,

  /// Initializes a new `CallStack` with the given allocator.
  /// The stack starts with no frames and no result.
  /// The allocator is used for managing the internal list of `StackFrame`s.
  pub fn init(allocator: Allocator) CallStack {
      return CallStack {
          .allocator = allocator,
          .frames = .empty,
          .result = null,
      };
  }

  /// Pushes a new `StackFrame` onto the call stack.
  /// This is used to signal that a new production rule needs to be parsed.
  /// The frame will be processed by the main loop on the next iteration.
  fn push(self: *CallStack, frame: StackFrame) !void {
    try self.frames.append(self.allocator, frame);
  }

  /// Pops the top frame from the call stack and constructs an `ASTNode`
  /// from its accumulated data (production type, value, and child nodes).
  /// If a parent frame exists, the resulting node is appended to the
  /// parent's children; otherwise, it is stored as the root result.
  /// Returns the completed `ASTNode`, or `error.EmptyStack` if the
  /// stack is empty.
  fn pop(self: *CallStack) !ASTNode {
    // Gets the top frame which is the last item of the array.
    // This also removes the frame from the stack.
    const top_frame: StackFrame = self.frames.pop() orelse return error.EmptyStack;

    // Build a node from what it was collected in the frame:
    const node = ASTNode {
      .type = top_frame.production,
      .value = top_frame.value,
      .children = top_frame.nodes.items,
    };

    // When there's a parent frame, give it the result of the current frame process.
    // When a frame has not parent it means it is done and should store the result.
    if (self.frames.items.len > 0) {
      var parent = &self.frames.items[self.frames.items.len - 1];
      try parent.nodes.append(self.allocator, node);
    } else {
      // No parent — this is the root result:
      self.result = node;
    }

    // Return complete node:
    return node;
  }
};

/// Parses a grammar rule:
/// <FILE_CONTENTS> ::= NEW_LINE* <STATEMENT>* END_OF_FILE
fn handleFileContents(parser: *Parser, stack: *CallStack, frame: *StackFrame) !void {
  switch (frame.step) {
    0 => {
      // Consume any leading blank lines before looking for statements, one per main loop iteration.
      if (parser.currentToken().type == .NEW_LINE) {
        _ = try parser.expect(.NEW_LINE);
      } else {
        // Move to next step once all blank lines have been consumed.
        frame.step = 1;
      }
    },

    // The main loop will hit this step n times,
    // each iteraton processing a token and progressing through the file.
    1 => {
      switch (parser.currentToken().type) {
        .WHITE_SPACE => {
          // Consume leading whitespace
          _ = try parser.expect(.WHITE_SPACE);
        },
        .NEW_LINE => {
          // If we hit a newline, it's a whitespace-only line - consume and continue
          _ = try parser.expect(.NEW_LINE);
        },
        .END_OF_FILE => {
          // Done with all statements so we can move to step 2.
          frame.step = 2;
        },
        else => {
          // Otherwise parse as normal statement by adding a stack call:
          const statement_frame = StackFrame.init(stack.allocator, .STATEMENT);

          // Continue the main loop iteration so that we look at the top of the stack and process the latest frame:
          try stack.push(statement_frame);

          // Stay on step 1 (so when STATEMENT completes, we come back here):
          frame.step = 1;
        },
      }
    },

    // Reaches the final step processing the end of the file
    // and removes the frame from the stack, finalising the parsing.
    2 => {
      // Once all the potential available statements are done, we expect EOF.
      _ = try parser.expect(.END_OF_FILE);

      // Removes frame from the stack.
      // The result is automatically returned here by the pop.
      _ = try stack.pop();
    },

    else => {}
  }
}

/// Parses a grammar rule:
/// <STATEMENT> ::= <ASSIGNMENT> WHITE_SPACE* (NEW_LINE+ | END_OF_FILE)
fn handleStatement(parser: *Parser, stack: *CallStack, frame: *StackFrame) !void {
  switch (frame.step) {
    0 => {
      // Moves to next step so that when the frame is done processing we continue parsing the statement.
      // This needs to happen before the push to avoid pointer invalidation issues.
      frame.step = 1;

      // Attempt to parse an assignment:
      const assignment_frame = StackFrame.init(parser.allocator, .ASSIGNMENT);
      try stack.push(assignment_frame);
    },
    1 => {
      // Ignore any trailing .WHITE_SPACE by advancing until we find a `.NEW_LINE`:
      if (parser.currentToken().type == .WHITE_SPACE) {
        _ = try parser.expect(.WHITE_SPACE);
      } else {
        // A statement ends with one or more new lines, or END_OF_FILE if it's the last statement.
        if (parser.currentToken().type == .NEW_LINE) {
            _ = try parser.expect(.NEW_LINE);
            // Ignore any other new lines:
            while (parser.currentToken().type == .NEW_LINE) {
                _ = try parser.expect(.NEW_LINE);
            }
        } else if (parser.currentToken().type == .END_OF_FILE) {
            // Valid - last statement in file, no trailing newline required.
        } else {
            return ParseError.UnexpectedToken;
        }

        // Done with this production, we can remove it from the stack:
        _ = try stack.pop();
      }
    },
    else => {}
  }
}

/// Parses a grammar rule:
/// <ASSIGNMENT> ::= <IDENTIFIER> (WHITE_SPACE)* EQUALS (WHITE_SPACE)* <VALUE>
fn handleAssignment(parser: *Parser, stack: *CallStack, frame: *StackFrame) !void {
  switch (frame.step) {
    0 => {
      // Move to the next step:
      // This needs to happen before the push to avoid pointer invalidation issues.
      frame.step = 1;

      // Signals that an identifier non terminal needs to be parsed:
      try stack.push(StackFrame.init(stack.allocator, .IDENTIFIER));
    },
    1=> {
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

      // Move to the next step on the text iteration.
      frame.step = 2;
    },
    2 => {
      // This needs to happen before the push to avoid pointer invalidation issues.
      frame.step = 3;

      // Attempt to parse the value portion of the statement.
      try stack.push(StackFrame.init(stack.allocator, .VALUE));
    },
    3 => {
      // Package the ASTNode for the next frame and remove the frame from the stack.
      _ = try stack.pop();
    },
    else => {}
  }
}

/// Parses a grammar rule:
/// <IDENTIFIER> ::= WORD
/// On pattern match, one non-terminal .IDENTIFIER node is returned and we abstract the `.WORD` terminal.
fn handleIdentifier(parser: *Parser, stack: *CallStack, frame: *StackFrame) !void {
  switch (frame.step) {
    0 => {
      // Sets the value of the ASTNode.
      const token = try parser.expect(.WORD);
      frame.value = try stack.allocator.dupe(u8, token.value);

      // When the frame is done, it's value will be used in the ASTNode.
      _ = try stack.pop();
    },
    else => {}
  }
}

/// Parses a grammar rule:
/// <VALUE> ::= <MIXED_CONTENT> | ε
fn handleValue(parser: *Parser, stack: *CallStack, frame: *StackFrame) !void {
  switch (frame.step) {
    0 => {
      const token = parser.currentToken();

      switch (token.type) {
        .WORD, .DOUBLE_QUOTED_STRING, .SINGLE_QUOTED_STRING => {
          // This needs to happen before the push to avoid pointer invalidation issues.
          frame.step = 1;

          const mixed_content_frame = StackFrame.init(stack.allocator, .MIXED_CONTENT);
          _ = try stack.push(mixed_content_frame);
        },
        else => {
          // If it's not either of those it must be an empty value:
          frame.step = 1;
        }
      }
    },
    1 => {
      if (frame.nodes.items.len > 0) {
          const child = frame.nodes.items[frame.nodes.items.len - 1];
          frame.value = try stack.allocator.dupe(u8, child.value);
      }

      // We are done processing this frame, we can move to the next stack frame.
      _ = try stack.pop();
    },
    else => {}
  }
}

/// Parses a grammar rule:
/// <MIXED_CONTENT> ::= <VALUE_TOKEN> (WHITE_SPACE* <VALUE_TOKEN>)*
fn handleMixedContent(parser: *Parser, stack: *CallStack, frame: *StackFrame) !void {
  switch (frame.step) {
    // The value of this token needs to be appended to the frame as an accumulator as there might be more content that is part of the value in other tokens.
    // A <MIXED_CONTENT> can have multiple <VALUE_TOKEN> ASTNodes.
    0 => {
      // This needs to happen before the push to avoid pointer invalidation issues.
      frame.step = 1;

      // Attempt to find a value token:
      const first_value_frame = StackFrame.init(stack.allocator, .VALUE_TOKEN);
      _ = try stack.push(first_value_frame);
    },

    1 => {
      // Append it to our final string,
      // value comes from .VALUE_TOKEN stack frame.
      const last_child = frame.nodes.items[frame.nodes.items.len - 1];
      try frame.bytes_accumulated.appendSlice(stack.allocator, last_child.value);

      // Keep parsing the remaining value tokens and white space.
      if (parser.currentToken().type == .WHITE_SPACE) {
        const white_space_token = try parser.expect(.WHITE_SPACE);
        try frame.bytes_accumulated.appendSlice(parser.allocator, white_space_token.value);
      }

      frame.step = 2;
    },

    2 => {
        if (parser.currentToken().type == .WHITE_SPACE) {
            const ws_token = try parser.expect(.WHITE_SPACE);
            try frame.bytes_accumulated.appendSlice(stack.allocator, ws_token.value);
            // Stay on step 2 to check for more whitespace or a value token
        } else if (parser.currentToken().type == .WORD or
                   parser.currentToken().type == .DOUBLE_QUOTED_STRING or
                   parser.currentToken().type == .SINGLE_QUOTED_STRING) {

            // This needs to happen before the push to avoid pointer invalidation issues.
            frame.step = 1;

            // Push VALUE_TOKEN, go back to step 1 to collect its result
            try stack.push(StackFrame.init(stack.allocator, .VALUE_TOKEN));
        } else {
            // Done — set the frame's value from accumulated bytes and pop
            frame.value = try stack.allocator.dupe(u8, frame.bytes_accumulated.items);
            _ = try stack.pop();
        }
    },
    else => {}
  }
}

/// Parses a grammar rule:
/// <VALUE_TOKEN> ::= WORD | DOUBLE_QUOTED_STRING | SINGLE_QUOTED_STRING
fn handleValueToken(parser: *Parser, stack: *CallStack, frame: *StackFrame) !void {
  switch (frame.step) {
    0 => {
      const token = parser.currentToken();

      switch (token.type) {
        .WORD, .DOUBLE_QUOTED_STRING, .SINGLE_QUOTED_STRING => {
          // Enforces grammar rule, copies token _value_ over to stack frame.
          const value_token = try parser.expect(token.type);
          frame.value = try stack.allocator.dupe(u8, value_token.value);
        },
        else => {
          return ParseError.UnexpectedToken;
        }
      }

      _ = try stack.pop();
    },
    else => {}
  }
}

/// Process tokens using a managed call stack to iteratively parse the input.
/// Initialises the stack with a `FILE_CONTENTS` frame and loops through
/// frames, dispatching each production to its handler until the stack is
/// empty. Returns the root `ASTNode` of the resulting Abstract Syntax Tree,
/// or a `ParseError.UnexpectedToken` error if parsing fails to produce a result.
pub fn parse(parser: *Parser) !ASTNode {
  // Instantiate a call stack to store all frames.
  var stack: CallStack = CallStack.init(parser.allocator);

  // Instantiate the start frame and push it into the stack.
  // This should result into more frames being pushed to the stack over many iterations.
  const initial_frame = StackFrame.init(parser.allocator, .FILE_CONTENTS);
  try stack.push(initial_frame);

  // Iterates through the stack to parse each production.
  // More frames will be pushed onto the stack as it runs,
  // eventually the stack should reach zero and return the AST as a result.
  while (stack.frames.items.len > 0)  {
    const frame = &stack.frames.items[stack.frames.items.len - 1];

    // Maps each production to its respective function for processing.
    // Each production might be visited one or multiple times to process
    // a different step.
    switch (frame.production) {
      .FILE_CONTENTS => try handleFileContents(parser, &stack, frame),
      .STATEMENT => try handleStatement(parser, &stack, frame),
      .ASSIGNMENT => try handleAssignment(parser, &stack, frame),
      .IDENTIFIER => try handleIdentifier(parser, &stack, frame),
      .VALUE => try handleValue(parser, &stack, frame),
      .MIXED_CONTENT => try handleMixedContent(parser, &stack, frame),
      .VALUE_TOKEN => try handleValueToken(parser, &stack, frame),
    }
  }

  // Returns the final result:
  return stack.result orelse ParseError.UnexpectedToken;
}
