# Envo - A .env file parser for Zig

Built for version `0.15.2`.

# Importing into a Zig Project

Fetch the `envo` package and save it to `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/csalmeida/envo
```

Then, in your `build.zig` file, load the dependency and its module:

```zig
    // Load the "envo" dependency from build.zig.zon:
    const envo_package = b.dependency("envo", .{
        .target = target,
        .optimize = optimize,
    });
    // Load the "envo" module from the package:
    const envo_module = envo_package.module("envo");
```

Finally, make the module available to your executable. You can do this in one of two ways:

**Option A** — Add the import when defining your executable's root module:

```zig
    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "envo", .module = envo_module },
            },
        }),
    });
```

**Option B** — Add the import to an existing root module:

```zig
    exe.root_module.addImport("envo", envo_module);
```

Once configured, you can import `envo` in your Zig source files:

```zig
const envo = @import("envo");
```

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
