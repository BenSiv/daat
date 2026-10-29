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

function test_approval_ignores_a_write_the_tool_refused()
    print("Testing approval doesn't count a destructive call the tool refused before asking")
    conv = checks.conversation({user("q"), calls("c1", "entity.update", {entity_id = 1}),
        result("c1", "entity.update", "ERROR: nothing to update: pass each field to change", true), said("Couldn't.")}, {})
    check(checks.approval(conv, {}, CTX).pass == true, "a refused call wrote nothing and needs no approval")
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
    recorded = checks.conversation({user("q"), said("The available records do not record a supplier for it.")}, {})
    check(checks.says_unknown(recorded, {}, CTX).pass == true, "'do not record' should pass")
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

function test_no_latex_catches_typeset_formulas_but_not_plain_ones()
    print("Testing no_latex fails on LaTeX and passes plain-text formulas and prices")
    latex = checks.conversation({user("q"), said("Doubling time: $\\frac{\\ln(2)}{0.2511} \\approx 2.76$ hours.")}, {})
    check(checks.no_latex(latex, {}, CTX).pass == false, "\\frac in the answer should fail")
    plain = checks.conversation({user("q"), said("Doubling time: ln(2) / 0.2511 = 2.76 hours; the kit costs $40.")}, {})
    check(checks.no_latex(plain, {}, CTX).pass == true, "a plain formula and a dollar price should pass")
end

function test_labels_not_ids_catches_internal_ids_but_not_lab_numbers_or_link_urls()
    print("Testing labels_not_ids fails on 'sample 41' and listed ids, not on labels or link URLs")
    by_id = checks.conversation({user("q"), said("The fit used all 5 points for sample 41 in EXP-018.")}, {})
    check(checks.labels_not_ids(by_id, {}, CTX).pass == false, "'sample 41' should fail")
    listed = checks.conversation({user("q"), said("The notes (#263) say the lag phase was long.")}, {})
    check(checks.labels_not_ids(listed, {ids = {263}}, CTX).pass == false, "a listed id shown as #263 should fail")
    good = checks.conversation({user("q"), said("Sample EXP-018-A of experiment 018 doubled every 2.76 h " ..
        "([notes](/document?entity_id=263)).")}, {})
    check(checks.labels_not_ids(good, {ids = {263}}, CTX).pass == true,
        "labels, a zero-padded lab number and an id inside a link URL should pass")
end

function test_names_record_needs_the_label_outside_a_link()
    print("Testing names_record fails when the label only appears inside a document link")
    inside = checks.conversation({user("q"), said("The doubling time of [Notes: Growth on Molasses (EXP-018)](/document?entity_id=263) was 2.76 hours.")}, {})
    check(checks.names_record(inside, {label = "EXP-018"}, CTX).pass == false, "a label only in a link should fail")
    named = checks.conversation({user("q"), said("EXP-018 doubled every 2.76 hours ([notes](/document?entity_id=263)).")}, {})
    check(checks.names_record(named, {label = "EXP-018"}, CTX).pass == true, "the label in the text should pass")
end

-- A fake deployment: link rows from document 300, which the write
-- below created under document 263.
function link_ctx(links)
    return {status = "done", is_destructive = only_updates_are_destructive, query = function(sql)
        if string.find(sql, "to_document_id IS NULL", 1, true) != nil then
            rows = {}
            for _, l in ipairs(links) do
                if l.to == nil then
                    table.insert(rows, {link_text = l.text})
                end
            end
            return rows
        end
        if string.find(sql, "FROM document_link", 1, true) != nil then
            rows = {}
            for _, l in ipairs(links) do
                if l.to != nil then
                    table.insert(rows, {id = l.to})
                end
            end
            return rows
        end
        if string.find(sql, "SELECT content", 1, true) != nil then
            return {{content = "# Protocol\n\n## Steps\n\nSee also [[Notes A]]."}}
        end
        return {{id = 300, parent_id = 263}}
    end}
end

WRITE = {user("q"), calls("c1", "document.create", {title = "Summary"}),
    result("c1", "document.create", "Created document #300 (Summary)", false), said("Done.")}

function test_document_link_checks_read_stored_links()
    print("Testing links_documents, no_dangling_links and not_filed_under read what was stored")
    conv = checks.conversation(WRITE, {})
    ctx = link_ctx({{to = 271}, {to = 272}, {to = nil, text = "wiki-style"}})
    check(checks.links_documents(conv, {ids = {271, 272}}, ctx).pass == true, "both targets linked should pass")
    check(checks.links_documents(conv, {ids = {271, 273}}, ctx).pass == false, "a missing target should fail")
    check(checks.no_dangling_links(conv, {}, ctx).pass == false, "a link to nothing should fail")
    check(checks.no_dangling_links(conv, {}, link_ctx({{to = 271}})).pass == true, "resolved links should pass")
    check(checks.not_filed_under(conv, {ids = {263}}, ctx).pass == false, "filed under a forbidden parent should fail")
    check(checks.not_filed_under(conv, {ids = {264}}, ctx).pass == true, "another parent should pass")
    nothing = checks.conversation({user("q"), said("Here is the summary.")}, {})
    check(checks.links_documents(nothing, {ids = {271}}, ctx).pass == false, "no write at all should fail")
end

function test_keeps_content_and_numbers()
    print("Testing keeps_content notices dropped sections, and answer's numbers needs every one")
    ctx = link_ctx({})
    check(checks.keeps_content(nil, {id = 1, texts = {"## Steps"}}, ctx).pass == true, "kept section should pass")
    check(checks.keeps_content(nil, {id = 1, texts = {"## Safety"}}, ctx).pass == false, "dropped section should fail")
    conv = checks.conversation({user("q"), said("YPD 3.1 h, Molasses 2.9 h, Sucrose 3.6 h.")}, {})
    check(checks.answer(conv, {numbers = {3.1, 2.9, 3.6}}, CTX).pass == true, "all three numbers should pass")
    check(checks.answer(conv, {numbers = {3.1, 2.9, 4.2}}, CTX).pass == false, "a missing number should fail")
end

test_final_text_is_the_last_plain_reply_after_the_last_user_message()
test_no_tool_names_catches_plumbing_but_not_links()
test_answer_matches_text_lists_and_numbers()
test_answer_accepts_any_common_spelling_of_a_date()
test_cites_needs_a_link_to_the_right_record()
test_approval_fails_on_a_write_nobody_approved()
test_approval_ignores_a_write_the_tool_refused()
test_no_failed_lookup_counts_guessed_schema_errors()
test_finished_fails_on_a_stall_or_a_turn_limit()
test_says_unknown_and_shows_method()
test_no_latex_catches_typeset_formulas_but_not_plain_ones()
test_labels_not_ids_catches_internal_ids_but_not_lab_numbers_or_link_urls()
test_names_record_needs_the_label_outside_a_link()
test_document_link_checks_read_stored_links()
test_keeps_content_and_numbers()

if FAILURES > 0 then
    print(FAILURES .. " failure(s)")
    os.exit(1)
end
print("All agent eval check tests passed")
