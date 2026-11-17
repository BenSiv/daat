-- tst/unit/agent_ollama.lua
-- Unit tests for src/provider/agent_ollama.lua's pure translation logic:
-- canonical protocol <-> OpenAI-compatible /v1/chat/completions and
-- /v1/embeddings wire shapes, thinking extraction (`reasoning`,
-- `reasoning_content`, and `<think>...</think>`), tool-name mapping, and
-- batch embedding ordering. No network calls.

agent_ollama = require("provider.agent_ollama")
json = require("dkjson")

unit = require("unit")
check = unit.check
tests = unit.suite()

function tests.defaults_and_endpoint_urls()
    print("Testing agent_ollama open-weights defaults and localhost endpoint URL")
    check(agent_ollama.default_model == "qwen3:8b", "expected default_model qwen3:8b, got: " .. tostring(agent_ollama.default_model))
    check(agent_ollama.default_embedding_model == "nomic-embed-text", "expected default_embedding_model nomic-embed-text")
    check(agent_ollama.ollama_endpoint_url("chat/completions") == "http://127.0.0.1:11434/v1/chat/completions",
        "expected default localhost Ollama chat completions URL")
    check(agent_ollama.ollama_endpoint_url("/embeddings") == "http://127.0.0.1:11434/v1/embeddings",
        "expected leading slash normalized on endpoint")
end

