-- Real, structured multi-provider tool-calling via the pi-ai bridge
-- (bridge/pi-bridge.mjs, backed by @earendil-works/pi-ai) -- replaces
-- agent_provider_vertex.lua's hand-rolled curl+regex approach. Chosen
-- over hand-porting per-provider wire protocols into Lua: pi-ai already
-- solves (and keeps up to date) the actual hard part -- each provider's
-- own function-calling schema, auth flow, and message format -- and
-- reimplementing that ourselves would mean perpetually chasing every
-- provider's own API evolution by hand, in a language with no HTTP
-- client or JSON-schema tooling of its own. See doc/architecture.md's
-- "Chat" section and the bridge's own header comment for the full
-- rationale.
--
-- Same one-shot-subprocess-per-call shape agent_provider_vertex.lua's
-- own curl shell-out already used (no daemon, matches this app's
-- per-request CGI architecture): write one JSON request to the bridge's
-- stdin, read one JSON response from its stdout, done. Requires `node`
-- on PATH and PI_BRIDGE_PATH pointing at the built bridge/dist/pi-bridge.cjs
-- (no default -- a real path this deployment's own Dockerfile sets).
--
-- Provider/model selection: AGENT_PROVIDER_NAME (a pi-ai provider id,
-- e.g. "google-vertex", "anthropic") and the existing AGENT_MODEL env
-- var (a model id within that provider, e.g. "gemini-2.5-flash") --
-- this is what actually makes "model-agnostic" real: switching
-- providers is these two env vars, not a new Lua file.

json = require("dkjson")

agent_provider_pi = {}

DEFAULT_PROVIDER = "google-vertex"

function pi_bridge_path()
    path = os.getenv("PI_BRIDGE_PATH")
    if path == nil or path == "" then
        return nil, "PI_BRIDGE_PATH env var is not set"
    end
    return path
end

function pi_provider_name()
    name = os.getenv("AGENT_PROVIDER_NAME")
    if name == nil or name == "" then
        return DEFAULT_PROVIDER
    end
    return name
end

-- Converts agent.lua's own message-list shape (role + content, where
-- content is either a plain string or an array of content blocks) into
-- exactly the JSON the bridge expects -- effectively a passthrough,
-- since agent.lua's shape was designed to mirror the bridge's Context
-- messages 1:1 (see agent.lua's build_history_messages).
function bridge_request(model, system_prompt, messages, tools)
    return {
        provider = pi_provider_name(),
        model = model,
        systemPrompt = system_prompt,
        messages = messages,
        tools = tools,
    }
end

-- Runs the bridge as a subprocess via a temp file for the request body
-- (same io.popen + temp-file pattern agent_provider_vertex.lua's own
-- vertex_post used for curl -- avoids shell-interpolating arbitrary
-- prompt/tool-result content) and reads its stdout back.
function run_bridge(bridge_path, request_table)
    tmp_path = os.tmpname()
    file = io.open(tmp_path, "w")
    if file == nil then
        return nil, "cannot create temp file for bridge request"
    end
    io.write(file, json.encode(request_table))
    io.close(file)

    cmd = "node " .. shell_quote_pi(bridge_path) .. " < " .. shell_quote_pi(tmp_path)
    handle = io.popen(cmd, "r")
    output = nil
    if handle != nil then
        output = io.read(handle, "*all")
        io.close(handle)
    end
    os.remove(tmp_path)

    if output == nil or output == "" then
        return nil, "no output from pi bridge (node/bridge invocation failure)"
    end

    response, _, decode_err = json.decode(output)
    if response == nil then
        return nil, "invalid JSON response from pi bridge: " .. tostring(decode_err) .. "; raw: " .. string.sub(output, 1, 500)
    end
    return response
end

function shell_quote_pi(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- agent_provider_pi.converse(model, system_prompt, messages, tools)
--   -> (response, err, usage)
--
-- `response` (on success) is the bridge's own decoded reply, keys
-- exactly as its JSON names them (camelCase, not translated to
-- snake_case anywhere in this file): {content = [...blocks...],
-- stopReason = ..., errorMessage = ...} -- returned even when
-- stopReason is "error"/"aborted" (the LLM call itself failed, e.g.
-- auth/rate-limit), since that's still real, structured information
-- the caller should record and act on, not the same thing as `err`
-- below, which means the bridge itself couldn't be reached or returned
-- unparseable output -- a genuine infrastructure failure with no
-- structured content to fall back on at all.
function agent_provider_pi.converse(model, system_prompt, messages, tools)
    bridge_path, path_err = pi_bridge_path()
    if bridge_path == nil then
        return nil, path_err
    end

    request = bridge_request(model, system_prompt, messages, tools)
    response, err = run_bridge(bridge_path, request)
    if response == nil then
        return nil, err
    end

    usage = nil
    if response.usage != nil then
        usage = {
            prompt_tokens = response.usage.input,
            completion_tokens = response.usage.output,
            total_tokens = response.usage.totalTokens,
        }
    end
    return response, nil, usage
end

-- Plain-text single-shot generation (agent.lua's compaction summarizer,
-- knowledge.lua's distill/link-evaluation calls) -- none of these need
-- tool-calling or multi-turn history, so rather than force every one of
-- them onto the structured Context shape, this just wraps converse()
-- with a single user turn and unwraps the first text block back out.
function agent_provider_pi.generate(model, system_prompt, prompt)
    response, err, usage = agent_provider_pi.converse(model, system_prompt, {{role = "user", content = prompt}}, {})
    if response == nil then
        return nil, err
    end
    text = first_text(response.content)
    if text == nil then
        error_message = response.errorMessage
        if error_message == nil then
            error_message = "no text content in response (stopReason: " .. tostring(response.stopReason) .. ")"
        end
        return nil, error_message
    end
    return text, nil, usage
end

function first_text(blocks)
    if blocks == nil then
        return nil
    end
    parts = {}
    for _, block in ipairs(blocks) do
        if block.type == "text" and block.text != nil then
            table.insert(parts, block.text)
        end
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts)
end

-- pi-ai has no embeddings API of its own (it's a chat/tool-calling
-- layer over provider chat endpoints, not a general model client) --
-- confirmed directly against its own source, not assumed. Embeddings
-- (semantic search over documents, see document.lua) stay on the
-- direct Vertex REST call agent_provider_vertex.lua already has and has
-- already been verified against production, rather than inventing a
-- second bridge for a capability the chosen library doesn't cover.
function agent_provider_pi.embeddings(model, text)
    vertex = require("agent_provider_vertex")
    return vertex.embeddings(model, text)
end

return agent_provider_pi
