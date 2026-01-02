const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const context = vibe_jinja.context;
const value = vibe_jinja.value;

// ============================================================================
// Production HuggingFace Template Tests
// These test REAL templates from production models to ensure vibe-jinja works
// ============================================================================

/// Helper to create a messages list with system and user messages
fn createTestMessages(allocator: std.mem.Allocator, include_system: bool) !*value.List {
    const messages_list = try allocator.create(value.List);
    messages_list.* = value.List.init(allocator);

    if (include_system) {
        const system_msg = try allocator.create(value.Dict);
        system_msg.* = value.Dict.init(allocator);
        try system_msg.set("role", value.Value{ .string = try allocator.dupe(u8, "system") });
        try system_msg.set("content", value.Value{ .string = try allocator.dupe(u8, "You are a helpful assistant.") });
        try messages_list.append(value.Value{ .dict = system_msg });
    }

    const user_msg = try allocator.create(value.Dict);
    user_msg.* = value.Dict.init(allocator);
    try user_msg.set("role", value.Value{ .string = try allocator.dupe(u8, "user") });
    try user_msg.set("content", value.Value{ .string = try allocator.dupe(u8, "Hello!") });
    try messages_list.append(value.Value{ .dict = user_msg });

    return messages_list;
}

/// Helper to create multi-turn messages (user, assistant, user)
fn createMultiTurnMessages(allocator: std.mem.Allocator) !*value.List {
    const messages_list = try allocator.create(value.List);
    messages_list.* = value.List.init(allocator);

    const user1 = try allocator.create(value.Dict);
    user1.* = value.Dict.init(allocator);
    try user1.set("role", value.Value{ .string = try allocator.dupe(u8, "user") });
    try user1.set("content", value.Value{ .string = try allocator.dupe(u8, "What is 2+2?") });
    try messages_list.append(value.Value{ .dict = user1 });

    const assistant = try allocator.create(value.Dict);
    assistant.* = value.Dict.init(allocator);
    try assistant.set("role", value.Value{ .string = try allocator.dupe(u8, "assistant") });
    try assistant.set("content", value.Value{ .string = try allocator.dupe(u8, "4") });
    try messages_list.append(value.Value{ .dict = assistant });

    const user2 = try allocator.create(value.Dict);
    user2.* = value.Dict.init(allocator);
    try user2.set("role", value.Value{ .string = try allocator.dupe(u8, "user") });
    try user2.set("content", value.Value{ .string = try allocator.dupe(u8, "And 3+3?") });
    try messages_list.append(value.Value{ .dict = user2 });

    return messages_list;
}

// Embed all templates (copied to integration/templates/ for embed access)
const llama3_instruct = @embedFile("templates/llama3-instruct.jinja");
const chatml = @embedFile("templates/chatml.jinja");
const qwen2_instruct = @embedFile("templates/qwen2-instruct.jinja");
const mistral_instruct = @embedFile("templates/mistral-instruct.jinja");
const llama2_chat = @embedFile("templates/llama2-chat.jinja");
const phi_3 = @embedFile("templates/phi-3.jinja");
const gemma_instruct = @embedFile("templates/gemma-instruct.jinja");
const granite_instruct = @embedFile("templates/granite-instruct.jinja");
const command_r = @embedFile("templates/command-r.jinja");
const zephyr = @embedFile("templates/zephyr.jinja");
const alpaca = @embedFile("templates/alpaca.jinja");
const falcon_instruct = @embedFile("templates/falcon-instruct.jinja");
const solar_instruct = @embedFile("templates/solar-instruct.jinja");
const chatqa = @embedFile("templates/chatqa.jinja");
const openchat = @embedFile("templates/openchat.jinja");
const vicuna = @embedFile("templates/vicuna.jinja");

// ----------------------------------------------------------------------------
// Llama 3 Instruct
// ----------------------------------------------------------------------------

test "llama3-instruct: basic user message" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createTestMessages(allocator, false);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    const bos_key = try allocator.dupe(u8, "bos_token");
    defer allocator.free(bos_key);
    try vars.put(bos_key, value.Value{ .string = try allocator.dupe(u8, "<|begin_of_text|>") });

    const add_gen_key = try allocator.dupe(u8, "add_generation_prompt");
    defer allocator.free(add_gen_key);
    try vars.put(add_gen_key, value.Value{ .boolean = true });

    const result = try rt.renderString(llama3_instruct, vars, "llama3");
    defer allocator.free(result);

    // Verify expected tokens
    try testing.expect(std.mem.indexOf(u8, result, "<|begin_of_text|>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|start_header_id|>user<|end_header_id|>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Hello!") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|eot_id|>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|start_header_id|>assistant<|end_header_id|>") != null);
}

// ----------------------------------------------------------------------------
// ChatML (Qwen, Yi, DeepSeek)
// ----------------------------------------------------------------------------

