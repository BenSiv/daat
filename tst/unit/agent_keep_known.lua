-- Phase 1 of doc/context-management-plan.md: answering exact repeat calls
-- from what's in context, and carrying schema lookups through compaction.
-- Pure functions only; tst/integration/agent_keep_known.bats covers the
-- turn loop.

agent = require("agent")
json = require("dkjson")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function call(id, name, args)
    return {role = "assistant", content = {{type = "toolCall", id = id, name = name, arguments = args}}}
end

function result(id, name, text, is_error)
    return {role = "toolResult", toolCallId = id, toolName = name, content = {{type = "text", text = text}}, isError = is_error == true}
end

function never_write(name)
    return false
end

function writes_documents(name)
    return name == "document.create"
end

function test_canonical_json_ignores_key_order()
    print("Testing canonical_json sorts keys at every level")
    check(agent.canonical_json({b = 1, a = {d = 2, c = 3}}) == agent.canonical_json({a = {c = 3, d = 2}, b = 1}), "same arguments in another key order should compare equal")
    check(agent.canonical_json({a = 1}) != agent.canonical_json({a = 2}), "different values should differ")
end

function test_find_repeat()
    print("Testing find_repeat: exact repeat of an answered read-only call")
    history = {
        {role = "user", content = "fields of sample?"},
        call("c1", "entity.fields", {entity_type = "sample"}),
        result("c1", "entity.fields", "id, name, ..."),
    }
    check(agent.find_repeat(history, "entity.fields", {entity_type = "sample"}, never_write) == "c1", "an exact repeat should find the earlier call")
    check(agent.find_repeat(history, "entity.fields", {entity_type = "plant"}, never_write) == nil, "other arguments are not a repeat")
    check(agent.find_repeat(history, "entity.query", {sql = "SELECT 1"}, never_write) == nil, "entity.query is not repeat-safe (data can change)")

    print("Testing find_repeat: an error result, a missing result, or a write since don't count")
    errored = {call("c1", "entity.fields", {entity_type = "sample"}), result("c1", "entity.fields", "ERROR", true)}
    check(agent.find_repeat(errored, "entity.fields", {entity_type = "sample"}, never_write) == nil, "an errored call should run again")
    unanswered = {call("c1", "entity.fields", {entity_type = "sample"})}
    check(agent.find_repeat(unanswered, "entity.fields", {entity_type = "sample"}, never_write) == nil, "a call with no result in context should run again")
    written = {
        call("c1", "document.search", {query = "media"}), result("c1", "document.search", "#1 Media"),
        call("c2", "document.create", {title = "Media notes"}), result("c2", "document.create", "created #2"),
    }
    check(agent.find_repeat(written, "document.search", {query = "media"}, writes_documents) == nil, "a write after the earlier call should make it run again")
    rewritten = {
        call("c2", "document.create", {title = "x"}), result("c2", "document.create", "created"),
        call("c3", "document.search", {query = "media"}), result("c3", "document.search", "#1 Media"),
    }
    check(agent.find_repeat(rewritten, "document.search", {query = "media"}, writes_documents) == "c3", "a write before the earlier call doesn't matter")
end

function stored_call(id, name, args)
    return {role = "assistant", content = json.encode({blocks = {{type = "toolCall", id = id, name = name, arguments = args}}})}
end

function stored_result(id, name, text)
    return {role = "tool_result", content = json.encode({tool_call_id = id, tool_name = name, text = text, is_error = false})}
end

function test_pinned_schema_block()
    print("Testing pinned_schema_block keeps the latest schema result per call, newest first")
    rows = {
        stored_call("a", "entity.fields", {entity_type = "sample"}), stored_result("a", "entity.fields", "OLD sample fields"),
        stored_call("b", "entity.list_types", {}), stored_result("b", "entity.list_types", "sample, plant"),
        stored_call("c", "entity.query", {sql = "SELECT 1"}), stored_result("c", "entity.query", "1"),
        stored_call("d", "entity.fields", {entity_type = "sample"}), stored_result("d", "entity.fields", "NEW sample fields"),
    }
    block = agent.pinned_schema_block(rows, 6000)
    check(block != nil, "expected a pinned block")
    check(string.find(block, "NEW sample fields", 1, true) != nil, "the latest result for a call wins")
    check(string.find(block, "OLD sample fields", 1, true) == nil, "an older result for the same call is replaced")
    check(string.find(block, "sample, plant", 1, true) != nil, "list_types is pinned")
    check(string.find(block, "SELECT 1", 1, true) == nil, "entity.query isn't schema, so it isn't pinned")

    print("Testing the pinned block survives a second compaction, and the budget names what doesn't fit")
    summary = {role = "compaction_summary", content = "Prose summary.\n\n" .. block}
    body, entries = agent.split_pinned_schema(summary.content)
    check(body == "Prose summary.", "the prose is split from the block, got: " .. tostring(body))
    check(#entries == 2, "two entries parsed back, got " .. tostring(#entries))
    again = agent.pinned_schema_block({summary, stored_call("e", "entity.relationships", {}), stored_result("e", "entity.relationships", "sample.experiment -> experiment")}, 6000)
    check(string.find(again, "NEW sample fields", 1, true) != nil and string.find(again, "sample.experiment", 1, true) != nil, "old entries carry over and new ones join them")
    tight = agent.pinned_schema_block({summary}, 60)
    check(string.find(tight, "not kept", 1, true) != nil, "entries over the budget are named as not kept")
    reparsed_body, reparsed = agent.split_pinned_schema("x\n\n" .. tight)
    carried = agent.pinned_schema_block({{role = "compaction_summary", content = "x\n\n" .. tight}}, 6000)
    check(carried == nil or string.find(carried, "(not kept", 1, true) == nil, "a names-only line isn't carried as if it were a result")
end

test_canonical_json_ignores_key_order()
test_find_repeat()
test_pinned_schema_block()

if FAILURES > 0 then
    print(FAILURES .. " test(s) failed")
    os.exit(1)
end
print("All agent_keep_known.lua tests passed")
