-- tst/unit/agent_provider_claude.lua
-- Unit tests for src/agent_provider_claude.lua's translation functions:
-- canonical (agent.lua's own neutral protocol, see doc/agent-protocol.md)
-- <-> Claude's real Messages API wire shapes. No real API calls -- these
-- exercise the pure translation logic and (for stop_reason mapping) a
-- monkey-patched claude_post, matching this repo's existing tst/unit/
-- style (require the module, check(), run inline, exit 1 on failure).

agent_provider_claude = require("agent_provider_claude")
json = require("dkjson")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function test_tools_from_canonical_passes_lowercase_schema_through()
    print("Testing claude_tools_from_canonical keeps standard JSON Schema as-is")
    tools = {
        {name = "document.search", description = "Search pages.",
         parameters = {type = "object", properties = {query = {type = "string"}}, required = {"query"}}},
    }
    out = claude_tools_from_canonical(tools)
    check(#out == 1, "expected one translated tool")
    check(out[1].name == "document.search", "name should pass through unchanged")
    check(out[1].input_schema.type == "object", "expected lowercase 'object', got: " .. tostring(out[1].input_schema.type))
    check(out[1].input_schema.properties.query.type == "string", "expected lowercase 'string' for nested property")
end

function test_messages_from_canonical_user_and_assistant()
    print("Testing claude_messages_from_canonical translates user/assistant roles")
    messages = {
        {role = "user", content = "hello"},
        {role = "assistant", content = {{type = "text", text = "hi there"}}},
    }
    out = claude_messages_from_canonical(messages)
    check(#out == 2, "expected two messages")
    check(out[1].role == "user" and out[1].content == "hello", "expected plain user string content")
    check(out[2].role == "assistant", "expected assistant role")
    check(out[2].content[1].type == "text" and out[2].content[1].text == "hi there", "expected text block preserved")
end

function test_messages_from_canonical_tool_call_and_result()
    print("Testing a toolCall block becomes tool_use, and toolResult becomes a tool_result message keyed by the real id")
    messages = {
        {role = "assistant", content = {{type = "toolCall", id = "toolu_abc123", name = "document.search", arguments = {query = "x"}}}},
        {role = "toolResult", toolCallId = "toolu_abc123", toolName = "document.search", isError = false,
         content = {{text = "found it"}}},
    }
    out = claude_messages_from_canonical(messages)
    check(out[1].content[1].type == "tool_use", "expected tool_use block")
    check(out[1].content[1].id == "toolu_abc123", "expected Claude's own real id preserved, not a synthesized one")
    check(out[1].content[1].input.query == "x", "expected arguments passed as input")
    check(out[2].role == "user", "a tool result must be sent back as a user-role message")
    check(out[2].content[1].type == "tool_result", "expected a tool_result content block")
    check(out[2].content[1].tool_use_id == "toolu_abc123", "expected tool_result keyed by the same real id")
    check(out[2].content[1].content == "found it", "expected result text preserved")
    check(out[2].content[1].is_error == false, "expected is_error false for a successful result")
end

function test_blocks_from_content_all_three_types()
    print("Testing claude_blocks_from_content translates text/tool_use/thinking blocks to canonical shape")
    content = {
        {type = "text", text = "here's my answer"},
        {type = "tool_use", id = "toolu_xyz", name = "entity.list", input = {entity_type = "sample"}},
        {type = "thinking", thinking = "let me consider...", signature = "sig123"},
    }
    blocks = claude_blocks_from_content(content)
    check(#blocks == 3, "expected 3 translated blocks, got " .. tostring(#blocks))
    check(blocks[1].type == "text" and blocks[1].text == "here's my answer", "expected text block")
    check(blocks[2].type == "toolCall" and blocks[2].id == "toolu_xyz", "expected toolCall block with real id preserved")
    check(blocks[2].name == "entity.list" and blocks[2].arguments.entity_type == "sample", "expected name/arguments preserved")
    check(blocks[3].type == "thinking" and blocks[3].thinking == "let me consider...", "expected thinking block")
    check(blocks[3].thinking_signature == "sig123", "expected Claude's signature preserved as thinking_signature")
end

function test_stop_reason_mapping()
    print("Testing claude_stop_reason_to_canonical maps every real stop_reason value")
    check(claude_stop_reason_to_canonical("end_turn") == "stop", "expected 'end_turn' -> 'stop'")
    check(claude_stop_reason_to_canonical("tool_use") == "toolUse", "expected 'tool_use' -> 'toolUse'")
    check(claude_stop_reason_to_canonical("max_tokens") == "length", "expected 'max_tokens' -> 'length'")
    -- pause_turn is only reachable if a server tool were ever declared
    -- (this file never declares one -- see its own header), and
    -- stop_sequence/refusal/anything else Anthropic adds later are all
    -- real responses that aren't a genuine completed answer this file
    -- knows how to continue -- all fall through to "error".
    check(claude_stop_reason_to_canonical("pause_turn") == "error", "expected unreachable-in-practice 'pause_turn' -> 'error'")
    check(claude_stop_reason_to_canonical("stop_sequence") == "error", "expected 'stop_sequence' -> 'error'")
    check(claude_stop_reason_to_canonical(nil) == "error", "expected nil -> 'error'")
end

-- Run them
test_tools_from_canonical_passes_lowercase_schema_through()
test_messages_from_canonical_user_and_assistant()
test_messages_from_canonical_tool_call_and_result()
test_blocks_from_content_all_three_types()
test_stop_reason_mapping()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All agent_provider_claude.lua tests passed")
