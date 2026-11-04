-- tst/unit/agent_tool_registry.lua
-- The tool registry's own rules (doc/agent-tools.md, "One registry" and
-- "Invariants"; #6): every record's fields are well-formed, an extension
-- that would shadow a built-in or declare a tool twice is left out whole,
-- an extension tool becomes a record of the same shape, and what a
-- research sub-agent may call is one predicate. agent.build_tool_registry
-- is pure, so none of this needs a database.

agent = require("agent")
agent_tools = require("agent_tools")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

-- Luam's type() calls a boolean a "flag".
function optional_flag(value)
    return value == nil or type(value) == "flag"
end

function extension_entry(name, tools)
    return {name = name, manifest = {name = name, capabilities = {tools = tools}}}
end

function tool(name, destructive)
    return {name = name, description = name .. " does a thing", destructive = destructive, parameters = {type = "object", properties = {}}}
end

function test_every_builtin_record_follows_the_field_rules()
    print("Testing every built-in record's fields are well-formed")
    for group, methods in pairs(agent_tools.AGENT_TOOLS) do
        for method, record in pairs(methods) do
            name = group .. "." .. method
            check(type(record.destructive) == "flag", name .. ": destructive must be true or false")
            check(optional_flag(record.in_research), name .. ": in_research must be true, false or absent")
            check(record.control == nil or agent.CONTROL_KINDS[record.control] != nil,
                name .. ": control '" .. tostring(record.control) .. "' isn't a CONTROL_KINDS kind")
            -- Until #6 moves it, a tool's handler is still execute_tool's
            -- branch; tst/unit/agent_tools.lua checks every tool reaches one.
            check(record.handler == nil or type(record.handler) == "function", name .. ": handler must be a function")
            -- precheck runs on the way to approval, which only a
            -- destructive tool takes.
            check(record.precheck == nil or type(record.precheck) == "function", name .. ": precheck must be a function")
            if record.precheck != nil then
                check(record.destructive == true, name .. ": precheck is only for destructive tools")
            end
            if record.control != nil then
                check(record.in_research != true, name .. ": a control tool can't be in_research")
            end
            if record.destructive == true then
                check(record.in_research != true, name .. ": a destructive tool can't be in_research")
            end
        end
    end
end

function test_control_tools_are_the_three_kinds()
    print("Testing the control tools are research, clarify and background")
    found = {}
    for group, methods in pairs(agent_tools.AGENT_TOOLS) do
        for method, record in pairs(methods) do
            if record.control != nil then
                found[group .. "." .. method] = record.control
            end
        end
    end
    check(found["research.investigate"] == "research", "research.investigate should be control = research")
    check(found["clarify.ask"] == "clarify", "clarify.ask should be control = clarify")
    check(found["background.start"] == "background", "background.start should be control = background")
    check(found["background.status"] == "background", "background.status should be control = background")
    count = 0
    for _, _ in pairs(found) do
        count = count + 1
    end
    check(count == 4, "expected exactly 4 control tools, found " .. count)
end

-- run_turn handles a turn-ending kind from its row alone, so the row must
-- say everything it needs.
function test_turn_ending_kinds_are_complete()
    print("Testing every turn-ending control kind says what run_turn needs")
    for name, kind in pairs(agent.CONTROL_KINDS) do
        check(type(kind.ends_turn) == "flag", name .. ": ends_turn must be true or false")
        if kind.ends_turn == true then
            for _, field in ipairs({"result", "another_this_turn", "status", "message_argument"}) do
                check(type(kind[field]) == "string" and kind[field] != "", name .. ": a turn-ending kind needs " .. field)
            end
        end
    end
    check(agent.turn_ending_kind({control = "clarify"}) == agent.CONTROL_KINDS.clarify, "clarify ends the turn")
    check(agent.turn_ending_kind({control = "research"}) == nil, "research doesn't")
    check(agent.turn_ending_kind({destructive = true}) == nil, "a tool without a control kind doesn't")
    check(agent.turn_ending_kind(nil) == nil, "an unknown tool doesn't")
