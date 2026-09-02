-- Google Vertex AI backend for agent_provider's generate/converse/
-- embeddings interface. Calls Vertex's REST API directly
-- (generateContent for text and structured tool-calling, predict for
-- embeddings) via a curl shell-out authenticated with a fresh
-- Application Default Credentials access token -- not a vendored
-- HTTP/TLS client or a Google client library, matching the "bind to an
-- existing, battle-tested tool" stance already used for bcrypt/HMAC/
-- cmark. Verified against a real project (celleste-elab): gemini-3.5-
-- flash-lite for generation (brex 153144598 -- migrated off gemini-2.5-
-- flash ahead of its 2026-10-20 Vertex deprecation), text-embedding-005
-- for embeddings, both confirmed live.
--
-- .converse() (native structured tool-calling) translates agent.lua's
-- own provider-agnostic canonical shape (see agent_provider.lua's own
-- header and doc/agent-protocol.md -- roles user/assistant/toolResult,
-- block types text/toolCall/thinking) into Vertex's real wire shapes and
-- back. All of that translation is contained in this one file --
-- vertex_contents_from_messages/vertex_blocks_from_parts below -- agent.lua
-- itself never changes and never learns anything Vertex-specific.
-- Real wire shapes here, verified live against the actual API:
-- thinking parts are {text, thought=true}, and any part -- a
-- functionCall, or the final text/thinking part of a response -- may
-- carry a thoughtSignature (that exact camelCase name since it's
-- Vertex's own wire field, not this codebase's choice), preserved on
-- our own block as a plain snake_case thinking_signature -- self-
-- contained round-trip plumbing between this file's own
-- vertex_blocks_from_parts/vertex_contents_from_messages, not part of
-- the pre-existing stopReason/toolCallId-style canonical contract
-- agent.lua actually reads, so it follows this codebase's own Lua
-- naming rather than Vertex's own. On a Gemini 3.x model this is not
-- merely a round-trip nicety for a functionCall part specifically:
-- omitting a functionCall's own thoughtSignature on the very next
-- request is a real, confirmed-live 400 INVALID_ARGUMENT ("Function
-- call ... is missing a thought_signature"), not just degraded
-- reasoning quality -- Gemini 2.5 never enforced this. On a parallel
-- tool-call turn (2+ functionCall parts in one response), Vertex
-- attaches thoughtSignature to the first functionCall part only;
-- confirmed live that a subsequent parallel call in the same response
-- carries none, and none needs to be echoed back for it either -- this
-- file's per-part capture already handles that correctly by construc-
-- tion, since a part with no signature on the wire just never sets
-- thinking_signature on its own block. On a plain final-answer part,
-- returning a captured signature is recommended (better reasoning
-- continuity across turns) but not enforced -- confirmed live that
-- omitting it there causes no error.
--
-- A landmine worth naming explicitly, since it looks like the obvious
-- fix and isn't: Gemini 3 also started returning a real `id` alongside
-- every functionCall (e.g. "call_1419080") -- the direct Gemini API's
-- own docs say to echo it back on the matching functionResponse's own
-- `id` field for correlation. Do NOT do that here: confirmed live that
-- Vertex AI's generateContent proto (unlike the direct Gemini API)
-- rejects a functionCall/functionResponse part that carries an `id` at
-- all, 400 INVALID_ARGUMENT, a known cross-vendor compatibility gap as
-- of this writing. This file deliberately keeps synthesizing its own
-- call_N ids for agent.lua's own tool_result correlation (see
-- vertex_blocks_from_parts below) and never reads or sends Vertex's
-- real functionCall.id at all -- correlation by name, in declaration
-- order, remains correct here since Vertex's own functionResponse
-- parts are matched to functionCall parts positionally within one
-- contents[] entry, not by id.
--
-- finishReason is "STOP" identically whether a turn ends in a tool call
-- or a final answer -- stopReason has to be derived from whether a
-- functionCall part is actually present, not from finishReason alone.
--
-- Requires `gcloud` on PATH, already authenticated (`gcloud auth
-- application-default login`), and two platform.lua fields (see
-- config.platform_config()): vertex_project (required, no default --
-- this is a real, potentially billed GCP project, never hardcoded
-- here) and vertex_region (optional, defaults to us-central1).