function tests.tool_names_round_trip_and_refuse_invalid()
    print("Testing tool names map . <-> __ within 64 chars and refuse invalid names or missing parameters")
    check(agent_ollama.ollama_wire_tool_name("document.search") == "document__search", "expected . -> __")
    check(agent_ollama.ollama_canonical_tool_name("document__search") == "document.search", "expected __ -> .")

    tools = {{
        name = "entity.query",
        description = "Run a SELECT.",
        parameters = {type = "object", properties = {sql = {type = "string"}}, required = {"sql"}},
    }}
    out, err = agent_ollama.ollama_tools_from_canonical(tools)
    check(err == nil and #out == 1, "expected one translated function tool")
    check(out[1].type == "function", "expected type = 'function'")
    check(out[1]["function"].name == "entity__query", "expected wire function name")
    check(out[1]["function"].parameters.type == "object", "expected lowercase JSON Schema preserved")

    schema = {type = "object", properties = {}}
    bad = {
        {name = "ext.bad__name", why = "double underscore cannot round-trip"},
        {name = "ext.bad name", why = "spaces outside allowed charset"},
        {name = "x." .. string.rep("a", 65), why = "exceeds 64-character OpenAI function name cap"},
    }
    for _, c in ipairs(bad) do
        bad_out, bad_err = agent_ollama.ollama_tools_from_canonical({{name = c.name, description = "d", parameters = schema}})
        check(bad_out == nil and bad_err != nil and string.find(bad_err, c.name, 1, true) != nil,
            c.why .. ": expected refusal naming tool, got: " .. tostring(bad_err))
    end

    no_params, no_params_err = agent_ollama.ollama_tools_from_canonical({{name = "view.list", description = "d"}})
    check(no_params == nil and string.find(tostring(no_params_err), "view.list", 1, true) != nil,
        "missing parameters should fail naming the tool")
end

function tests.messages_from_canonical_system_tool_call_and_result()
    print("Testing ollama_messages_from_canonical serializes system, assistant tool_calls JSON string, and tool role")
    messages = {
        {role = "user", content = "Find cocoa samples."},
        {role = "assistant", content = {
            {type = "thinking", thinking = "check schema first"},
            {type = "toolCall", id = "call_7", name = "entity.list", arguments = {entity_type = "sample"}},
        }},
        {role = "toolResult", toolCallId = "call_7", toolName = "entity.list", isError = false,
         content = {{text = "3 rows"}}},
    }
    out = agent_ollama.ollama_messages_from_canonical("Be accurate.", messages)
    check(#out == 4, "expected system + user + assistant + tool = 4 messages, got " .. tostring(#out))
    check(out[1].role == "system" and out[1].content == "Be accurate.", "expected system message first")
    check(out[2].role == "user" and out[2].content == "Find cocoa samples.", "expected user message")
    check(out[3].role == "assistant" and #out[3].tool_calls == 1, "expected assistant tool_calls")
    tc = out[3].tool_calls[1]
    check(tc.id == "call_7" and tc.type == "function", "expected preserved id and type=function")
    check(tc["function"].name == "entity__list", "expected wire name on replayed assistant tool call")
    check(type(tc["function"].arguments) == "string", "OpenAI wire arguments must be a JSON string")
    decoded_args = json.decode(tc["function"].arguments)
    check(decoded_args.entity_type == "sample", "expected JSON-encoded arguments round-trip")
    check(out[4].role == "tool" and out[4].tool_call_id == "call_7" and out[4].content == "3 rows",
        "expected tool role message keyed by tool_call_id")
end

function tests.blocks_from_message_captures_all_three_thinking_shapes_and_strips_tags()
    print("Testing ollama_blocks_from_message handles reasoning, reasoning_content, <think> tags, and agent_thinking=off")
    -- 1. Ollama / OpenRouter `message.reasoning`
    b1, has_tc1 = agent_ollama.ollama_blocks_from_message({
        reasoning = "Let me check the protocol.",
        content = "Use 20 mL.",
    }, "summary")
    check(has_tc1 == false and #b1 == 2, "expected thinking + text blocks")
    check(b1[1].type == "thinking" and b1[1].thinking == "Let me check the protocol.", "expected reasoning captured")
    check(b1[2].type == "text" and b1[2].text == "Use 20 mL.", "expected visible reply")

    -- 2. vLLM / DeepSeek `message.reasoning_content` + tool call with finish_reason="stop" quirk
    b2, has_tc2 = agent_ollama.ollama_blocks_from_message({
        reasoning_content = "Querying media table.",
        content = "",
        tool_calls = {{
            ["function"] = {name = "entity__query", arguments = "{\"sql\":\"SELECT 1\"}"},
        }},
    }, "full")
    check(has_tc2 == true and #b2 == 2, "expected thinking + toolCall")
    check(b2[1].type == "thinking" and b2[1].thinking == "Querying media table.", "expected reasoning_content captured")
    check(b2[2].type == "toolCall" and b2[2].id == "call_1" and b2[2].name == "entity.query", "expected synthesized call_1 and canonical name")
    check(b2[2].arguments.sql == "SELECT 1", "expected JSON string arguments decoded")
    check(agent_ollama.ollama_finish_reason_to_canonical("stop", has_tc2) == "toolUse",
        "tool_calls presence must override a local server's finish_reason='stop'")

    -- 3. Unparsed `<think>...</think>` tags in content: captured when summary, stripped even when off
    msg_tags = {content = "<think>\nStep 1: check sample.\n</think>\n\nSample CCN51 is active."}
    b_sum, _ = agent_ollama.ollama_blocks_from_message(msg_tags, "summary")
    check(#b_sum == 2 and b_sum[1].type == "thinking" and b_sum[1].thinking == "Step 1: check sample.",
        "expected <think> tag extracted into thinking block under summary")
    check(b_sum[2].type == "text" and b_sum[2].text == "Sample CCN51 is active.",
        "expected <think> tag stripped from visible text")

    b_off, _ = agent_ollama.ollama_blocks_from_message(msg_tags, "off")
    check(#b_off == 1 and b_off[1].type == "text" and b_off[1].text == "Sample CCN51 is active.",
        "off must omit thinking block while still stripping raw <think> tags from visible text")

    text, thinking = agent_ollama.ollama_text_and_thinking_from_message(msg_tags, "summary")
    check(text == "Sample CCN51 is active." and thinking == "Step 1: check sample.",
        "generate helper should return both visible text and thinking")
end

function tests.payloads_omit_reasoning_effort_by_default_and_embeddings_preserve_index_order()
    print("Testing payloads omit reasoning_effort unless opted in, and embeddings sort by index")
    cp, err = agent_ollama.ollama_converse_payload(nil, "Sys", {{role = "user", content = "Hi"}}, nil, "summary")
    check(err == nil and cp.model == "qwen3:8b", "expected default qwen3:8b model")
    check(cp.reasoning_effort == nil, "reasoning_effort must stay unset by default so non-thinking models do not 400")

    gp = agent_ollama.ollama_generate_payload(nil, nil, "Summarize", "full")
    check(gp.model == "qwen3:8b" and gp.reasoning_effort == nil, "generate payload uses default model without reasoning_effort")

    function fake_post(endpoint, payload)
        check(endpoint == "embeddings" and payload.model == "nomic-embed-text", "expected embeddings endpoint and default model")
        -- Return out of order on purpose to verify index sorting
        return {
            data = {
                {index = 1, embedding = {0.4, 0.5}},
                {index = 0, embedding = {0.1, 0.2}},
            },
        }, nil
    end
    vecs, embed_err = agent_ollama.ollama_embed_batch_with(fake_post, nil, {"first", "second"})
    check(embed_err == nil and #vecs == 2, "expected 2 vectors")
    check(vecs[1][1] == 0.1 and vecs[2][1] == 0.4, "expected vectors ordered by item.index")
end

function tests.every_shipped_agent_tool_maps_cleanly_to_ollama_wire_format()
    print("Testing every built-in AGENT_TOOLS declaration translates cleanly through ollama_tools_from_canonical")
    agent = require("agent")
    decls = agent.tool_declarations()
    wire_tools, err = agent_ollama.ollama_tools_from_canonical(decls)
    check(err == nil and wire_tools != nil and #wire_tools == #decls,
        "every built-in daat tool must satisfy Ollama/OpenAI's 64-char charset rule, got err: " .. tostring(err))
    for i, wt in ipairs(wire_tools) do
        back = agent_ollama.ollama_canonical_tool_name(wt["function"].name)
        check(back == decls[i].name, "round-trip mismatch for " .. tostring(decls[i].name))
    end
end

unit.run(tests)
