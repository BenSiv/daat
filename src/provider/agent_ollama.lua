-- Local / open-weights backend for agent_provider's generate/converse/
-- embeddings interface, speaking the standard OpenAI-compatible HTTP API
-- (/v1/chat/completions and /v1/embeddings) via a curl shell-out.
--
-- Defaults to a local Ollama server at http://127.0.0.1:11434/v1 with
-- small open-weights defaults (qwen3:8b for chat/generation,
-- nomic-embed-text for embeddings) so an example or development
-- deployment works end-to-end -- tool-calling chat, semantic search,
-- distillation, curation -- with no cloud account, billed project or
-- API key. Because the wire protocol is standard /v1/chat/completions
-- and /v1/embeddings, pointing config.lua's `ollama_url` at another
-- OpenAI-compatible server (llama-server, vLLM, LM Studio, OpenRouter,
-- or OpenAI itself) works without code changes; when OLLAMA_API_KEY (or
-- OPENAI_API_KEY) is set in the environment, it is sent as a Bearer
-- token.
--
-- .converse() translates agent.lua's provider-agnostic canonical shape
-- (doc/agent-protocol.md -- roles user/assistant/toolResult, block
-- types text/toolCall/thinking) into /v1/chat/completions messages and
-- back inside this one file. Like Claude (#21), OpenAI-compatible
-- servers restrict function names to ^[a-zA-Z0-9_-]{1,64}$, so dotted
-- daat tool names (document.search) map to "__" on the wire and back.
--
-- Open-weights servers expose reasoning in three ways on
-- /v1/chat/completions: `message.reasoning` (Ollama, OpenRouter),
-- `message.reasoning_content` (vLLM, DeepSeek, llama-server
-- --reasoning-format deepseek), or a leading `<think>...</think>` tag
-- inside `message.content` (unparsed Qwen3 / DeepSeek-R1 outputs).
-- ollama_blocks_from_message handles all three: `<think>...</think>` is
-- always stripped from visible text so raw tags never leak into replies,
-- and captured reasoning is emitted as a canonical `thinking` block
-- whenever config.lua's `agent_thinking` is `"summary"` or `"full"`.
-- Outgoing `reasoning_effort` ("none" / "medium" / "high") is sent only
-- when config.lua opts in with `ollama_reasoning_effort = true`,
-- because Ollama and strict OpenAI servers return HTTP 400 when
-- `reasoning_effort` is sent to a model without thinking support
-- (e.g. llama3.2, gemma3).

json = require("dkjson")
config = require("config")
external_tool = require("external_tool")

agent_ollama = {}

agent_ollama.default_model = "qwen3:8b"
agent_ollama.default_embedding_model = "nomic-embed-text"

DEFAULT_OLLAMA_URL = "http://127.0.0.1:11434/v1"
REQUEST_TIMEOUT_SECONDS = 120
OLLAMA_TOOL_NAME_PATTERN = "^[a-zA-Z0-9_-]+$"
OLLAMA_TOOL_NAME_MAX = 64

function ollama_base_url()
    url = config.setting("ollama_url")
    if type(url) != "string" or url == "" then
        url = DEFAULT_OLLAMA_URL
    end
    return (string.gsub(url, "/+$", ""))
end

function ollama_api_key()
    key = os.getenv("OLLAMA_API_KEY")
    if key != nil and key != "" then
        return key
    end
    key = os.getenv("OPENAI_API_KEY")
    if key != nil and key != "" then
        return key
    end
    return nil
end

function ollama_endpoint_url(endpoint)
    path = string.gsub(tostring(endpoint), "^/+", "")
    return ollama_base_url() .. "/" .. path
end

function ollama_post(endpoint, payload_table)
    url = ollama_endpoint_url(endpoint)
    key = ollama_api_key()

    response_text, _ = external_tool.with_temp_file(json.encode(payload_table), "w", function(tmp_path)
        auth_header = ""
        if key != nil then
            auth_header = " -H " .. external_tool.shell_quote("Authorization: Bearer " .. key)
        end
        cmd = "curl -s --max-time " .. REQUEST_TIMEOUT_SECONDS ..
            " -X POST " .. external_tool.shell_quote(url) ..
            auth_header ..
            " -H " .. external_tool.shell_quote("content-type: application/json") ..
            " -d @" .. external_tool.shell_quote(tmp_path)
        return external_tool.capture(cmd)
    end)

    if response_text == nil or response_text == "" then
        return nil, "no response from Ollama/OpenAI API at " .. url .. " (curl/network failure)"
    end

    response, _, decode_err = json.decode(response_text)
    if response == nil then
        return nil, "invalid JSON response from Ollama/OpenAI API: " .. tostring(decode_err)
    end
    if response.error != nil then
        if type(response.error) == "table" then
            err_msg = response.error.message
            if err_msg == nil then
                err_msg = json.encode(response.error)
            end
            return nil, "Ollama/OpenAI API error: " .. tostring(err_msg)
        end
        return nil, "Ollama/OpenAI API error: " .. tostring(response.error)
    end
    return response
end

function usage_from_response(response)
    usage = response.usage
    if usage == nil then
        return {prompt_tokens = nil, completion_tokens = nil, total_tokens = nil}
    end
    prompt_tok = usage.prompt_tokens
    completion_tok = usage.completion_tokens
    total_tok = usage.total_tokens
    if total_tok == nil and prompt_tok != nil and completion_tok != nil then
        total_tok = prompt_tok + completion_tok
    end
    thought_tok = nil
    if type(usage.completion_tokens_details) == "table" then
        thought_tok = usage.completion_tokens_details.reasoning_tokens
    end
    return {
        prompt_tokens = prompt_tok,
        completion_tokens = completion_tok,
        total_tokens = total_tok,
        thought_tokens = thought_tok,
    }
end

function ollama_wire_tool_name(name)
    if type(name) != "string" or string.find(name, "__", 1, true) != nil then
        return nil, "tool name " .. tostring(name) .. " can't be sent to Ollama/OpenAI: it contains \"__\", which stands for \".\" on the wire"
    end
    wire = string.gsub(name, "%.", "__")
    if #wire > OLLAMA_TOOL_NAME_MAX or string.match(wire, OLLAMA_TOOL_NAME_PATTERN) == nil then
        return nil, "tool name " .. name .. " can't be sent to Ollama/OpenAI: it must be at most " .. OLLAMA_TOOL_NAME_MAX .. " letters, digits, '.', '_' or '-'"
    end
    return wire, nil
end

function ollama_canonical_tool_name(wire)
    if type(wire) != "string" then
        return wire
    end
    canonical = string.gsub(wire, "__", ".")
    return canonical
end

function ollama_tools_from_canonical(tools)
    translated = {}
    for _, tool in ipairs(tools) do
        wire, err = ollama_wire_tool_name(tool.name)
        if wire == nil then
            return nil, err
        end
        if type(tool.parameters) != "table" then
            return nil, "tool " .. tostring(tool.name) .. " has no parameters; Ollama/OpenAI requires parameters on every function tool"
        end
        table.insert(translated, {
            type = "function",
            ["function"] = {
                name = wire,
                description = tool.description,
                parameters = tool.parameters,
            },
        })
    end
    return translated, nil
end

function empty_json_object()
    return setmetatable({}, {__jsontype = "object"})
end

function ollama_messages_from_canonical(system_prompt, messages)
    result = {}
    if system_prompt != nil and system_prompt != "" then
        table.insert(result, {role = "system", content = system_prompt})
    end
    if messages == nil then
        return result
    end
    call_seq = 0
    for _, msg in ipairs(messages) do
        if msg.role == "user" then
            table.insert(result, {role = "user", content = tostring(msg.content)})
        elseif msg.role == "assistant" then
            text_parts = {}
            tool_calls = {}
            content_blocks = msg.content
            if type(content_blocks) != "table" then
                content_blocks = {}
            end
            for _, block in ipairs(content_blocks) do
                if block.type == "text" and block.text != nil and block.text != "" then
                    table.insert(text_parts, block.text)
                elseif block.type == "toolCall" then
                    call_seq = call_seq + 1
                    wire_name = ollama_wire_tool_name(block.name)
                    if wire_name == nil then
                        wire_name = block.name
                    end
                    args_obj = block.arguments
                    if type(args_obj) != "table" then
                        args_obj = empty_json_object()
                    elseif next(args_obj) == nil then
                        args_obj = empty_json_object()
                    end
                    call_id = block.id
                    if type(call_id) != "string" or call_id == "" then
                        call_id = "call_" .. call_seq
                    end
                    table.insert(tool_calls, {
                        id = call_id,
                        type = "function",
                        ["function"] = {
                            name = wire_name,
                            arguments = json.encode(args_obj),
                        },
                    })
                end
            end
            text_joined = table.concat(text_parts, "\n")
            if #tool_calls > 0 then
                table.insert(result, {
                    role = "assistant",
                    content = text_joined,
                    tool_calls = tool_calls,
                })
            elseif text_joined != "" then
                table.insert(result, {role = "assistant", content = text_joined})
            end
        elseif msg.role == "toolResult" then
            text = ""
            if msg.content != nil and msg.content[1] != nil and msg.content[1].text != nil then
                text = tostring(msg.content[1].text)
            end
            tc_id = ""
            if msg.toolCallId != nil then
                tc_id = tostring(msg.toolCallId)
            end
            table.insert(result, {
                role = "tool",
                tool_call_id = tc_id,
                content = text,
            })
        end
    end
    return result
end

-- Splits leading `<think>...</think>` blocks out of raw message content
-- when an open-weights server hasn't already moved them into `reasoning`
-- / `reasoning_content`. Always strips the tags from visible text so
-- raw `<think>` markup never reaches a reply.
function split_think_tags(raw_text)
    if type(raw_text) != "string" or raw_text == "" then
        return nil, nil
    end
    thoughts = {}
    rest = raw_text
    while true do
        s, e, inner = string.find(rest, "^%s*<think>(.-)</think>%s*")
        if s == nil then
            break
        end
        trimmed = string.gsub(inner, "^%s*(.-)%s*$", "%1")
        if trimmed != "" then
            table.insert(thoughts, trimmed)
        end
        rest = string.sub(rest, e + 1)
    end
    thinking = nil
    if #thoughts > 0 then
        thinking = table.concat(thoughts, "\n\n")
    end
    visible = nil
    if rest != "" then
        visible = rest
    end
    return visible, thinking
end

function decode_tool_arguments(raw_args)
    if type(raw_args) == "table" then
        return raw_args
    end
    if type(raw_args) != "string" or string.match(raw_args, "^%s*$") != nil then
        return empty_json_object()
    end
    decoded, _, _ = json.decode(raw_args)
    if type(decoded) == "table" then
        return decoded
    end
    return empty_json_object()
end

function effective_thinking_mode(thinking_mode)
    if thinking_mode != nil then
        return thinking_mode
    end
    return config.load().agent_thinking
end

function ollama_reasoning_effort(thinking_mode)
    if config.setting("ollama_reasoning_effort") != true then
        return nil
    end
    mode = effective_thinking_mode(thinking_mode)
    if mode == "summary" then
        return "medium"
    end
    if mode == "full" then
        return "high"
    end
    return "none"
end

function ollama_blocks_from_message(message, thinking_mode)
    blocks = {}
    if type(message) != "table" then
        return blocks, false
    end
    mode = effective_thinking_mode(thinking_mode)

    thinking_parts = {}
    wire_reasoning = message.reasoning
    if type(wire_reasoning) != "string" or wire_reasoning == "" then
        wire_reasoning = message.reasoning_content
    end
    if type(wire_reasoning) == "string" then
        trimmed_wire = string.gsub(wire_reasoning, "^%s*(.-)%s*$", "%1")
        if trimmed_wire != "" then
            table.insert(thinking_parts, trimmed_wire)
        end
    end

    visible_text, tag_thinking = split_think_tags(message.content)
    if tag_thinking != nil then
        table.insert(thinking_parts, tag_thinking)
    end

    if mode != "off" and #thinking_parts > 0 then
        table.insert(blocks, {type = "thinking", thinking = table.concat(thinking_parts, "\n\n")})
    end
    if visible_text != nil and visible_text != "" then
        table.insert(blocks, {type = "text", text = visible_text})
    end

    has_tool_calls = false
    if type(message.tool_calls) == "table" then
        for i, tc in ipairs(message.tool_calls) do
            fn = tc["function"]
            if type(fn) != "table" then
                fn = {}
            end
            call_id = tc.id
            if type(call_id) != "string" or call_id == "" then
                call_id = "call_" .. i
            end
            table.insert(blocks, {
                type = "toolCall",
                id = call_id,
                name = ollama_canonical_tool_name(fn.name),
                arguments = decode_tool_arguments(fn.arguments),
            })
            has_tool_calls = true
        end
    end
    return blocks, has_tool_calls
end

-- Local OpenAI-compatible servers occasionally report finish_reason =
-- "stop" even when tool_calls are present; derive "toolUse" whenever a
-- toolCall block is actually returned, matching agent_vertex.lua.
function ollama_finish_reason_to_canonical(finish_reason, has_tool_calls)
    if has_tool_calls == true or finish_reason == "tool_calls" then
        return "toolUse"
    end
    if finish_reason == "stop" then
        return "stop"
    end
    if finish_reason == "length" then
        return "length"
    end
    return "error"
end

function ollama_converse_payload(model, system_prompt, messages, tools, thinking_mode)
    if model == nil or model == "" then
        model = agent_ollama.default_model
    end
    payload = {
        model = model,
        messages = ollama_messages_from_canonical(system_prompt, messages),
    }
    effort = ollama_reasoning_effort(thinking_mode)
    if effort != nil then
        payload.reasoning_effort = effort
    end
    if tools != nil and #tools > 0 then
        wire_tools, tools_err = ollama_tools_from_canonical(tools)
        if wire_tools == nil then
            return nil, tools_err
        end
        payload.tools = wire_tools
    end
    return payload, nil
end

function agent_ollama.converse(model, system_prompt, messages, tools)
    payload, payload_err = ollama_converse_payload(model, system_prompt, messages, tools, nil)
    if payload == nil then
        return nil, payload_err
    end

    response, err = ollama_post("chat/completions", payload)
    if response == nil then
        return nil, err
    end
    usage = usage_from_response(response)

    choice = nil
    if type(response.choices) == "table" then
        choice = response.choices[1]
    end
    if choice == nil or choice.message == nil then
        return {content = {}, stopReason = "error",
            errorMessage = "empty response from Ollama/OpenAI API (no choices)"}, nil, usage
    end

    blocks, has_tool_calls = ollama_blocks_from_message(choice.message, nil)
    canonical_stop = ollama_finish_reason_to_canonical(choice.finish_reason, has_tool_calls)
    if canonical_stop == "error" then
        return {content = {}, stopReason = "error",
            errorMessage = "Ollama/OpenAI API stopped generating (finish_reason: " .. tostring(choice.finish_reason) .. ")"}, nil, usage
    end
    if #blocks == 0 then
        return {content = {}, stopReason = "error",
            errorMessage = "empty response (finish_reason: " .. tostring(choice.finish_reason) .. ")"}, nil, usage
    end
    return {content = blocks, stopReason = canonical_stop}, nil, usage
end

function ollama_text_and_thinking_from_message(message, thinking_mode)
    blocks, _ = ollama_blocks_from_message(message, thinking_mode)
    text_parts = {}
    thinking_parts = {}
    for _, block in ipairs(blocks) do
        if block.type == "text" and block.text != nil then
            table.insert(text_parts, block.text)
        elseif block.type == "thinking" and block.thinking != nil then
            table.insert(thinking_parts, block.thinking)
        end
    end
    text = nil
    if #text_parts > 0 then
        text = table.concat(text_parts, "\n")
    end
    thinking = nil
    if #thinking_parts > 0 then
        thinking = table.concat(thinking_parts, "\n\n")
    end
    return text, thinking
end

function ollama_generate_payload(model, system_prompt, prompt, thinking_mode)
    if model == nil or model == "" then
        model = agent_ollama.default_model
    end
    payload = {
        model = model,
        messages = ollama_messages_from_canonical(system_prompt, {{role = "user", content = tostring(prompt)}}),
    }
    effort = ollama_reasoning_effort(thinking_mode)
    if effort != nil then
        payload.reasoning_effort = effort
    end
    return payload
end

function agent_ollama.generate(model, system_prompt, prompt)
    payload = ollama_generate_payload(model, system_prompt, prompt, nil)

    response, err = ollama_post("chat/completions", payload)
    if response == nil then
        return nil, err
    end
    choice = nil
    if type(response.choices) == "table" then
        choice = response.choices[1]
    end
    if choice == nil or choice.message == nil then
        return nil, "empty response from Ollama/OpenAI API (no choices)"
    end
    text, thinking = ollama_text_and_thinking_from_message(choice.message, nil)
    if text == nil then
        return nil, "empty response (finish_reason: " .. tostring(choice.finish_reason) .. ")"
    end
    return text, nil, usage_from_response(response), thinking
end

function ollama_embed_batch_with(post, model, texts)
    if model == nil or model == "" then
        model = agent_ollama.default_embedding_model
    end
    if texts == nil or #texts == 0 then
        return {}
    end
    response, err = post("embeddings", {model = model, input = texts})
    if response == nil then
        return nil, err
    end
    if type(response.data) != "table" or #response.data != #texts then
        got_n = "nil"
        if type(response.data) == "table" then
            got_n = tostring(#response.data)
        end
        return nil, "Ollama/OpenAI API returned " .. got_n .. " embeddings for " .. #texts .. " texts"
    end
    ordered = {}
    for pos, item in ipairs(response.data) do
        if type(item) != "table" or type(item.embedding) != "table" then
            return nil, "malformed embeddings response"
        end
        slot = pos
        if type(item.index) == "number" then
            slot = item.index + 1
        end
        ordered[slot] = item.embedding
    end
    vectors = {}
    for i = 1, #texts do
        if ordered[i] == nil then
            return nil, "missing embedding at index " .. tostring(i - 1)
        end
        table.insert(vectors, ordered[i])
    end
    return vectors
end

function agent_ollama.embeddings_batch(model, texts)
    return ollama_embed_batch_with(ollama_post, model, texts)
end

function agent_ollama.embeddings(model, text)
    vectors, err = ollama_embed_batch_with(ollama_post, model, {text})
    if vectors == nil then
        return nil, err
    end
    return vectors[1], nil
end

-- Exposed for unit testing across require(), matching agent_claude.lua
-- and agent_vertex.lua.
agent_ollama.ollama_endpoint_url = ollama_endpoint_url
agent_ollama.ollama_wire_tool_name = ollama_wire_tool_name
agent_ollama.ollama_canonical_tool_name = ollama_canonical_tool_name
agent_ollama.ollama_tools_from_canonical = ollama_tools_from_canonical
agent_ollama.ollama_messages_from_canonical = ollama_messages_from_canonical
agent_ollama.ollama_blocks_from_message = ollama_blocks_from_message
agent_ollama.ollama_finish_reason_to_canonical = ollama_finish_reason_to_canonical
agent_ollama.ollama_converse_payload = ollama_converse_payload
agent_ollama.ollama_generate_payload = ollama_generate_payload
agent_ollama.ollama_text_and_thinking_from_message = ollama_text_and_thinking_from_message
agent_ollama.ollama_embed_batch_with = ollama_embed_batch_with
agent_ollama.split_think_tags = split_think_tags

return agent_ollama
