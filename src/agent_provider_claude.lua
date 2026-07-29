-- Anthropic Claude backend for agent_provider's generate/converse/
-- embeddings interface. Calls the Messages API directly
-- (https://api.anthropic.com/v1/messages) via a curl shell-out --
-- same "bind to an existing, battle-tested tool" stance as
-- agent_provider_vertex.lua, no vendored HTTP/TLS client, no Node/pi-ai
-- bridge process.
--
-- .converse() translates agent.lua's own provider-agnostic canonical
-- shape (see agent_provider.lua's own header, and doc/agent-protocol.md
-- -- roles user/assistant/toolResult, block types text/toolCall/
-- thinking) into Claude's real wire shapes and back. All of that
-- translation is contained in this one file -- claude_messages_from_
-- canonical/claude_blocks_from_content below -- agent.lua itself never
-- learns anything Claude-specific, the same way it never learns
-- anything Vertex-specific.
--
-- Unlike agent_provider_vertex.lua's schema translation (canonical
-- lowercase JSON Schema -> Vertex's uppercase proto enum), Claude's own
-- `input_schema` is already standard lowercase JSON Schema -- tool
-- declarations pass through close to as-is here, the concrete payoff
-- of the canonical protocol being a real neutral standard rather than
-- one vendor's dialect (see agent.lua's own AGENT_TOOLS header comment).
--
-- Claude's tool_use blocks carry a real, stable id from Anthropic
-- itself (the "toolu_..." prefix) -- unlike Vertex's wire protocol
-- (which has no id concept for function calls at all, forcing
-- agent_provider_vertex.lua to synthesize one), this file uses
-- Claude's own id directly as the canonical toolCall block's `id`, and
-- threads it back verbatim in the following turn's tool_result block.
--
-- Deliberately NOT using any of Claude's native server-executed tools
-- (web_search/code_execution/etc.) -- those execute on Anthropic's own
-- infrastructure before this file ever sees them, which means they
-- can't be gated by the pending-approval flow agent.lua already applies
-- to every destructive tool call. A web-search capability, if added
-- later, belongs in AGENT_TOOLS as an ordinary custom tool backed by
-- our own search-API call, going through that same approval gate --
-- not as one of Claude's server tools. See doc/agent-protocol.md.
--
-- Requires ANTHROPIC_API_KEY in the environment (PassEnv'd the same
-- way PLATFORM_MARIADB_PASSWORD already is -- see apache-platform.conf).

json = require("dkjson")

agent_provider_claude = {}

DEFAULT_MODEL = "claude-sonnet-5"
ANTHROPIC_VERSION = "2023-06-01"
ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"

function shell_quote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

function claude_api_key()
    key = os.getenv("ANTHROPIC_API_KEY")
    if key == nil or key == "" then
        return nil, "ANTHROPIC_API_KEY is not set"
    end
    return key
end

-- POSTs `payload_table` (JSON-encoded) to the Messages API, via a temp
-- file (curl -d @file) rather than shell-interpolating the payload
-- directly -- the only shell-interpolated value is the API key itself
-- (a fixed credential this process holds, never prompt/response
-- content), matching agent_provider_vertex.lua's own vertex_post().
function claude_post(payload_table)
    key, key_err = claude_api_key()
    if key == nil then
        return nil, key_err
    end

    tmp_path = os.tmpname()
    file = io.open(tmp_path, "w")
    if file == nil then
        return nil, "cannot create temp file for request body"
    end
    io.write(file, json.encode(payload_table))
    io.close(file)

    cmd = "curl -s -X POST " .. shell_quote(ANTHROPIC_API_URL) ..
        " -H " .. shell_quote("x-api-key: " .. key) ..
        " -H " .. shell_quote("anthropic-version: " .. ANTHROPIC_VERSION) ..
        " -H " .. shell_quote("content-type: application/json") ..
        " -d @" .. shell_quote(tmp_path)

    handle = io.popen(cmd, "r")
    response_text = nil
    if handle != nil then
        response_text = io.read(handle, "*all")
        io.close(handle)
    end
    os.remove(tmp_path)

    if response_text == nil or response_text == "" then
        return nil, "no response from Claude API (curl/network failure)"
    end

    response, _, decode_err = json.decode(response_text)
    if response == nil then
        return nil, "invalid JSON response from Claude API: " .. tostring(decode_err)
    end
    if response.type == "error" then
        return nil, "Claude API error: " .. tostring(response.error and response.error.message)
    end
    return response
