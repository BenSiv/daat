-- tst/unit/interrupted_write.lua
-- An approved write a crash left 'running' with no result (#22): the
-- model is told it may or may not have been done and to check first,
-- not "Run it again", which on a demo lab led it to propose the same
-- entity.create again on a plain "continue". pair_tool_results is pure:
-- it's told which call blocks are interrupted writes, and every other
-- call left without a result keeps the plain text.

agent = require("agent")

unit = require("unit")
check = unit.check
tests = unit.suite()

WRITE_TEXT = "may or may not have been done"
PLAIN_TEXT = "Run it again if you still need it"

function contains(text, part)
    return string.find(tostring(text), part, 1, true) != nil
end

-- The texts of the tool results, in order.
function result_texts(paired)
    out = {}
    for _, msg in ipairs(paired) do
        if msg.role == "toolResult" then
            table.insert(out, msg.content[1].text)
        end
    end
    return out
end

function tests.an_interrupted_write_is_told_to_check_and_a_read_is_told_to_retry()
    print("Testing an interrupted write gets the check-first text, an interrupted read the plain one")
    read_call = {type = "toolCall", id = "call_1", name = "entity.list_types", arguments = {}}
    write_call = {type = "toolCall", id = "call_1", name = "entity.create", arguments = {entity_type = "person"}}
    history = {
        {role = "user", content = "add Dana"},
        {role = "assistant", content = {read_call}},
        {role = "user", content = "go on"},
        {role = "assistant", content = {write_call}},
    }
    interrupted = {}
    interrupted[write_call] = true
    texts = result_texts(agent.pair_tool_results(history, interrupted))
    check(#texts == 2, "both calls answered, got " .. tostring(#texts))
    check(contains(texts[1], PLAIN_TEXT) and contains(texts[1], WRITE_TEXT) == false,
        "the read keeps the plain text although it shares the write's id, got: " .. tostring(texts[1]))
    check(contains(texts[2], WRITE_TEXT) and contains(texts[2], "Check whether it took effect")
        and contains(texts[2], PLAIN_TEXT) == false, "the write is told to check, got: " .. tostring(texts[2]))
end

function tests.without_the_set_every_unanswered_call_gets_the_plain_text()
    print("Testing no interrupted set means today's text")
    call = {type = "toolCall", id = "call_1", name = "entity.create", arguments = {}}
    texts = result_texts(agent.pair_tool_results({{role = "assistant", content = {call}}}))
    check(#texts == 1 and contains(texts[1], PLAIN_TEXT), "got: " .. tostring(texts[1]))
end

function tests.a_write_that_has_its_result_keeps_it()
    print("Testing a write whose result was stored isn't touched")
    call = {type = "toolCall", id = "call_1", name = "entity.create", arguments = {}}
    interrupted = {}
    interrupted[call] = true
    history = {
        {role = "assistant", content = {call}},
        {role = "toolResult", toolCallId = "call_1", toolName = "entity.create", content = {{type = "text", text = "Created person #289"}}},
    }
    texts = result_texts(agent.pair_tool_results(history, interrupted))
    check(#texts == 1 and texts[1] == "Created person #289", "the stored result wins, got: " .. tostring(texts[1]))
end

unit.run(tests)