json = require("dkjson")
config = require("config")
external_tool = require("external_tool")

agent_vertex = {}

-- Confirmed live: gemini-3.5-flash-lite (config.lua's own default
-- agent_model as of brex 153144598) 404s on a regional endpoint like
-- us-central1 -- "global" is not just an option for a 3.x-family model,
-- it's the only location that actually serves one. Falls back to this
-- only when platform.lua sets no vertex_region of its own; a
-- deployment that deliberately picked a regional model (or a real
-- future one that does support regional locations) can still override
-- it explicitly.
DEFAULT_REGION = "global"

function vertex_config()
    conf = config.platform_config()
    project = conf.vertex_project
    if project == nil or project == "" then
        return nil, nil, "vertex_project is not set in platform.lua"
    end
    region = conf.vertex_region
    if region == nil or region == "" then
        region = DEFAULT_REGION
    end
    return project, region
end

-- A fresh bearer token per call, not cached -- ADC tokens are
-- short-lived (about an hour) and re-fetching costs one extra `gcloud`
-- invocation, negligible next to the LLM call itself.
function vertex_access_token()
    token, err = external_tool.capture("gcloud auth application-default print-access-token 2>/dev/null")
    if token == nil then
        return nil, "cannot get gcloud access token: " .. tostring(err)
    end
    token = string.gsub(token, "%s+$", "")
    if token == "" then
        return nil, "empty access token -- is 'gcloud auth application-default login' configured?"
    end
    return token
end

-- Every regional/multi-regional location uses a
-- "{region}-aiplatform.googleapis.com" subdomain, but "global" (required
-- for current-generation Gemini models not yet available in any
-- regional location, e.g. the 3.x family as of 2026-08) has no such
-- subdomain -- confirmed live: "global-aiplatform.googleapis.com" does
-- not resolve as an API host at all, only the bare host does.
function vertex_url(project, region, model_and_method_path)
    host = "aiplatform.googleapis.com"
    if region != "global" then
        host = region .. "-" .. host
    end
    return "https://" .. host .. "/v1/projects/" .. project ..
        "/locations/" .. region .. "/publishers/google/models/" .. model_and_method_path
end

-- POSTs `payload_table` (JSON-encoded) to
-- .../publishers/google/models/<model_and_method_path>, via a temp
-- file (curl -d @file) rather than shell-interpolating the payload
-- directly -- the only shell-interpolated values are the URL and a
-- path this process generated itself, never prompt/response content.
function vertex_post(model_and_method_path, payload_table)
    project, region, config_err = vertex_config()
    if project == nil then
        return nil, config_err
    end
    token, token_err = vertex_access_token()
    if token == nil then
        return nil, token_err
    end

    url = vertex_url(project, region, model_and_method_path)

    response_text, _ = external_tool.with_temp_file(json.encode(payload_table), "w", function(tmp_path)
        cmd = "curl -s -X POST " .. external_tool.shell_quote(url) ..
            " -H " .. external_tool.shell_quote("Authorization: Bearer " .. token) ..
            " -H " .. external_tool.shell_quote("Content-Type: application/json") ..
            " -d @" .. external_tool.shell_quote(tmp_path)
        return external_tool.capture(cmd)
    end)

    if response_text == nil then
        return nil, "no response from Vertex AI (curl/network failure)"
    end

    response, _, decode_err = json.decode(response_text)
    if response == nil then
        return nil, "invalid JSON response from Vertex AI: " .. tostring(decode_err)
    end
    if response.error != nil then
        return nil, "Vertex AI error: " .. tostring(response.error.message)
    end
    return response
end

-- `usageMetadata` (promptTokenCount/candidatesTokenCount/totalTokenCount)
-- is a real field on every generateContent response -- knowledge_context
-- (see doc/architecture.md's "Knowledge pool" section) needs real token
-- accounting, not just agent.estimate_tokens' char/4 heuristic (still
-- used for compaction thresholding, unrelated). Absent entirely just
-- means a nil-valued table, not an error -- older API versions or a
-- malformed response shouldn't fail generation over accounting metadata.
function usage_from_response(response)
    meta = response.usageMetadata
    if meta == nil then
        return {prompt_tokens = nil, completion_tokens = nil, total_tokens = nil}
    end
    return {
        prompt_tokens = meta.promptTokenCount,
        completion_tokens = meta.candidatesTokenCount,
        total_tokens = meta.totalTokenCount,
    }
