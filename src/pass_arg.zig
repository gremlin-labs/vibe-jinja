/// Pass argument type for decorators.
/// Determines what should be passed as the first argument to filters/tests/functions.
pub const PassArg = enum {
    none,
    context,
    eval_context,
    environment,
};
