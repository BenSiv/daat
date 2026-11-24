-- tst/unit/agent_eval_checks.lua
-- Unit tests for tst/eval/checks.lua (doc/agent-eval.md): every
-- scorecard check must fail on the conversation it exists to catch,
-- not only pass on the scripted good path bld/eval.sh exercises.

json = require("dkjson")
checks = dofile("tst/eval/checks.lua")

unit = require("unit")
check = unit.check
tests = unit.suite()

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

-- The tools each loop is offered, for the validity checks (#41): the chat
-- loop a read, a search and a write; a research sub-agent the read only.
-- Schemas as src/agent_tools.lua declares them.
ENTITY_GET = {parameters = {type = "object", required = {"entity_type", "entity_id"}, properties = {
    entity_type = {type = "string"}, entity_id = {type = "integer"}, field = {type = "string"}}}}
DOCUMENT_SEARCH = {parameters = {type = "object", required = {"query"}, properties = {
    query = {type = "string"}, scope = {type = "string", enum = {"all", "titles"}}}}}
ENTITY_UPDATE = {parameters = {type = "object", required = {"entity_type", "entity_id"}, additionalProperties = true,
    properties = {entity_type = {type = "string"}, entity_id = {type = "integer"}, reason = {type = "string"}}}}
-- No built-in tool declares an array today; an extension's tool can, so
-- this stands in for one.
DOCUMENT_COMPARE = {parameters = {type = "object", required = {"document_ids"}, properties = {
    document_ids = {type = "array", items = {type = "integer"}}}}}
CHAT_TOOLS = {["entity.get"] = ENTITY_GET, ["document.search"] = DOCUMENT_SEARCH, ["entity.update"] = ENTITY_UPDATE,
    ["document.compare"] = DOCUMENT_COMPARE}
RESEARCH_TOOLS = {["entity.get"] = ENTITY_GET, ["document.search"] = DOCUMENT_SEARCH}
VALIDITY_CTX = {declared = function(loop)
    if loop == "research" or loop == "background" then
        return RESEARCH_TOOLS
    end
    return CHAT_TOOLS
end}

-- A step of a sub-agent: stored under its parent with its loop.
function in_loop(row, loop)
    row.parent_message_id = 1
    row.loop_kind = loop
    return row
end

function tests.known_tools_fails_on_a_tool_nobody_declared()
    print("Testing known_tools catches invented tools, as on 20261110-111632-live")
    -- Recorded: per-medium-documents-1 and sample-last-readings-1 of that run.
    conv = checks.conversation({user("Which documents cover the media?"),
        calls("c1", "document.query", {sql = "SELECT d.id, d.title FROM document d WHERE d.title LIKE '%EXP-014%'"}),
        result("c1", "document.query", "ERROR: unknown tool document.query", true),
        calls("c1", "entity.search", {query = "EXP-027"}),
        result("c1", "entity.search", "ERROR: unknown tool entity.search", true),
        calls("c1", "document.search", {query = "EXP-014"}),
        result("c1", "document.search", "hits", false), said("Done.")}, {})
    outcome = checks.known_tools(conv, {}, VALIDITY_CTX)
    check(outcome.pass == false and outcome.count == 2 and outcome.calls == 3,
        "two of three calls invented, got " .. tostring(outcome.count) .. " of " .. tostring(outcome.calls))
    check(string.find(outcome.detail, "document.query", 1, true) != nil and string.find(outcome.detail, "entity.search", 1, true) != nil,
        "names both, got: " .. outcome.detail)
    check(outcome.by_tool["document.query"] == 1 and outcome.by_tool["entity.search"] == 1, "counted by tool")
end

function tests.known_tools_holds_a_sub_agent_to_its_own_tools()
    print("Testing known_tools: a write is unknown to the research loop, known to chat")
    conv = checks.conversation({user("q"),
        in_loop(calls("c1", "entity.update", {}), "research"),
        in_loop(result("c1", "entity.update", "ERROR: research is read-only", true), "research"),
        in_loop(calls("c1", "entity.get", {}), "research"),
        calls("c1", "entity.update", {}), said("ok")}, {})
    outcome = checks.known_tools(conv, {}, VALIDITY_CTX)
    check(outcome.pass == false and outcome.count == 1 and outcome.calls == 3, "only the research write, got " .. tostring(outcome.count))
    check(string.find(outcome.detail, "entity.update (research)", 1, true) != nil, "says which loop, got: " .. outcome.detail)
end

function tests.known_tools_passes_declared_calls_and_no_calls()
    print("Testing known_tools passes a conversation of declared calls, or none")
    conv = checks.conversation({user("q"), calls("c1", "entity.get", {}), result("c1", "entity.get", "row", false), said("ok")}, {})
    outcome = checks.known_tools(conv, {}, VALIDITY_CTX)
    check(outcome.pass == true and outcome.count == 0 and outcome.calls == 1, "a declared call passes")
    outcome = checks.known_tools(checks.conversation({user("q"), said("ok")}, {}), {}, VALIDITY_CTX)
    check(outcome.pass == true and outcome.calls == 0, "no calls passes")
end

function valid_arguments_of(arguments, name)
    conv = checks.conversation({user("q"), calls("c1", name, arguments), result("c1", name, "x", false), said("ok")}, {})
    return checks.valid_arguments(conv, {}, VALIDITY_CTX)
end

function tests.valid_arguments_fails_on_each_kind_of_bad_argument()
    print("Testing valid_arguments catches missing, mistyped, unknown and out-of-list arguments")
    missing = valid_arguments_of({entity_id = 24}, "entity.get")
    check(missing.pass == false and missing.count == 1 and string.find(missing.detail, "missing entity_type", 1, true) != nil,
        "a required field missing, got: " .. missing.detail)
    -- The id as text: what a model copying "experiment 24" from a result writes.
    mistyped = valid_arguments_of({entity_type = "experiment", entity_id = "24"}, "entity.get")
    check(mistyped.pass == false and string.find(mistyped.detail, "entity_id should be integer, got string", 1, true) != nil,
        "a string where an integer belongs, got: " .. mistyped.detail)
    fractional = valid_arguments_of({entity_type = "experiment", entity_id = 24.5}, "entity.get")
    check(fractional.pass == false, "24.5 isn't an integer")
    unknown = valid_arguments_of({entity_type = "experiment", entity_id = 24, lab_number = "EXP-027"}, "entity.get")
    check(unknown.pass == false and string.find(unknown.detail, "unknown lab_number", 1, true) != nil,
        "a key the tool doesn't take, got: " .. unknown.detail)
    off_list = valid_arguments_of({query = "EXP-027", scope = "everything"}, "document.search")
    check(off_list.pass == false and string.find(off_list.detail, "'everything' isn't one of all, titles", 1, true) != nil,
        "a value outside the enum, got: " .. off_list.detail)
end

function tests.valid_arguments_passes_good_calls_and_open_ended_writes()
    print("Testing valid_arguments passes matching calls, and field keys on entity.update")
    check(valid_arguments_of({entity_type = "experiment", entity_id = 24}, "entity.get").pass == true, "required only")
    check(valid_arguments_of({entity_type = "experiment", entity_id = 24, field = "notes"}, "entity.get").pass == true, "with an optional one")
    open = valid_arguments_of({entity_type = "experiment", entity_id = 24, status = "finished"}, "entity.update")
    check(open.pass == true, "additionalProperties = true takes one key per field, got: " .. open.detail)
    still_typed = valid_arguments_of({entity_type = "experiment", entity_id = "24", status = "finished"}, "entity.update")
    check(still_typed.pass == false, "a declared key is still typed on an open-ended write")
    undeclared = valid_arguments_of({sql = "SELECT 1"}, "document.query")
    check(undeclared.pass == true and undeclared.calls == 0, "an undeclared tool is known_tools' to count, not this one")
end

function tests.valid_arguments_tells_an_array_from_an_object()
    print("Testing valid_arguments: a JSON object where an array is declared is a wrong type (Ben, #60)")
    -- Arguments go through json.encode and decode, as stored ones do, so
    -- these carry dkjson's __jsontype.
    object = valid_arguments_of({document_ids = {first = 291}}, "document.compare")
    check(object.pass == false and string.find(object.detail, "document_ids should be array", 1, true) != nil,
        "an object for an array, got: " .. object.detail)
    check(valid_arguments_of({document_ids = {291, 292}}, "document.compare").pass == true, "a real array passes")
    items = valid_arguments_of({document_ids = {291, "292"}}, "document.compare")
    check(items.pass == false and string.find(items.detail, "should be integer", 1, true) != nil,
        "an array's items are still typed, got: " .. items.detail)
    -- dkjson writes an empty Lua table as [], as a test-mode script's
    -- document.children {} is stored; empty is empty either way.
    check(valid_arguments_of({}, "document.search").count == 1, "an empty object still misses its required query")
    empty = valid_arguments_of({document_ids = {}}, "document.compare")
    check(empty.pass == true, "an empty list is an array, got: " .. empty.detail)
    check(checks.json_kind == nil, "helpers stay out of the check list")
end

function tests.grounded_ids_fails_on_an_id_nothing_showed()
    print("Testing grounded_ids catches a lab number read as a row id (#38's failure)")
    -- EXP-017 is row 24; the 17 in the lab number isn't a row id anywhere.
    conv = checks.conversation({user("When did EXP-017 start?"),
        calls("c1", "entity.get", {entity_type = "experiment", entity_id = 17}),
        result("c1", "entity.get", "id=17; lab_number=EXP-009", false), said("It started on 2026-01-02.")}, {})
    outcome = checks.grounded_ids(conv, {}, VALIDITY_CTX)
    check(outcome.pass == false and outcome.count == 1 and string.find(outcome.detail, "entity.get (entity_id 17)", 1, true) != nil,
        "17 came from EXP-017, got: " .. outcome.detail)
    check(outcome.by_tool["entity.get"] == 1, "counted by tool")
end

function tests.grounded_ids_passes_an_id_a_result_or_the_user_gave()
    print("Testing grounded_ids passes ids from an earlier result or the user's message")
    from_result = checks.conversation({user("When did EXP-017 start?"),
        calls("c1", "entity.find", {text = "EXP-017"}),
        result("c1", "entity.find", "experiment 24 \"Growth trial\" (lab_number EXP-017)", false),
        calls("c2", "entity.get", {entity_type = "experiment", entity_id = 24}),
        result("c2", "entity.get", "started_on=2026-01-07", false), said("2026-01-07.")}, {})
    outcome = checks.grounded_ids(from_result, {}, VALIDITY_CTX)
    check(outcome.pass == true and outcome.calls == 2, "24 came from entity.find, got: " .. outcome.detail)
    from_user = checks.conversation({user("Show me document 261"),
        calls("c1", "document.read", {document_id = 261}), result("c1", "document.read", "text", false), said("ok")}, {})
    check(checks.grounded_ids(from_user, {}, VALIDITY_CTX).pass == true, "the user named 261")
end

function tests.grounded_ids_never_lets_the_model_ground_itself()
    print("Testing grounded_ids: the model's own text and arguments don't ground an id")
    conv = checks.conversation({user("q"), said("I'll look at experiment 17."),
        calls("c1", "entity.get", {entity_type = "experiment", entity_id = 17}),
        result("c1", "entity.get", "ERROR: no such row", true),
        calls("c2", "entity.get", {entity_type = "experiment", entity_id = 17}),
        result("c2", "entity.get", "ERROR: no such row", true), said("Not found.")}, {})
    outcome = checks.grounded_ids(conv, {}, VALIDITY_CTX)
    check(outcome.pass == false and outcome.count == 2, "both uses of the invented 17, got " .. tostring(outcome.count))
    check(checks.has_number == nil, "helpers stay out of the check list")
end

function tests.grounded_ids_takes_only_what_came_from_outside_the_model()
    print("Testing grounded_ids: a progress note or an error echoing the id doesn't ground it (Ben, #60)")
    -- An error result names the id it was given, as entity.get's does.
    echoed = checks.conversation({user("q"),
        calls("c1", "entity.get", {entity_type = "experiment", entity_id = 17}),
        result("c1", "entity.get", "ERROR: no such experiment #17", true),
        calls("c2", "entity.get", {entity_type = "experiment", entity_id = 17}),
        result("c2", "entity.get", "ERROR: no such experiment #17", true), said("Not found.")}, {})
    outcome = checks.grounded_ids(echoed, {}, VALIDITY_CTX)
    check(outcome.count == 2, "an error's echo of 17 grounds neither call, got " .. tostring(outcome.count))
    -- The note between two step budgets of an auto-continued turn.
    noted = checks.conversation({user("q"), {role = "progress", content = "Next I'll read experiment 17."},
        calls("c1", "entity.get", {entity_type = "experiment", entity_id = 17}),
        result("c1", "entity.get", "r", false), said("ok")}, {})
    check(checks.grounded_ids(noted, {}, VALIDITY_CTX).pass == false, "the model's progress note doesn't ground 17")
    -- What did come from outside still does: a decision, a summary, a result.
    for _, role in ipairs({"decision", "compaction_summary", "tool_result"}) do
        row = {role = role, content = "experiment 17"}
        if role == "tool_result" then
            row = result("c0", "entity.find", "experiment 17", false)
        end
        conv = checks.conversation({user("q"), row, calls("c1", "entity.get", {entity_type = "experiment", entity_id = 17}),
            result("c1", "entity.get", "r", false), said("ok")}, {})
        check(checks.grounded_ids(conv, {}, VALIDITY_CTX).pass == true, "a " .. role .. " row grounds 17")
    end
end

function tests.grounded_ids_reads_whole_numbers_only()
    print("Testing grounded_ids: 24 isn't in 124, 240 or EXP-0245")
    texts = {"row 124", "EXP-0245", "id 240"}
    for _, text in ipairs(texts) do
        conv = checks.conversation({user(text), calls("c1", "entity.get", {entity_type = "x", entity_id = 24}),
            result("c1", "entity.get", "r", false), said("ok")}, {})
        check(checks.grounded_ids(conv, {}, VALIDITY_CTX).pass == false, "24 isn't in '" .. text .. "'")
    end
    conv = checks.conversation({user("entity_id=24,"), calls("c1", "entity.get", {entity_type = "x", entity_id = 24}),
        result("c1", "entity.get", "r", false), said("ok")}, {})
    check(checks.grounded_ids(conv, {}, VALIDITY_CTX).pass == true, "24 stands alone in 'entity_id=24,'")
    ids = checks.conversation({user("rows 5 and 6"), calls("c1", "plot.points", {row_ids = {5, 6, 7}}),
        result("c1", "plot.points", "r", false), said("ok")}, {})
    outcome = checks.grounded_ids(ids, {}, VALIDITY_CTX)
    check(outcome.pass == false and string.find(outcome.detail, "row_ids 7", 1, true) != nil, "a list's ids each, got: " .. outcome.detail)
end

function tests.final_text_is_the_last_plain_reply_after_the_last_user_message()
    print("Testing the final answer is the last plain reply of the latest exchange")
    conv = checks.conversation({user("q1"), said("old answer"), user("q2"), calls("c1", "document.search", {}),
        result("c1", "document.search", "hits", false), said("new answer")}, {})
    check(conv.final_text == "new answer", "expected 'new answer', got " .. tostring(conv.final_text))
    conv = checks.conversation({user("q1"), said("old answer"), user("q2")}, {})
    check(conv.final_text == nil, "a question with no reply yet has no final answer")
end

function tests.answer_matches_text_lists_and_numbers()
    print("Testing answer finds text, every item of a list, and a number within tolerance")
    conv = checks.conversation({user("q"), said("It contains Glucose, Peptone and Yeast extract; Td = 3.91 h.")}, {})
    check(checks.answer(conv, {expected = "glucose"}, CTX).pass == true, "case-insensitive text should match")
    check(checks.answer(conv, {all = {"Glucose", "Agar"}}, CTX).pass == false, "a missing list item should fail")
    check(checks.answer(conv, {number = 3.85, tolerance = 0.05}, CTX).pass == true, "3.91 is within 5% of 3.85")
    check(checks.answer(conv, {number = 3.5, tolerance = 0.05}, CTX).pass == false, "3.91 is not within 5% of 3.5")
end

function tests.answer_accepts_any_common_spelling_of_a_date()
    print("Testing a date answer matches ISO and written-out spellings, and only the right date")
    for _, reply in ipairs({"It started on 2026-04-25.", "It started on **April 25, 2026**.",
            "Started 25 April 2026.", "Started Apr 25, 2026."}) do
        conv = checks.conversation({user("q"), said(reply)}, {})
        check(checks.answer(conv, {date = "2026-04-25"}, CTX).pass == true, "should accept: " .. reply)
    end
    wrong = checks.conversation({user("q"), said("It started on April 24, 2026.")}, {})
    check(checks.answer(wrong, {date = "2026-04-25"}, CTX).pass == false, "the day before must not match")
end

function tests.cites_needs_a_link_to_the_right_record()
    print("Testing cites wants a link to the record, not just its number")
    linked = checks.conversation({user("q"), said("See [notes](/document?entity_id=212).")}, {})
    check(checks.cites(linked, {ids = {212}}, CTX).pass == true, "a link to 212 should pass")
    check(checks.cites(linked, {ids = {21}}, CTX).pass == false, "entity_id=212 must not count as 21")
    bare = checks.conversation({user("q"), said("See document #212.")}, {})
    check(checks.cites(bare, {ids = {212}}, CTX).pass == false, "mentioning #212 without a link should fail")
end

function tests.approval_fails_on_a_write_nobody_approved()
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
end

function tests.approval_passes_a_turn_that_never_reached_its_write()
    print("Testing approval doesn't fail a turn that ran out of steps before proposing its write")
    -- 20261117-102156-live, approval-mark-finished #1: turn_limit while
    -- still reading, no write proposed. Nothing ran unapproved; finished
    -- and state are what fail.
    rows = {user("mark EXP-049 finished"), calls("c1", "entity.find", {text = "EXP-049"}),
        result("c1", "entity.find", "experiment 178", false)}
    conv = checks.conversation(rows, {})
    check(checks.approval(conv, {}, CTX).pass == true, "no write ran, so nothing ran without approval")
    check(checks.finished(conv, {}, {status = "turn_limit"}).pass == false, "the unfinished turn fails finished instead")
end

function tests.approval_ignores_a_write_the_tool_refused()
    print("Testing approval doesn't count a destructive call the tool refused before asking")
    conv = checks.conversation({user("q"), calls("c1", "entity.update", {entity_id = 1}),
        result("c1", "entity.update", "ERROR: nothing to update: pass each field to change", true), said("Couldn't.")}, {})
    check(checks.approval(conv, {}, CTX).pass == true, "a refused call wrote nothing and needs no approval")
end

function tests.no_failed_lookup_counts_guessed_schema_errors()
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

function tests.finished_fails_on_a_stall_or_a_turn_limit()
    print("Testing finished fails on 'should I continue?' and on a non-done status")
    stalled = checks.conversation({user("q"), said("I found 3 of 5 runs. Should I continue?")}, {})
    check(checks.finished(stalled, {}, CTX).pass == false, "a stall should fail")
    answered = checks.conversation({user("q"), said("All 5 runs finished.")}, {})
    check(checks.finished(answered, {}, CTX).pass == true, "a plain answer should pass")
    check(checks.finished(answered, {}, {status = "turn_limit"}).pass == false, "a turn limit should fail")
    check(checks.finished(answered, {}, {}).pass == true, "a stored chat has no status and is judged by its text")
end

function tests.says_unknown_and_shows_method()
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

function tests.no_tool_names_catches_plumbing_but_not_links()
    print("Testing no_tool_names catches tool names but not record links or sentence ends")
    leaky = checks.conversation({user("q"), said("| S1 | calc.evaluate -> 4.31 days |")}, {})
    check(checks.no_tool_names(leaky, {}, CTX).pass == false, "calc.evaluate in the answer should fail")
    clean = checks.conversation({user("q"), said("See the [notes](/document?entity_id=4) and the entity. Done.")}, {})
    check(checks.no_tool_names(clean, {}, CTX).pass == true, "links and ordinary words should pass")
end

function tests.no_latex_catches_typeset_formulas_but_not_plain_ones()
    print("Testing no_latex fails on LaTeX and passes plain-text formulas and prices")
    latex = checks.conversation({user("q"), said("Doubling time: $\\frac{\\ln(2)}{0.2511} \\approx 2.76$ hours.")}, {})
    check(checks.no_latex(latex, {}, CTX).pass == false, "\\frac in the answer should fail")
    plain = checks.conversation({user("q"), said("Doubling time: ln(2) / 0.2511 = 2.76 hours; the kit costs $40.")}, {})
    check(checks.no_latex(plain, {}, CTX).pass == true, "a plain formula and a dollar price should pass")
end

function tests.labels_not_ids_catches_internal_ids_but_not_lab_numbers_or_link_urls()
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

function tests.names_record_needs_the_label_outside_a_link()
    print("Testing names_record fails when the label only appears inside a document link, and passes on a record link")
    inside_doc = checks.conversation({user("q"), said("The doubling time of [Notes: Growth on Molasses (EXP-018)](/document?entity_id=263) was 2.76 hours.")}, {})
    check(checks.names_record(inside_doc, {label = "EXP-018"}, CTX).pass == false, "a label only in a /document link should fail")
    detail_doc = checks.conversation({user("q"), said("See [Notes (EXP-018)](/detail?type=document&entity_id=263).")}, {})
    check(checks.names_record(detail_doc, {label = "EXP-018"}, CTX).pass == false, "a label only in a type=document link should fail")
    titled_only = checks.conversation({user("q"), said("[Growth on Molasses](/detail?type=experiment&entity_id=24) doubled every 2.76 hours.")}, {})
    check(checks.names_record(titled_only, {label = "EXP-018"}, CTX).pass == false, "a record link whose label omits EXP-018 should fail")
    linked_record = checks.conversation({user("q"), said("[EXP-018](/detail?type=experiment&entity_id=24) doubled every 2.76 hours.")}, {})
    check(checks.names_record(linked_record, {label = "EXP-018"}, CTX).pass == true, "linking the record itself by its label should pass")
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

function tests.document_link_checks_read_stored_links()
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

function tests.keeps_content_and_numbers()
    print("Testing keeps_content notices dropped sections, and answer's numbers needs every one")
    ctx = link_ctx({})
    check(checks.keeps_content(nil, {id = 1, texts = {"## Steps"}}, ctx).pass == true, "kept section should pass")
    check(checks.keeps_content(nil, {id = 1, texts = {"## Safety"}}, ctx).pass == false, "dropped section should fail")
    conv = checks.conversation({user("q"), said("YPD 3.1 h, Molasses 2.9 h, Sucrose 3.6 h.")}, {})
    check(checks.answer(conv, {numbers = {3.1, 2.9, 3.6}}, CTX).pass == true, "all three numbers should pass")
    check(checks.answer(conv, {numbers = {3.1, 2.9, 4.2}}, CTX).pass == false, "a missing number should fail")
end

function tests.final_text_ignores_child_rows_and_thinking_blocks()
    print("Testing final_text ignores child rows (research, self_check) and thinking blocks")
    reply_with_thinking = {
        role = "assistant",
        content = json.encode({blocks = {
            {type = "thinking", thinking = "maybe 999 is wrong"},
            {type = "text", text = "The count is 42."},
        }}),
    }
    child_self_check = {
        role = "assistant",
        parent_message_id = 2,
        loop_kind = "self_check",
        content = json.encode({blocks = {{type = "thinking", thinking = "verified 42"}}}),
    }
    child_research = {
        role = "assistant",
        parent_message_id = 2,
        loop_kind = "research",
        content = json.encode({blocks = {{type = "text", text = "sub-agent finding that came later"}}}),
    }
    conv = checks.conversation({user("q"), reply_with_thinking, child_self_check, child_research}, {})
    check(conv.final_text == "The count is 42.", "expected main reply text only, got " .. tostring(conv.final_text))
    check(checks.answer(conv, {number = 999, tolerance = 0.01}, CTX).pass == false, "numbers inside thinking blocks must not satisfy answer check")
end

unit.run(tests)
