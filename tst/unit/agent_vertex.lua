-- tst/unit/agent_vertex.lua
-- Unit tests for src/provider/agent_vertex.lua's vertex_url: no real
-- API calls -- exercises the pure URL-building logic, matching this
-- repo's existing tst/unit/ style (require the module, check(), run
-- inline, exit 1 on failure).

agent_vertex = require("provider.agent_vertex")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function test_vertex_url_regional_uses_region_subdomain()
    print("Testing vertex_url prefixes the host with region for a regional location")
    url = agent_vertex.vertex_url("celleste-elab", "europe-west1", "gemini-2.5-flash:generateContent")
    expected = "https://europe-west1-aiplatform.googleapis.com/v1/projects/celleste-elab" ..
        "/locations/europe-west1/publishers/google/models/gemini-2.5-flash:generateContent"
    check(url == expected, "expected " .. expected .. ", got " .. tostring(url))
end

function test_vertex_url_global_has_no_subdomain_prefix()
    print("Testing vertex_url uses the bare host for the global location")
    url = agent_vertex.vertex_url("celleste-elab", "global", "gemini-3.5-flash-lite:generateContent")
    expected = "https://aiplatform.googleapis.com/v1/projects/celleste-elab" ..
        "/locations/global/publishers/google/models/gemini-3.5-flash-lite:generateContent"
    check(url == expected, "expected " .. expected .. ", got " .. tostring(url))
end

-- Gemini 3.x: a functionCall part's thoughtSignature is mandatory to
-- echo back on the next request (confirmed live against a real
-- gemini-3.5-flash-lite call while scoping brex 153144598 -- omitting
-- it is a real 400, not just a quality nicety). This locks the
-- capture half of that round-trip in as a real regression test rather
-- than only the live-only bats coverage.
function test_vertex_blocks_captures_thought_signature_on_tool_call()
    print("Testing vertex_blocks_from_parts captures thoughtSignature on a functionCall part")
    parts = {{functionCall = {name = "add", args = {a = 1, b = 2}}, thoughtSignature = "sig-1"}}
    blocks = agent_vertex.vertex_blocks_from_parts(parts)
    check(blocks[1].type == "toolCall", "expected a toolCall block, got " .. tostring(blocks[1].type))
    check(blocks[1].thinking_signature == "sig-1", "expected thinking_signature 'sig-1', got " .. tostring(blocks[1].thinking_signature))
end

-- Confirmed live: on a parallel tool-call turn, only the FIRST
-- functionCall part in the response carries a thoughtSignature -- a
-- later one in the same response has none at all.
function test_vertex_blocks_only_captures_signature_on_first_of_parallel_calls()
    print("Testing vertex_blocks_from_parts leaves a later parallel functionCall's signature unset")
    parts = {
        {functionCall = {name = "add", args = {a = 1, b = 2}}, thoughtSignature = "sig-1"},
        {functionCall = {name = "add", args = {a = 3, b = 4}}},
    }
    blocks = agent_vertex.vertex_blocks_from_parts(parts)
    check(blocks[1].thinking_signature == "sig-1", "first call should carry the signature")
    check(blocks[2].thinking_signature == nil, "second parallel call should carry no signature, got " .. tostring(blocks[2].thinking_signature))
end

-- The gap this session's own live testing found and fixed: a plain
-- final text/thinking part can also carry a thoughtSignature (Gemini 3
-- docs: "recommended," not enforced, but still real data worth
-- preserving) -- confirmed live against gemini-3.5-flash-lite that an
-- ordinary text-only reply comes back with one attached.
function test_vertex_blocks_captures_thought_signature_on_text_and_thinking_parts()
    print("Testing vertex_blocks_from_parts captures thoughtSignature on plain text/thinking parts too")
    parts = {
        {thought = true, text = "reasoning...", thoughtSignature = "sig-thinking"},
        {text = "final answer", thoughtSignature = "sig-text"},
    }
    blocks = agent_vertex.vertex_blocks_from_parts(parts)
    check(blocks[1].type == "thinking" and blocks[1].thinking_signature == "sig-thinking",
        "expected the thinking block to carry sig-thinking, got " .. tostring(blocks[1].thinking_signature))
    check(blocks[2].type == "text" and blocks[2].thinking_signature == "sig-text",
        "expected the text block to carry sig-text, got " .. tostring(blocks[2].thinking_signature))
end

-- The other half of the same round trip: whatever got captured on a
-- block must be sent back on the matching outgoing part, for all three
-- block types, not just toolCall.
function test_vertex_contents_round_trips_thought_signature_for_every_block_type()
    print("Testing vertex_contents_from_messages re-attaches thoughtSignature for text/thinking/toolCall blocks")
    messages = {
        {role = "assistant", content = {
            {type = "thinking", thinking = "reasoning...", thinking_signature = "sig-thinking"},
            {type = "toolCall", id = "call_1", name = "add", arguments = {a = 1, b = 2}, thinking_signature = "sig-tool"},
        }},
    }
    contents = agent_vertex.vertex_contents_from_messages(messages)
    parts = contents[1].parts
    check(parts[1].thoughtSignature == "sig-thinking", "expected the thinking part to carry sig-thinking, got " .. tostring(parts[1].thoughtSignature))
    check(parts[2].thoughtSignature == "sig-tool", "expected the functionCall part to carry sig-tool, got " .. tostring(parts[2].thoughtSignature))

    messages_no_sig = {{role = "assistant", content = {{type = "text", text = "final answer"}}}}
    contents_no_sig = agent_vertex.vertex_contents_from_messages(messages_no_sig)
    check(contents_no_sig[1].parts[1].thoughtSignature == nil,
        "a block with no captured signature should not invent one on the way back out")
end

test_vertex_url_regional_uses_region_subdomain()
test_vertex_url_global_has_no_subdomain_prefix()
test_vertex_blocks_captures_thought_signature_on_tool_call()
test_vertex_blocks_only_captures_signature_on_first_of_parallel_calls()
test_vertex_blocks_captures_thought_signature_on_text_and_thinking_parts()
test_vertex_contents_round_trips_thought_signature_for_every_block_type()

if FAILURES > 0 then
    print(tostring(FAILURES) .. " failure(s)")
    os.exit(1)
end
print("All tests passed")