end

-- agent.lua's own AGENT_TOOLS (see doc/agent-protocol.md) declares
-- `parameters` as plain, standard JSON Schema -- lowercase `type`
-- ("object"/"string"/"integer"/etc.) -- daat's own neutral
-- contract, not any one vendor's dialect. Vertex/Gemini's real
-- functionDeclarations Schema requires the uppercase proto enum instead
-- ("OBJECT"/"STRING"/"INTEGER") -- a real Vertex call rejects lowercase
-- `type` outright. This function is this file's own half of that
-- translation (agent_claude.lua
-- has the equivalent, much smaller, translation for Claude's dialect,
-- which is already lowercase JSON Schema) -- recurses into `properties`
-- (each value) and `items` (for arrays); every other key (description,
-- required, additionalProperties) passes through unchanged.
VERTEX_TYPE_ENUM = {
    object = "OBJECT", string = "STRING", integer = "INTEGER",
    number = "NUMBER", boolean = "BOOLEAN", array = "ARRAY",
}

function vertex_schema_from_canonical(schema)
    if type(schema) != "table" then
        return schema
    end
    out = {}
    for k, v in pairs(schema) do
        if k == "type" and VERTEX_TYPE_ENUM[v] != nil then
            out[k] = VERTEX_TYPE_ENUM[v]
        elseif k == "properties" then
            props = {}
            for prop_name, prop_schema in pairs(v) do
                props[prop_name] = vertex_schema_from_canonical(prop_schema)
            end
            -- Same empty-table/dkjson object-vs-array ambiguity
            -- AGENT_TOOLS' own EMPTY_OBJECT_SCHEMA already works around
            -- (agent.lua) -- preserve it through translation instead of
            -- re-triggering the same live 400 INVALID_ARGUMENT.
            if next(props) == nil then
                setmetatable(props, {__jsontype = "object"})
            end
            out[k] = props
        elseif k == "items" then
            out[k] = vertex_schema_from_canonical(v)
        else
            out[k] = v
        end
    end
    return out
end

-- Applies vertex_schema_from_canonical to every declared tool's
-- `parameters`, leaving `name`/`description` untouched.
function vertex_tools_from_canonical(tools)
    translated = {}
    for _, tool in ipairs(tools) do
        table.insert(translated, {
            name = tool.name,
            description = tool.description,
            parameters = vertex_schema_from_canonical(tool.parameters),
        })
    end
    return translated
end