end

function usage_from_response(response)
    usage = response.usage
    if usage == nil then
        return {prompt_tokens = nil, completion_tokens = nil, total_tokens = nil}
    end
    total = nil
    if usage.input_tokens != nil and usage.output_tokens != nil then
        total = usage.input_tokens + usage.output_tokens
    end
    return {
        prompt_tokens = usage.input_tokens,
        completion_tokens = usage.output_tokens,
        total_tokens = total,
    }
end

-- agent.lua's own AGENT_TOOLS declares `parameters` as plain, standard
-- JSON Schema already -- exactly what Claude's `input_schema` expects,
-- so this is closer to a pass-through than agent_provider_vertex.lua's
-- equivalent. Still a real, explicit translation step (not a shared
-- reference to AGENT_TOOLS' own tables) so this file never silently
-- depends on agent.lua's internal representation staying byte-for-byte
-- identical to Claude's -- if the canonical schema ever needs a key
-- Claude doesn't want (or vice versa), this is where that lives.
function claude_tools_from_canonical(tools)
    translated = {}
    for _, tool in ipairs(tools) do
        table.insert(translated, {
            name = tool.name,
            description = tool.description,
            input_schema = tool.parameters,
        })
    end
    return translated
end

-- Maps agent.lua's own canonical message-history shape (build_history_
-- messages: role user/assistant/toolResult, assistant content is
-- always a block array, toolResult content is always a single-block
-- array) into Claude's real Messages API `messages[]` shape. A
-- toolResult message becomes a `role: "user"` message with a single
-- `tool_result` content block, keyed by the real Claude tool_use id
-- this file itself set on the canonical toolCall block two turns
-- earlier (see claude_blocks_from_content below) -- not a synthesized
-- id the way Vertex needs.
function claude_messages_from_canonical(messages)
    result = {}
    if messages == nil then
        return result
    end
    for _, msg in ipairs(messages) do
        if msg.role == "user" then
            table.insert(result, {role = "user", content = tostring(msg.content)})
        elseif msg.role == "assistant" then
            blocks = {}
            for _, block in ipairs(msg.content) do
                if block.type == "text" and block.text != nil then
                    table.insert(blocks, {type = "text", text = block.text})
                elseif block.type == "thinking" and block.thinking != nil then
                    thinking_block = {type = "thinking", thinking = block.thinking}
                    if block.thinking_signature != nil then
                        thinking_block.signature = block.thinking_signature
                    end
                    table.insert(blocks, thinking_block)
                elseif block.type == "toolCall" then
                    table.insert(blocks, {type = "tool_use", id = block.id, name = block.name, input = block.arguments})
                end
            end
            if #blocks > 0 then
                table.insert(result, {role = "assistant", content = blocks})
            end
        elseif msg.role == "toolResult" then
            text = ""
            if msg.content != nil and msg.content[1] != nil then
                text = tostring(msg.content[1].text)
            end
            table.insert(result, {role = "user", content = {
                {type = "tool_result", tool_use_id = msg.toolCallId, content = text, is_error = msg.isError == true},
            }})
        end
    end
    return result
end

