-- Context by type: observation masking (agent.shape_context), per-loop
-- masking config, masked-stub repeat handling, and verbatim answer
-- round-trip through compaction (#36, #12, #19, #11).

config = require("config")
agent = require("agent")

unit = require("unit")
check = unit.check
tests = unit.suite()

function call_and_result(id, name, args, text, is_err, rid)
    return {
        {role = "assistant", content = {{type = "toolCall", id = id, name = name, arguments = args}}},
        {
            role = "toolResult",
            toolCallId = id,
            toolName = name,
            content = {{type = "text", text = text}},
            isError = is_err == true,
            resultId = rid,
            origChars = string.len(text),
        },
    }
end

function append_pair(messages, pair)
    table.insert(messages, pair[1])
    table.insert(messages, pair[2])
end

function tests.resolve_masking_defaults_and_overrides()
    print("Testing config.resolve_masking defaults and boolean/table overrides")
    def = config.resolve_masking(nil)
    check(def.research == true and def.background == true and def.chat == false,
        "default masking: research/background on, chat off")

    all_on = config.resolve_masking(true)
    check(all_on.research == true and all_on.background == true and all_on.chat == true,
        "boolean true turns all three on")

    all_off = config.resolve_masking(false)
    check(all_off.research == false and all_off.background == false and all_off.chat == false,
        "boolean false turns all three off")

    partial = config.resolve_masking({chat = true, research = false})
    check(partial.chat == true and partial.research == false and partial.background == true,
        "table overrides named loops and leaves unmentioned ones at defaults")
end

function tests.shape_context_masks_older_keeps_tail_errors_schema_and_short()
    print("Testing agent.shape_context masks older large results while keeping errors, pinned schema, short results, and the last K")
    big_a = string.rep("A", 500)
    big_b = string.rep("B", 600)
    short_c = "only 25 chars of output!!"
    err_d = "ERROR: " .. string.rep("E", 450)
    schema_f = string.rep("S", 550)
    tail_1 = string.rep("T", 500)
    tail_2 = string.rep("U", 500)

    messages = {{role = "user", content = "investigate samples"}}
    append_pair(messages, call_and_result("c1", "entity.query", {sql = "SELECT * FROM sample"}, big_a, false, 41))
    append_pair(messages, call_and_result("c2", "document.search", {query = "molasses"}, big_b, false, nil))
    append_pair(messages, call_and_result("c3", "entity.get", {entity_type = "sample", entity_id = 1}, short_c, false, 43))
    append_pair(messages, call_and_result("c4", "entity.query", {sql = "SELECT bad"}, err_d, true, 44))
    append_pair(messages, call_and_result("c5", "entity.fields", {entity_type = "sample"}, schema_f, false, 45))
    append_pair(messages, call_and_result("c6", "entity.query", {sql = "SELECT 1"}, tail_1, false, 46))
    append_pair(messages, call_and_result("c7", "entity.query", {sql = "SELECT 2"}, tail_2, false, 47))

    shaped = agent.shape_context(messages, {
        enabled = true,
        keep_last = 2,
        min_chars = 300,
        batch_tokens = 0,
        chars_per_token = 2.8,
    })

    -- Input messages are untouched (render-time only).
    check(messages[3].content[1].text == big_a, "original messages table is never mutated")

    -- c1 masked with result_id and result.read guidance.
    c1_text = shaped[3].content[1].text
    check(shaped[3].masked == true, "c1 marked masked")
    check(string.find(c1_text, "entity.query({\"sql\":\"SELECT * FROM sample\"})", 1, true) != nil,
        "c1 stub names tool and canonical args: " .. c1_text)
    check(string.find(c1_text, "500 characters", 1, true) != nil, "c1 stub includes original size")
    check(string.find(c1_text, "result.read(result_id=41, offset=0)", 1, true) != nil,
        "c1 stub tells how to re-read via result.read: " .. c1_text)

    -- c2 masked without result_id -> re-run note.
    c2_text = shaped[5].content[1].text
    check(shaped[5].masked == true, "c2 marked masked")
    check(string.find(c2_text, "re-run the tool if needed again", 1, true) != nil,
        "c2 without result_id says to re-run: " .. c2_text)

    -- c3 (< 300 chars), c4 (error), c5 (pinned schema), c6 & c7 (last 2) all stay verbatim!
    check(shaped[7].content[1].text == short_c and shaped[7].masked != true, "short result (<300) kept verbatim")
    check(shaped[9].content[1].text == err_d and shaped[9].masked != true, "error result kept verbatim")
    check(shaped[11].content[1].text == schema_f and shaped[11].masked != true, "pin_on_compaction schema result kept verbatim")
    check(shaped[13].content[1].text == tail_1 and shaped[13].masked != true, "tail K-1 kept verbatim")
    check(shaped[15].content[1].text == tail_2 and shaped[15].masked != true, "tail K kept verbatim")

    -- find_repeat treats masked results as no longer in context, while unmasked ones still dedupe.
    check(agent.find_repeat(shaped, "document.search", {query = "molasses"}, function(_) return false end) == nil,
        "masked document.search is not answered with REPEAT_CALL_NOTE")
    check(agent.find_repeat(shaped, "entity.fields", {entity_type = "sample"}, function(_) return false end) == "c5",
        "unmasked pinned entity.fields still dedupes")
end

function tests.shape_context_moves_boundary_in_token_batches()
    print("Testing agent.shape_context advances its masking boundary only in >= batch_tokens jumps")
    -- batch_tokens = 1000 at 3.0 chars/token => batch_chars = 3000.
    -- Each result is 1600 chars: 1 older result = 1600 (<3000, 0 masked);
    -- 2 older results = 3200 (>=3000, 2 masked);
    -- 3 older results = 3200 + 1600 (still only first 2 masked: prefix stable!).
    chunk = string.rep("X", 1600)
    policy = {enabled = true, keep_last = 1, min_chars = 300, batch_tokens = 1000, chars_per_token = 3.0}

    msgs = {{role = "user", content = "go"}}
    append_pair(msgs, call_and_result("b1", "entity.query", {sql = "SELECT 1"}, chunk, false, 1))
    append_pair(msgs, call_and_result("b2", "entity.query", {sql = "SELECT 2"}, chunk, false, 2))
    s1 = agent.shape_context(msgs, policy)
    check(s1[3].masked != true and s1[5].masked != true, "1600 older chars < 3000 batch: nothing masked yet")

    append_pair(msgs, call_and_result("b3", "entity.query", {sql = "SELECT 3"}, chunk, false, 3))
    s2 = agent.shape_context(msgs, policy)
    check(s2[3].masked == true and s2[5].masked == true and s2[7].masked != true,
        "3200 older chars >= 3000 batch: b1 and b2 masked together, tail b3 verbatim")

    append_pair(msgs, call_and_result("b4", "entity.query", {sql = "SELECT 4"}, chunk, false, 4))
    s3 = agent.shape_context(msgs, policy)
    check(s3[3].masked == true and s3[5].masked == true and s3[7].masked != true and s3[9].masked != true,
        "adding b4 leaves b3 unmasked (1600 < 3000 since last boundary) so prefix 1..7 is byte-identical!")
    check(s2[3].content[1].text == s3[3].content[1].text and s2[7].content[1].text == s3[7].content[1].text,
        "prefix messages 1..7 are identical across consecutive turns between batch jumps")
end

function tests.compacted_answers_round_trip()
    print("Testing verbatim compacted answers parse back without leaking into prose or requests")
    raw = "## Established facts\nok\n\n" ..
        agent.COMPACTION_USER_REQUESTS_HEADER .. "\n" ..
        agent.format_user_request("first question") .. "\n\n" ..
        agent.COMPACTION_ANSWERS_HEADER .. "\n" ..
        agent.format_user_request("conclusion line 1\n- detail A") .. "\n" ..
        agent.format_user_request("second conclusion")
    without_answers, answers = agent.parse_compacted_answers(raw)
    body, requests = agent.parse_user_requests(without_answers)
    check(body == "## Established facts\nok", "prose cleanly separated: " .. tostring(body))
    check(#requests == 1 and requests[1] == "first question", "request preserved")
    check(#answers == 2, "two answers parsed")
    check(answers[1] == "conclusion line 1\n- detail A", "multi-line answer preserved verbatim")
    check(answers[2] == "second conclusion", "second answer preserved verbatim")
end

function tests.reused_call_ids_across_steps_do_not_collide()
    print("Testing reused per-step call_1 ids (Vertex) keep each step's own masking and repeat state")
    msgs = {{role = "user", content = "check"}}
    -- Step 1: call_1 is document.search("alpha"), masked later
    append_pair(msgs, call_and_result("call_1", "document.search", {query = "alpha"}, string.rep("M", 500), false, 10))
    -- Step 2: call_1 is entity.fields("sample"), unmasked in tail
    append_pair(msgs, call_and_result("call_1", "entity.fields", {entity_type = "sample"}, string.rep("S", 500), false, 11))

    shaped = agent.shape_context(msgs, {enabled = true, keep_last = 1, min_chars = 300, batch_tokens = 0, chars_per_token = 2.8})
    check(shaped[3].masked == true, "step 1 call_1 masked")
    check(string.find(shaped[3].content[1].text, "document.search({\"query\":\"alpha\"})", 1, true) != nil,
        "step 1 stub keeps step 1's own args, not step 2's reused call_1 args: " .. shaped[3].content[1].text)
    check(agent.find_repeat(shaped, "document.search", {query = "alpha"}, function(_) return false end) == nil,
        "step 2's unmasked call_1 must NOT make step 1's masked call_1 look answered!")
    check(agent.find_repeat(shaped, "entity.fields", {entity_type = "sample"}, function(_) return false end) == "call_1",
        "step 2's own unmasked call_1 still dedupes")
end

unit.run(tests)