end

function test_research_may_call()
    print("Testing research_may_call: read-only, in_research, and no control kind")
    check(agent.research_may_call({destructive = false, in_research = true}) == true, "a read-only in_research tool is allowed")
    check(agent.research_may_call({destructive = false}) == false, "a tool without in_research is not")
    check(agent.research_may_call({destructive = true, in_research = true}) == false, "a destructive tool never is")
    check(agent.research_may_call({destructive = false, in_research = true, control = "research"}) == false, "a control tool never is")
    check(agent.research_may_call(nil) == false, "an unknown tool is not")
end

function test_extension_tools_become_records_in_manifest_order()
    print("Testing extension tools become records, after the built-ins, in manifest order")
    builtins = {document = {search = {destructive = false, in_research = true, description = "d", parameters = {}}}}
    registry, ordered, refused = agent.build_tool_registry(builtins, {
        extension_entry("widgets", {tool("lookup", false), tool("bump", true), tool("peek", nil)}),
    })
    check(#refused == 0, "nothing should be refused")
    check(#ordered == 4, "expected 1 built-in and 3 extension tools, got " .. #ordered)
    check(ordered[1].group == "document", "built-ins come first")
    check(ordered[2].method == "lookup" and ordered[3].method == "bump" and ordered[4].method == "peek",
        "extension tools keep their manifest order")
    lookup = registry.widgets.lookup
    bump = registry.widgets.bump
    peek = registry.widgets.peek
    check(lookup.destructive == false and lookup.in_research == true, "a read-only extension tool is available to research")
    check(bump.destructive == true and bump.in_research == false, "a destructive extension tool is not")
    check(peek.destructive == false, "an absent destructive flag means read-only, as before")
    check(lookup.repeat_safe == false and lookup.pin_on_compaction == false, "extension tools are never answered from context or pinned")
    check(lookup.extension == "widgets", "an extension record names its extension")
    check(lookup.description == "lookup does a thing" and lookup.parameters.type == "object", "description and parameters come from the manifest")
end

function test_an_extension_named_after_a_builtin_group_is_refused()
    print("Testing an extension named after a built-in group is left out whole")
    builtins = {stats = {fit = {destructive = false, in_research = true, description = "d", parameters = {}}}}
    registry, ordered, refused = agent.build_tool_registry(builtins, {
        extension_entry("stats", {tool("summary", false)}),
    })
    check(#refused == 1 and refused[1].name == "stats", "the colliding extension should be refused")
    check(registry.stats.summary == nil, "its tool must not be merged into the built-in group")
    check(registry.stats.fit != nil, "the built-in group is untouched")
    check(#ordered == 1, "only the built-in tool is declared")
end

function test_an_extension_declaring_a_tool_twice_is_refused()
    print("Testing an extension that declares the same tool twice is left out whole")
    registry, ordered, refused = agent.build_tool_registry({}, {
        extension_entry("widgets", {tool("lookup", false), tool("lookup", true)}),
        extension_entry("gadgets", {tool("peek", false)}),
    })
    check(#refused == 1 and refused[1].name == "widgets", "the extension with a duplicate tool should be refused")
    check(registry.widgets == nil, "none of its tools is registered")
    check(registry.gadgets != nil and registry.gadgets.peek != nil, "other extensions are unaffected")
    check(#ordered == 1 and ordered[1].group == "gadgets", "only the other extension's tool is declared")
end

test_every_builtin_record_follows_the_field_rules()
test_control_tools_are_the_three_kinds()
test_turn_ending_kinds_are_complete()
test_research_may_call()
test_extension_tools_become_records_in_manifest_order()
test_an_extension_named_after_a_builtin_group_is_refused()
test_an_extension_declaring_a_tool_twice_is_refused()

if FAILURES > 0 then
    print(FAILURES .. " failure(s)")
    os.exit(false)
end
print("agent tool registry tests passed")
