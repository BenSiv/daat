-- A deterministic, cost-free provider for tests -- not a mock bolted
-- onto agent.lua, just another named backend behind agent_provider's
-- own dynamic-loading facade, selected the same way Vertex is (the
-- AGENT_PROVIDER env var). Running the real turn loop/compaction logic
-- against real Vertex AI on every test run would make the test suite
-- slow, flaky (network), and genuinely cost money on every invocation
-- -- fine for a handful of dedicated end-to-end confirmations, wrong
-- for routine test iteration.
--
-- Scripted via the AGENT_TEST_RESPONSES env var: a "\1"-delimited list
-- of canned responses, returned in order across successive generate()/
-- converse() calls within one process (a single web request's turn
-- loop can call either several times in a row -- e.g. compact_if_needed's
-- own generate() call, then run_turn's converse() calls -- see
-- agent.lua) -- one shared counter/list for both, since a real request
-- only ever exercises one or the other in any given test. Once the
-- list is exhausted, the last response repeats rather than erroring,
-- so a test that doesn't care about exact scripting still terminates.
--
-- generate() returns whatever scripted text as-is (no parsing -- its
-- callers just want plain text). converse() JSON-decodes each scripted
-- entry into the same {content, stopReason} shape agent_provider_pi's
-- real bridge returns -- e.g.
-- '{"content":[{"type":"text","text":"hi"}],"stopReason":"stop"}' or
-- '{"content":[{"type":"toolCall","id":"call_1","name":"document.search","arguments":{"query":"x"}}],"stopReason":"toolUse"}'
-- -- so the turn loop exercises the exact same structured dispatch
-- path real Vertex traffic does. With no script at all, converse()
-- replies with a plain "Test response." final answer so an unscripted
-- call still completes cleanly.

json = require("dkjson")

agent_provider_test = {}

TEST_RESPONSE_INDEX = 0

-- Same char/4 heuristic as agent.estimate_tokens (not cross-required
-- here to avoid coupling this standalone test provider to agent.lua's
-- own load order) -- deterministic stand-in usage numbers so
-- knowledge_context recording (task #87) has real, testable
-- prompt_tokens/completion_tokens even under the test provider,
-- instead of nils that would silently skip assertions.
function estimate_tokens_for_test(text)
    if text == nil then
        return 0
    end
    return math.ceil(string.len(text) / 4)
end

function agent_provider_test.generate(model, system_prompt, prompt)
    -- Optional: write the exact system_prompt this call received to a
    -- file, for tests asserting on it directly (e.g. task #70's
    -- deployment-configurable system_prompt_extra) rather than
    -- indirectly through model behavior. Off unless a test opts in --
    -- never touches the normal (no env var) test path.
    capture_path = os.getenv("AGENT_TEST_CAPTURE_SYSTEM_PROMPT")
    if capture_path != nil and capture_path != "" then
        capture_file = io.open(capture_path, "w")
        if capture_file != nil then
            io.write(capture_file, system_prompt)
            io.close(capture_file)
        end
    end

    TEST_RESPONSE_INDEX = TEST_RESPONSE_INDEX + 1
    raw = os.getenv("AGENT_TEST_RESPONSES")
    result = "<done>Test response.</done>"
    if raw != nil and raw != "" then
        responses = {}
        for piece in string.gmatch(raw, "([^\1]+)") do
            table.insert(responses, piece)
        end
        if responses[TEST_RESPONSE_INDEX] != nil then
            result = responses[TEST_RESPONSE_INDEX]
        else
            result = responses[#responses]
        end
    end
    usage = {
        prompt_tokens = estimate_tokens_for_test(system_prompt) + estimate_tokens_for_test(prompt),
        completion_tokens = estimate_tokens_for_test(result),
    }
    usage.total_tokens = usage.prompt_tokens + usage.completion_tokens
    return result, nil, usage
end

-- Same scripted-response mechanism as generate() (see this file's own
-- header) but returns the decoded structured shape converse() callers
-- expect, rather than raw text.
function agent_provider_test.converse(model, system_prompt, messages, tools)
    capture_path = os.getenv("AGENT_TEST_CAPTURE_SYSTEM_PROMPT")
    if capture_path != nil and capture_path != "" then
        capture_file = io.open(capture_path, "w")
        if capture_file != nil then
            io.write(capture_file, system_prompt)
            io.close(capture_file)
        end
    end

    -- A real tool-calling turn always passes a non-empty tools list
    -- (agent.tool_declarations() is never empty) -- an empty/nil tools
    -- list is a structural signal this is a no-tools call instead (in
    -- this app, only run_self_check makes one). Defaults to CONFIRM so
    -- every existing scripted test's own AGENT_TEST_RESPONSES sequence
    -- keeps completing in exactly the turn count it was written
    -- against, undisturbed -- self-check calls don't consume from that
    -- list at all. AGENT_TEST_SELF_CHECK_RESPONSE lets a test opt into
    -- a specific (e.g. non-confirm) self-check reply instead, to test
    -- the reject-and-continue path on purpose.
    if tools == nil or #tools == 0 then
        override = os.getenv("AGENT_TEST_SELF_CHECK_RESPONSE")
        if override != nil and override != "" then
            override_response, _, decode_err = json.decode(override)
            if override_response == nil then
                return nil, "AGENT_TEST_SELF_CHECK_RESPONSE is not valid JSON: " .. tostring(decode_err)
            end
            return override_response, nil, {prompt_tokens = 0, completion_tokens = 0, total_tokens = 0}
        end
        return {content = {{type = "text", text = "CONFIRM"}}, stopReason = "stop"}, nil, {prompt_tokens = 0, completion_tokens = 0, total_tokens = 0}
    end

    TEST_RESPONSE_INDEX = TEST_RESPONSE_INDEX + 1
    raw = os.getenv("AGENT_TEST_RESPONSES")
    scripted = nil
    if raw != nil and raw != "" then
        responses = {}
        for piece in string.gmatch(raw, "([^\1]+)") do
            table.insert(responses, piece)
        end
        if responses[TEST_RESPONSE_INDEX] != nil then
            scripted = responses[TEST_RESPONSE_INDEX]
        else
            scripted = responses[#responses]
        end
    end

    response = nil
    if scripted != nil then
        response, _, decode_err = json.decode(scripted)
        if response == nil then
            return nil, "AGENT_TEST_RESPONSES entry " .. tostring(TEST_RESPONSE_INDEX) .. " is not valid JSON: " .. tostring(decode_err)
        end
    else
        response = {content = {{type = "text", text = "Test response."}}, stopReason = "stop"}
    end

    prompt_text_length = string.len(tostring(system_prompt))
    if messages == nil then
        messages = {}
    end
    for _, m in ipairs(messages) do
        prompt_text_length = prompt_text_length + string.len(tostring(m.content))
    end
    usage = {
        prompt_tokens = math.ceil(prompt_text_length / 4),
        completion_tokens = estimate_tokens_for_test(scripted),
    }
    usage.total_tokens = usage.prompt_tokens + usage.completion_tokens
    return response, nil, usage
end

-- A stable, content-derived pseudo-embedding -- not a real semantic
-- vector, just enough determinism for ranking-formula tests to
-- exercise the cosine-similarity code path reproducibly.
function agent_provider_test.embeddings(model, text)
    seed = 0
    for i = 1, string.len(text) do
        seed = seed + string.byte(text, i)
    end
    vector = {}
    for i = 1, 8 do
        table.insert(vector, math.sin(seed + i))
    end
    return vector
end

return agent_provider_test