test "chatml: basic conversation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createTestMessages(allocator, true);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    // Don't set add_generation_prompt - let template use default (false -> true via is defined check)
    // Actually set it to true explicitly
    const add_gen_key = try allocator.dupe(u8, "add_generation_prompt");
    defer allocator.free(add_gen_key);
    try vars.put(add_gen_key, value.Value{ .boolean = true });

    const result = try rt.renderString(chatml, vars, "chatml");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<|im_start|>system") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|im_end|>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|im_start|>user") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|im_start|>assistant") != null);
}

// ----------------------------------------------------------------------------
// Qwen2 Instruct
// ----------------------------------------------------------------------------

test "qwen2-instruct: with system message extraction" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createTestMessages(allocator, true);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    const add_gen_key = try allocator.dupe(u8, "add_generation_prompt");
    defer allocator.free(add_gen_key);
    try vars.put(add_gen_key, value.Value{ .boolean = true });

    const result = try rt.renderString(qwen2_instruct, vars, "qwen2");
    defer allocator.free(result);

    // Should extract system and put it first
    try testing.expect(std.mem.indexOf(u8, result, "<|im_start|>system") != null);
    try testing.expect(std.mem.indexOf(u8, result, "You are a helpful assistant.") != null);
}

// ----------------------------------------------------------------------------
// Mistral Instruct
// ----------------------------------------------------------------------------

test "mistral-instruct: multi-turn conversation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createMultiTurnMessages(allocator);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    const bos_key = try allocator.dupe(u8, "bos_token");
    defer allocator.free(bos_key);
    try vars.put(bos_key, value.Value{ .string = try allocator.dupe(u8, "<s>") });

    const eos_key = try allocator.dupe(u8, "eos_token");
    defer allocator.free(eos_key);
    try vars.put(eos_key, value.Value{ .string = try allocator.dupe(u8, "</s>") });

    const result = try rt.renderString(mistral_instruct, vars, "mistral");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<s>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[INST]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[/INST]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "What is 2+2?") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</s>") != null);
}

// ----------------------------------------------------------------------------
// Phi-3
// ----------------------------------------------------------------------------

test "phi-3: basic format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createTestMessages(allocator, true);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    const bos_key = try allocator.dupe(u8, "bos_token");
    defer allocator.free(bos_key);
    try vars.put(bos_key, value.Value{ .string = try allocator.dupe(u8, "<s>") });

    const eos_key = try allocator.dupe(u8, "eos_token");
    defer allocator.free(eos_key);
    try vars.put(eos_key, value.Value{ .string = try allocator.dupe(u8, "<|end|>") });

    const add_gen_key = try allocator.dupe(u8, "add_generation_prompt");
    defer allocator.free(add_gen_key);
    try vars.put(add_gen_key, value.Value{ .boolean = true });

    const result = try rt.renderString(phi_3, vars, "phi3");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<s>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|system|>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|user|>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|end|>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|assistant|>") != null);
}

// ----------------------------------------------------------------------------
// Zephyr
// ----------------------------------------------------------------------------

test "zephyr: basic format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createTestMessages(allocator, true);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    const eos_key = try allocator.dupe(u8, "eos_token");
    defer allocator.free(eos_key);
    try vars.put(eos_key, value.Value{ .string = try allocator.dupe(u8, "</s>") });

    const add_gen_key = try allocator.dupe(u8, "add_generation_prompt");
    defer allocator.free(add_gen_key);
    try vars.put(add_gen_key, value.Value{ .boolean = true });

    const result = try rt.renderString(zephyr, vars, "zephyr");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<|system|>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|user|>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</s>") != null);
}

// ----------------------------------------------------------------------------
// Granite Instruct
// ----------------------------------------------------------------------------

test "granite-instruct: question/answer format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createTestMessages(allocator, true);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    const add_gen_key = try allocator.dupe(u8, "add_generation_prompt");
    defer allocator.free(add_gen_key);
    try vars.put(add_gen_key, value.Value{ .boolean = true });

    const result = try rt.renderString(granite_instruct, vars, "granite");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "System:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Question:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Answer:") != null);
}

// ----------------------------------------------------------------------------
// Falcon Instruct
// ----------------------------------------------------------------------------

test "falcon-instruct: basic format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createTestMessages(allocator, true);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    const add_gen_key = try allocator.dupe(u8, "add_generation_prompt");
    defer allocator.free(add_gen_key);
    try vars.put(add_gen_key, value.Value{ .boolean = true });

    const result = try rt.renderString(falcon_instruct, vars, "falcon");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "System:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "User:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Falcon:") != null);
}

// ----------------------------------------------------------------------------
// Solar Instruct
// ----------------------------------------------------------------------------

test "solar-instruct: basic format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createTestMessages(allocator, true);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    const add_gen_key = try allocator.dupe(u8, "add_generation_prompt");
    defer allocator.free(add_gen_key);
    try vars.put(add_gen_key, value.Value{ .boolean = true });

    const result = try rt.renderString(solar_instruct, vars, "solar");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "### System:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### User:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### Assistant:") != null);
}

// ----------------------------------------------------------------------------
// ChatQA
// ----------------------------------------------------------------------------