-- Maps agent.lua's own canonical message-history shape (build_history_
-- messages: role user/assistant/toolResult, assistant content is
-- always a block array, toolResult content is always a single-block
-- array) into Vertex's real generateContent `contents[]` shape.
-- compaction_summary/self_check rows already arrive here pre-flattened
-- to role "user" by build_history_messages itself, so no separate case
-- is needed for them.
function vertex_contents_from_messages(messages)
    contents = {}
    if messages == nil then
        return contents
    end
    for _, msg in ipairs(messages) do
        if msg.role == "user" then
            table.insert(contents, {role = "user", parts = {{text = tostring(msg.content)}}})
        elseif msg.role == "assistant" then
            parts = {}
            for _, block in ipairs(msg.content) do
                part = nil
                if block.type == "text" and block.text != nil then
                    part = {text = block.text}
                elseif block.type == "thinking" and block.thinking != nil then
                    part = {text = block.thinking, thought = true}
                elseif block.type == "toolCall" then
                    part = {functionCall = {name = block.name, args = block.arguments}}
                end
                if part != nil then
                    -- thoughtSignature is mandatory to echo back on a
                    -- functionCall part (see this file's own header --
                    -- omitting it on a Gemini 3.x model is a real,
                    -- confirmed-live 400, not just a quality nicety) and
                    -- merely recommended on a text/thinking part -- both
                    -- cases are the same "if we captured one on the way
                    -- in, send the same one back verbatim" rule, so
                    -- there's no reason to special-case which block
                    -- types get it.
                    if block.thinking_signature != nil then
                        part.thoughtSignature = block.thinking_signature
                    end
                    table.insert(parts, part)
                end
            end
            if #parts > 0 then
                table.insert(contents, {role = "model", parts = parts})
            end
        elseif msg.role == "toolResult" then
            text = ""
            if msg.content != nil and msg.content[1] != nil then
                text = tostring(msg.content[1].text)
            end
            part = {functionResponse = {name = msg.toolName, response = {content = text}}}
            -- Gemini requires every functionResponse part answering one
            -- functionCall turn to arrive together, in the SAME
            -- contents[] entry: a parallel-tool-call turn (2+ toolCall
            -- blocks in one assistant turn) produces consecutive
            -- canonical toolResult messages, one per call (see
            -- agent.lua's run_turn/run_research_loop) -- splitting these
            -- into separate {role="user",...} entries makes Vertex
            -- reject the next request outright ("Please ensure that the
            -- number of function response parts is equal to the number
            -- of function call parts of the function call turn.").
            -- `is_tool_response_group` is a purely internal marker
            -- distinguishing a merged-responses entry from an ordinary
            -- plain-text user message (both map to Vertex role "user",
            -- so checking `.role` alone would wrongly merge a genuine
            -- new user message into a preceding tool-response group too)
            -- -- stripped before this function returns, never sent to
            -- Vertex.
            previous = contents[#contents]
            if previous != nil and previous.is_tool_response_group == true then
                table.insert(previous.parts, part)
            else
                table.insert(contents, {role = "user", parts = {part}, is_tool_response_group = true})
            end
        end
    end
    for _, entry in ipairs(contents) do
        entry.is_tool_response_group = nil
    end
    return contents
end

-- The reverse direction: a real generateContent response's
-- candidates[1].content.parts into the canonical block shape, plus
-- whether any part was a tool call (stopReason has to be derived from
-- this, not from finishReason alone -- see this file's own header).
-- Tool-call ids are synthesized here, fresh per response, deliberately
-- ignoring Gemini 3's own real functionCall.id -- see this file's own
-- header on why Vertex's proto can't take that id back on a
-- functionResponse -- so these only ever need to be unique within this
-- one turn, for agent.lua's own tool_result correlation.
function vertex_blocks_from_parts(parts)
    blocks = {}
    has_tool_call = false
    call_index = 0
    for _, part in ipairs(parts) do
        block = nil
        if part.functionCall != nil then
            has_tool_call = true
            call_index = call_index + 1
            block = {
                type = "toolCall",
                id = "call_" .. tostring(call_index),
                name = part.functionCall.name,
                arguments = part.functionCall.args,
            }
        elseif part.thought == true and part.text != nil then
            block = {type = "thinking", thinking = part.text}
        elseif part.text != nil then
            block = {type = "text", text = part.text}
        end
        if block != nil then
            -- Confirmed live: on a Gemini 3.x model, thoughtSignature
            -- can land on a functionCall part (mandatory to echo back)
            -- or on the final text/thinking part of a response
            -- (recommended, not enforced) -- captured uniformly here so
            -- vertex_contents_from_messages' own send-back logic doesn't
            -- need to special-case which block type it came from. On a
            -- parallel tool-call turn, only the first functionCall part
            -- carries one; a later part in the same response simply has
            -- none here, which is already the correct thing to send
            -- back (nothing).
            if part.thoughtSignature != nil then
                block.thinking_signature = part.thoughtSignature
            end
            table.insert(blocks, block)
        end
    end
    return blocks, has_tool_call
end

-- agent_vertex.converse(model, system_prompt, messages, tools)
--   -> (response, err, usage)
--
-- Same contract every agent_provider implementation shares (see
-- agent_provider.lua's own header) -- `response` (on
-- success) is {content = [...blocks...], stopReason = ...,
-- errorMessage = ...}, returned even when stopReason is "error" (a real
-- HTTP response came back, just an unusable one -- no candidates, or a
-- finishReason like SAFETY/RECITATION that means the model refused/was
-- blocked) since that's still real, structured information the caller
-- should record and act on. `nil, err` is reserved for a genuine
-- connectivity/auth-level failure (vertex_post's own existing
-- behavior, unchanged, shared with .generate()/.embeddings() below) --
-- the network call itself couldn't be completed at all, nothing
-- structured to return.
function agent_vertex.converse(model, system_prompt, messages, tools)
    payload = {contents = vertex_contents_from_messages(messages)}
    if system_prompt != nil and system_prompt != "" then
        payload.systemInstruction = {parts = {{text = system_prompt}}}
    end
    if tools != nil and #tools > 0 then
        payload.tools = {{functionDeclarations = vertex_tools_from_canonical(tools)}}
    end
    -- Gemini 2.5's own thought-summary feature -- unconditional;
    -- response content then includes real {type:"thinking",...} blocks
    -- alongside text/toolCall ones (agent.lua's own
    -- extract_thinking_text/display_blocks handle both).
    payload.generationConfig = {thinkingConfig = {includeThoughts = true}}

    response, err = vertex_post(model .. ":generateContent", payload)
    if response == nil then
        return nil, err
    end
    usage = usage_from_response(response)

    if response.candidates == nil or response.candidates[1] == nil then
        return {content = {}, stopReason = "error", errorMessage = "no candidates in Vertex AI response"}, nil, usage
    end
    candidate = response.candidates[1]
    if candidate.content == nil or candidate.content.parts == nil or #candidate.content.parts == 0 then
        return {content = {}, stopReason = "error",
            errorMessage = "empty response (finishReason: " .. tostring(candidate.finishReason) .. ")"}, nil, usage
    end

    blocks, has_tool_call = vertex_blocks_from_parts(candidate.content.parts)

    if has_tool_call == true then
        return {content = blocks, stopReason = "toolUse"}, nil, usage
    end
    if candidate.finishReason == "MAX_TOKENS" then
        return {content = blocks, stopReason = "length"}, nil, usage
    end
    if candidate.finishReason != nil and candidate.finishReason != "STOP" then
        -- SAFETY, RECITATION, OTHER, etc. -- a real response, just not
        -- one that reflects a genuine completed answer.
        return {content = {}, stopReason = "error",
            errorMessage = "Vertex AI stopped generating (finishReason: " .. tostring(candidate.finishReason) .. ")"}, nil, usage
    end
    return {content = blocks, stopReason = "stop"}, nil, usage
end

function agent_vertex.generate(model, system_prompt, prompt)
    payload = {
        contents = {{role = "user", parts = {{text = prompt}}}},
    }
    if system_prompt != nil and system_prompt != "" then
        payload.systemInstruction = {parts = {{text = system_prompt}}}
    end

    response, err = vertex_post(model .. ":generateContent", payload)
    if response == nil then
        return nil, err
    end
    if response.candidates == nil or response.candidates[1] == nil then
        return nil, "no candidates in Vertex AI response"
    end
    candidate = response.candidates[1]
    if candidate.content == nil or candidate.content.parts == nil or candidate.content.parts[1] == nil then
        return nil, "empty response (finishReason: " .. tostring(candidate.finishReason) .. ")"
    end
    return candidate.content.parts[1].text, nil, usage_from_response(response)
end

function agent_vertex.embeddings(model, text)
    response, err = vertex_post(model .. ":predict", {instances = {{content = text}}})
    if response == nil then
        return nil, err
    end
    if response.predictions == nil or response.predictions[1] == nil then
        return nil, "no predictions in Vertex AI response"
    end
    embedding = response.predictions[1].embeddings
    if embedding == nil or embedding.values == nil then
        return nil, "malformed embeddings response"
    end
    return embedding.values
end

-- Exposed purely so tst/unit/agent_vertex.lua can reach it
-- across the require() boundary -- see the matching comment in
-- agent_claude.lua.
agent_vertex.vertex_url = vertex_url
agent_vertex.vertex_blocks_from_parts = vertex_blocks_from_parts
agent_vertex.vertex_contents_from_messages = vertex_contents_from_messages

return agent_vertex
