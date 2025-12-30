//! Default Configuration Values
//!
//! This module contains all the default configuration values for the Jinja2 template
//! engine. These values match the defaults from the Python Jinja2 implementation and
//! are used when an `Environment` is created without explicit configuration.
//!
//! # Configuration Options
//!
//! | Option | Default | Description |
//! |--------|---------|-------------|
//! | `BLOCK_START_STRING` | `{%` | Start delimiter for block tags |
//! | `BLOCK_END_STRING` | `%}` | End delimiter for block tags |
//! | `VARIABLE_START_STRING` | `{{` | Start delimiter for variable output |
//! | `VARIABLE_END_STRING` | `}}` | End delimiter for variable output |
//! | `COMMENT_START_STRING` | `{#` | Start delimiter for comments |
//! | `COMMENT_END_STRING` | `#}` | End delimiter for comments |
//! | `LINE_STATEMENT_PREFIX` | `null` | Optional line statement prefix |
//! | `LINE_COMMENT_PREFIX` | `null` | Optional line comment prefix |
//! | `TRIM_BLOCKS` | `false` | Remove first newline after block tags |
//! | `LSTRIP_BLOCKS` | `false` | Strip leading whitespace from block tags |
//! | `NEWLINE_SEQUENCE` | `\n` | Newline sequence for output |
//! | `KEEP_TRAILING_NEWLINE` | `false` | Keep trailing newline in templates |
//! | `AUTOESCAPE` | `false` | Enable automatic HTML escaping |
//! | `OPTIMIZED` | `true` | Enable AST optimization |
//! | `CACHE_SIZE` | `400` | LRU cache size for templates |
//! | `AUTO_RELOAD` | `true` | Auto-reload changed templates |
//! | `UNDEFINED_BEHAVIOR` | `lenient` | How to handle undefined variables |
//!
//! # Usage
//!
//! These defaults are automatically applied when creating an Environment:
//!
//! ```zig
//! var env = jinja.Environment.init(allocator);
//! // Uses all defaults from this module
//! ```

/// Default block start string: "{%"
pub const BLOCK_START_STRING = "{%";

/// Default block end string: "%}"
pub const BLOCK_END_STRING = "%}";

/// Default variable start string: "{{"
pub const VARIABLE_START_STRING = "{{";

/// Default variable end string: "}}"
pub const VARIABLE_END_STRING = "}}";

/// Default comment start string: "{#"
pub const COMMENT_START_STRING = "{#";

/// Default comment end string: "#}"
pub const COMMENT_END_STRING = "#}";

/// Default line statement prefix (None)
pub const LINE_STATEMENT_PREFIX: ?[]const u8 = null;

/// Default line comment prefix (None)
pub const LINE_COMMENT_PREFIX: ?[]const u8 = null;

/// Default trim blocks: false
pub const TRIM_BLOCKS = false;

/// Default lstrip blocks: false
pub const LSTRIP_BLOCKS = false;

/// Default newline sequence: "\n"
pub const NEWLINE_SEQUENCE = "\n";

/// Default keep trailing newline: false
pub const KEEP_TRAILING_NEWLINE = false;

/// Default autoescape: false
pub const AUTOESCAPE = false;

/// Default optimized: true
pub const OPTIMIZED = true;

/// Default cache size: 400
pub const CACHE_SIZE: usize = 400;

/// Default auto reload: true
pub const AUTO_RELOAD = true;

/// Default undefined behavior: lenient (return empty string)
pub const UNDEFINED_BEHAVIOR = @import("value.zig").UndefinedBehavior.lenient;
