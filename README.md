# Envo - A .env file parser for Zig

Built for version `0.15.2`.

# Grammar

```ruby
<FILE_CONTENTS> ::= NEW_LINE* <STATEMENT>* END_OF_FILE
<STATEMENT> ::= <ASSIGNMENT> WHITE_SPACE* (NEW_LINE+ | END_OF_FILE)
<ASSIGNMENT> ::= <IDENTIFIER> (WHITE_SPACE)* EQUALS (WHITE_SPACE)* <VALUE>
<IDENTIFIER> ::= WORD
<VALUE> ::= <MIXED_CONTENT> | ε
<MIXED_CONTENT> ::= <VALUE_TOKEN> (WHITE_SPACE* <VALUE_TOKEN>)*
<VALUE_TOKEN> ::= WORD | DOUBLE_QUOTED_STRING | SINGLE_QUOTED_STRING
```

## Tests

Currently tests can be run for each file directly, it's worth running tests when modifying the lexer and parser behaviour to check it still yields the same results and follows grammar rules.

```bash
zig test src/lexer.zig
zig test src/parser.zig
```
