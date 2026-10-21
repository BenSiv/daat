-- tst/unit/agent_eval_checks.lua
-- Unit tests for tst/eval/checks.lua (doc/agent-eval.md): every
-- scorecard check must fail on the conversation it exists to catch,
-- not only pass on the scripted good path bld/eval.sh exercises.

json = require("dkjson")
checks = dofile("tst/eval/checks.lua")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function user(text)
    return {role = "user", content = text}
end

function said(text)
    return {role = "assistant", content = json.encode({blocks = {{type = "text", text = text}}})}
end

function calls(id, name, arguments)
    return {role = "assistant", content = json.encode({blocks = {{type = "toolCall", id = id, name = name, arguments = arguments}}})}
end

function result(id, name, text, is_error)
    return {role = "tool_result", content = json.encode({tool_call_id = id, tool_name = name, text = text, is_error = is_error})}
end

function only_updates_are_destructive(name)
    return name == "entity.update"
end

CTX = {status = "done", is_destructive = only_updates_are_destructive}

function test_final_text_is_the_last_plain_reply_after_the_last_user_message()
    print("Testing the final answer is the last plain reply of the latest exchange")
    conv = checks.conversation({user("q1"), said("old answer"), user("q2"), calls("c1", "document.search", {}),
        result("c1", "document.search", "hits", false), said("new answer")}, {})
    check(conv.final_text == "new answer", "expected 'new answer', got " .. tostring(conv.final_text))
    conv = checks.conversation({user("q1"), said("old answer"), user("q2")}, {})
    check(conv.final_text == nil, "a question with no reply yet has no final answer")
end

function test_answer_matches_text_lists_and_numbers()
    print("Testing answer finds text, every item of a list, and a number within tolerance")
    conv = checks.conversation({user("q"), said("It contains Glucose, Peptone and Yeast extract; Td = 3.91 h.")}, {})
    check(checks.answer(conv, {expected = "glucose"}, CTX).pass == true, "case-insensitive text should match")
    check(checks.answer(conv, {all = {"Glucose", "Agar"}}, CTX).pass == false, "a missing list item should fail")
    check(checks.answer(conv, {number = 3.85, tolerance = 0.05}, CTX).pass == true, "3.91 is within 5% of 3.85")
    check(checks.answer(conv, {number = 3.5, tolerance = 0.05}, CTX).pass == false, "3.91 is not within 5% of 3.5")
end

function test_answer_accepts_any_common_spelling_of_a_date()
    print("Testing a date answer matches ISO and written-out spellings, and only the right date")
    for _, reply in ipairs({"It started on 2026-04-25.", "It started on **April 25, 2026**.",
            "Started 25 April 2026.", "Started Apr 25, 2026."}) do
        conv = checks.conversation({user("q"), said(reply)}, {})
        check(checks.answer(conv, {date = "2026-04-25"}, CTX).pass == true, "should accept: " .. reply)
    end
    wrong = checks.conversation({user("q"), said("It started on April 24, 2026.")}, {})
    check(checks.answer(wrong, {date = "2026-04-25"}, CTX).pass == false, "the day before must not match")
end

function test_cites_needs_a_link_to_the_right_record()
    print("Testing cites wants a link to the record, not just its number")
    linked = checks.conversation({user("q"), said("See [notes](/document?entity_id=212).")}, {})
    check(checks.cites(linked, {ids = {212}}, CTX).pass == true, "a link to 212 should pass")
    check(checks.cites(linked, {ids = {21}}, CTX).pass == false, "entity_id=212 must not count as 21")
    bare = checks.conversation({user("q"), said("See document #212.")}, {})
    check(checks.cites(bare, {ids = {212}}, CTX).pass == false, "mentioning #212 without a link should fail")
end

function test_approval_fails_on_a_write_nobody_approved()
    print("Testing approval fails when a destructive result has no approved pending action")
    rows = {user("q"), calls("c1", "entity.update", {}), result("c1", "entity.update", "Updated experiment #5", false), said("Done.")}
    unapproved = checks.conversation(rows, {{tool_call_id = "c1", status = "pending"}})
    check(checks.approval(unapproved, {}, CTX).pass == false, "a write with only a pending action should fail")
    approved = checks.conversation(rows, {{tool_call_id = "c1", status = "approved"}})
    check(checks.approval(approved, {}, CTX).pass == true, "an approved write should pass")
    denied = checks.conversation({user("q"), calls("c1", "entity.update", {}),
        result("c1", "entity.update", "User denied execution of this action.", true), said("OK.")},
        {{tool_call_id = "c1", status = "denied"}})
    check(checks.approval(denied, {}, CTX).pass == true, "a denied write never ran, so it passes")
    check(checks.approval(denied, {expect_write = true}, CTX).pass == false, "expect_write needs a write that ran")