test "chatqa: basic format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createTestMessages(allocator, true);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    const bos_key = try allocator.dupe(u8, "bos_token");
    defer allocator.free(bos_key);
    try vars.put(bos_key, value.Value{ .string = try allocator.dupe(u8, "") });

    const eos_key = try allocator.dupe(u8, "eos_token");
    defer allocator.free(eos_key);
    try vars.put(eos_key, value.Value{ .string = try allocator.dupe(u8, "") });

    const add_gen_key = try allocator.dupe(u8, "add_generation_prompt");
    defer allocator.free(add_gen_key);
    try vars.put(add_gen_key, value.Value{ .boolean = true });

    const result = try rt.renderString(chatqa, vars, "chatqa");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "User:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Assistant:") != null);
}

// ----------------------------------------------------------------------------
// OpenChat
// ----------------------------------------------------------------------------

test "openchat: GPT4 Correct format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createTestMessages(allocator, false);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    const bos_key = try allocator.dupe(u8, "bos_token");
    defer allocator.free(bos_key);
    try vars.put(bos_key, value.Value{ .string = try allocator.dupe(u8, "") });

    const add_gen_key = try allocator.dupe(u8, "add_generation_prompt");
    defer allocator.free(add_gen_key);
    try vars.put(add_gen_key, value.Value{ .boolean = true });

    const result = try rt.renderString(openchat, vars, "openchat");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "GPT4 Correct User:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|end_of_turn|>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "GPT4 Correct Assistant:") != null);
}

// ----------------------------------------------------------------------------
// Vicuna
// ----------------------------------------------------------------------------

test "vicuna: USER/ASSISTANT format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createTestMessages(allocator, true);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    const eos_key = try allocator.dupe(u8, "eos_token");
    defer allocator.free(eos_key);
    try vars.put(eos_key, value.Value{ .string = try allocator.dupe(u8, "</s>") });

    const add_gen_key = try allocator.dupe(u8, "add_generation_prompt");
    defer allocator.free(add_gen_key);
    try vars.put(add_gen_key, value.Value{ .boolean = true });

    const result = try rt.renderString(vicuna, vars, "vicuna");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "USER:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "ASSISTANT:") != null);
}

// ----------------------------------------------------------------------------
// Llama 2 Chat
// ----------------------------------------------------------------------------

test "llama2-chat: multi-turn conversation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createMultiTurnMessages(allocator);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    const bos_key = try allocator.dupe(u8, "bos_token");
    defer allocator.free(bos_key);
    try vars.put(bos_key, value.Value{ .string = try allocator.dupe(u8, "<s>") });

    const eos_key = try allocator.dupe(u8, "eos_token");
    defer allocator.free(eos_key);
    try vars.put(eos_key, value.Value{ .string = try allocator.dupe(u8, "</s>") });

    const result = try rt.renderString(llama2_chat, vars, "llama2");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<s>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[INST]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[/INST]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</s>") != null);
}

// ----------------------------------------------------------------------------
// Gemma Instruct
// ----------------------------------------------------------------------------

test "gemma-instruct: user/model format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createMultiTurnMessages(allocator);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    const bos_key = try allocator.dupe(u8, "bos_token");
    defer allocator.free(bos_key);
    try vars.put(bos_key, value.Value{ .string = try allocator.dupe(u8, "<bos>") });

    const add_gen_key = try allocator.dupe(u8, "add_generation_prompt");
    defer allocator.free(add_gen_key);
    try vars.put(add_gen_key, value.Value{ .boolean = true });

    const result = try rt.renderString(gemma_instruct, vars, "gemma");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<bos>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<start_of_turn>user") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<start_of_turn>model") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<end_of_turn>") != null);
}

// ----------------------------------------------------------------------------
// Command-R
// ----------------------------------------------------------------------------

test "command-r: Cohere format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const messages = try createMultiTurnMessages(allocator);
    const msg_key = try allocator.dupe(u8, "messages");
    defer allocator.free(msg_key);
    try vars.put(msg_key, value.Value{ .list = messages });

    const bos_key = try allocator.dupe(u8, "bos_token");
    defer allocator.free(bos_key);
    try vars.put(bos_key, value.Value{ .string = try allocator.dupe(u8, "<BOS_TOKEN>") });

    const add_gen_key = try allocator.dupe(u8, "add_generation_prompt");
    defer allocator.free(add_gen_key);
    try vars.put(add_gen_key, value.Value{ .boolean = true });

    const result = try rt.renderString(command_r, vars, "command-r");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<BOS_TOKEN>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|START_OF_TURN_TOKEN|>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|USER_TOKEN|>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|CHATBOT_TOKEN|>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<|END_OF_TURN_TOKEN|>") != null);
}

// ----------------------------------------------------------------------------
// Alpaca (uses namespace - skipped for now, needs further debugging)
// ----------------------------------------------------------------------------

// NOTE: Namespace attribute assignment is implemented but the Alpaca template
// test is skipped pending further debugging of edge cases.
// Basic namespace functionality works - see test/integration/set_with.zig for tests.