-- The reverse direction: a real Messages API response's `content[]`
-- into the canonical block shape, plus whether any block was a tool
-- call (stopReason is derived primarily from Claude's own stop_reason,
-- unlike Vertex which has to infer it from part presence -- see this
-- file's own converse()).
function claude_blocks_from_content(content)
    blocks = {}
    for _, block in ipairs(content) do
        if block.type == "text" and block.text != nil then
            table.insert(blocks, {type = "text", text = block.text})
        elseif block.type == "thinking" and block.thinking != nil then
            canonical_block = {type = "thinking", thinking = block.thinking}
            if block.signature != nil then
                canonical_block.thinking_signature = block.signature
            end
            table.insert(blocks, canonical_block)
        elseif block.type == "tool_use" then
            table.insert(blocks, {type = "toolCall", id = block.id, name = block.name, arguments = block.input})
        end
        -- server_tool_use/*_tool_result blocks deliberately unhandled --
        -- this file never declares a server tool (see header), so none
        -- should ever appear; if one did, dropping it silently would
        -- hide a real bug, so this is a place to add a loud error if
        -- server tools are ever adopted later, not before.
    end
    return blocks
end

-- agent_provider_claude.converse(model, system_prompt, messages, tools)
--   -> (response, err, usage)
--
-- Same contract every agent_provider implementation shares (see
-- agent_provider.lua's own header) -- `response` (on success) is
-- {content = [...blocks...], stopReason = ..., errorMessage = ...}.
-- Pure mapping, pulled out of converse() so it's directly unit-testable
-- without a real network call: Claude's stop_reason -> canonical
-- stopReason (see doc/agent-protocol.md). `stop_sequence`/`pause_turn`
-- (only reachable if a server tool were ever declared -- see this
-- file's own header) /`refusal`/anything else Anthropic adds later all
-- fall through to "error": a real response, just not a genuine
-- completed answer this file knows how to continue.
function claude_stop_reason_to_canonical(stop_reason)
    if stop_reason == "tool_use" then
        return "toolUse"
    end
    if stop_reason == "end_turn" then
        return "stop"
    end
    if stop_reason == "max_tokens" then
        return "length"
    end
    return "error"
end

-- `nil, err` is reserved for a genuine connectivity/auth-level failure
-- (claude_post's own behavior) -- the call itself couldn't be
-- completed, nothing structured to return.
function agent_provider_claude.converse(model, system_prompt, messages, tools)
    if model == nil or model == "" then
        model = DEFAULT_MODEL
    end
    payload = {
        model = model,
        max_tokens = 8192,
        messages = claude_messages_from_canonical(messages),
    }
    if system_prompt != nil and system_prompt != "" then
        payload.system = system_prompt
    end
    if tools != nil and #tools > 0 then
        payload.tools = claude_tools_from_canonical(tools)
    end

    response, err = claude_post(payload)
    if response == nil then
        return nil, err
    end
    usage = usage_from_response(response)

    if response.content == nil or #response.content == 0 then
        return {content = {}, stopReason = "error",
            errorMessage = "empty response (stop_reason: " .. tostring(response.stop_reason) .. ")"}, nil, usage
    end

    blocks = claude_blocks_from_content(response.content)
    canonical_stop_reason = claude_stop_reason_to_canonical(response.stop_reason)

    if canonical_stop_reason == "error" then
        return {content = {}, stopReason = "error",
            errorMessage = "Claude API stopped generating (stop_reason: " .. tostring(response.stop_reason) .. ")"}, nil, usage
    end
    return {content = blocks, stopReason = canonical_stop_reason}, nil, usage
end

function agent_provider_claude.generate(model, system_prompt, prompt)
    if model == nil or model == "" then
        model = DEFAULT_MODEL
    end
    payload = {
        model = model,
        max_tokens = 4096,
        messages = {{role = "user", content = tostring(prompt)}},
    }
    if system_prompt != nil and system_prompt != "" then
        payload.system = system_prompt
    end

    response, err = claude_post(payload)
    if response == nil then
        return nil, err
    end
    if response.content == nil or response.content[1] == nil or response.content[1].text == nil then
        return nil, "empty response (stop_reason: " .. tostring(response.stop_reason) .. ")"
    end
    return response.content[1].text, nil, usage_from_response(response)
end

-- No .embeddings -- Claude has no embeddings API. agent_provider.lua's
-- own dispatch already returns a clean "provider has no embeddings
-- support" error for a provider missing this, matching how any other
-- provider without one is already handled.

return agent_provider_claude