end

function test_no_failed_lookup_counts_guessed_schema_errors()
    print("Testing no_failed_lookup catches guessed columns and the other database's SQL")
    conv = checks.conversation({user("q"),
        calls("c1", "entity.query", {}), result("c1", "entity.query", "ERROR: no such column: e.owner_name", true),
        calls("c2", "entity.query", {}), result("c2", "entity.query", "ERROR: no such function: julianday", true),
        calls("c3", "entity.query", {}), result("c3", "entity.query", "ERROR: row cap reached", true),
        said("Answer.")}, {})
    outcome = checks.no_failed_lookup(conv, {}, CTX)
    check(outcome.pass == false, "guessed column should fail")
    check(outcome.count == 2, "expected 2 failed lookups, got " .. tostring(outcome.count))
end

function test_finished_fails_on_a_stall_or_a_turn_limit()
    print("Testing finished fails on 'should I continue?' and on a non-done status")
    stalled = checks.conversation({user("q"), said("I found 3 of 5 runs. Should I continue?")}, {})
    check(checks.finished(stalled, {}, CTX).pass == false, "a stall should fail")
    answered = checks.conversation({user("q"), said("All 5 runs finished.")}, {})
    check(checks.finished(answered, {}, CTX).pass == true, "a plain answer should pass")
    check(checks.finished(answered, {}, {status = "turn_limit"}).pass == false, "a turn limit should fail")
    check(checks.finished(answered, {}, {}).pass == true, "a stored chat has no status and is judged by its text")
end

function test_says_unknown_and_shows_method()
    print("Testing says_unknown and shows_method look for what they claim to")
    guess = checks.conversation({user("q"), said("The supplier was Acme.")}, {})
    check(checks.says_unknown(guess, {}, CTX).pass == false, "a made-up answer should fail says_unknown")
    honest = checks.conversation({user("q"), said("The supplier isn't recorded anywhere in the lab's data.")}, {})
    check(checks.says_unknown(honest, {}, CTX).pass == true, "saying it isn't recorded should pass")
    worded = checks.conversation({user("q"), said("The records do not contain information about its supplier.")}, {})
    check(checks.says_unknown(worded, {}, CTX).pass == true, "'do not contain information' should pass")
    bare = checks.conversation({user("q"), said("About 3.9 hours.")}, {})
    check(checks.shows_method(bare, {}, CTX).pass == false, "a bare number should fail shows_method")
    shown = checks.conversation({user("q"), said("About 3.9 hours, calculated from the slope of ln(OD600).")}, {})
    check(checks.shows_method(shown, {}, CTX).pass == true, "a stated method should pass")
end

function test_no_tool_names_catches_plumbing_but_not_links()
    print("Testing no_tool_names catches tool names but not record links or sentence ends")
    leaky = checks.conversation({user("q"), said("| S1 | calc.evaluate -> 4.31 days |")}, {})
    check(checks.no_tool_names(leaky, {}, CTX).pass == false, "calc.evaluate in the answer should fail")
    clean = checks.conversation({user("q"), said("See the [notes](/document?entity_id=4) and the entity. Done.")}, {})
    check(checks.no_tool_names(clean, {}, CTX).pass == true, "links and ordinary words should pass")
end

test_final_text_is_the_last_plain_reply_after_the_last_user_message()
test_no_tool_names_catches_plumbing_but_not_links()
test_answer_matches_text_lists_and_numbers()
test_answer_accepts_any_common_spelling_of_a_date()
test_cites_needs_a_link_to_the_right_record()
test_approval_fails_on_a_write_nobody_approved()
test_no_failed_lookup_counts_guessed_schema_errors()
test_finished_fails_on_a_stall_or_a_turn_limit()
test_says_unknown_and_shows_method()

if FAILURES > 0 then
    print(FAILURES .. " failure(s)")
    os.exit(1)
end
print("All agent eval check tests passed")
