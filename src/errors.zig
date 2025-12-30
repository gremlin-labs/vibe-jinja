/// Legacy error types for backward compatibility
/// These will be migrated to the new exceptions system
pub const SyntaxError = error{ CommentNotClosed, ExpressionNotClosed, TagNotParsable };
