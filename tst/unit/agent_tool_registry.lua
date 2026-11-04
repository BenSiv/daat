-- tst/unit/agent_tool_registry.lua
-- The tool registry's own rules (doc/agent-tools.md, "One registry" and
-- "Invariants"; #6): every record's fields are well-formed, an extension
-- that would shadow a built-in or declare a tool twice is left out whole,
-- an extension tool becomes a record of the same shape, and what a
-- research sub-agent may call is one predicate. agent.build_tool_registry
-- is pure; only the dispatcher tests, which call execute_tool, use a store.

agent = require("agent")
agent_tools = require("agent_tools")
init = require("init")
lfs = require("lfs")

unit = require("unit")
check = unit.check
tests = unit.suite()

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

function tests.every_builtin_record_follows_the_field_rules()
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
                -- Answering a write with "same as before" would skip it.
                check(record.repeat_safe != true, name .. ": a destructive tool can't be repeat_safe")
                check(record.pin_on_compaction != true, name .. ": a destructive tool can't be pin_on_compaction")
            end
            check(optional_flag(record.repeat_safe), name .. ": repeat_safe must be true, false or absent")
            check(optional_flag(record.pin_on_compaction), name .. ": pin_on_compaction must be true, false or absent")
        end
    end
end

function tests.control_tools_are_the_three_kinds()
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

-- The record fields replace two hand-kept lists in agent.lua (Context
-- Phase 1); the migration copies them as they were, and adding to either
-- set is its own measured PR (doc/agent-tools.md, "Decisions").
function names_with(field)
    names = {}
    for group, methods in pairs(agent_tools.AGENT_TOOLS) do
        for method, record in pairs(methods) do
            if record[field] == true then
                table.insert(names, group .. "." .. method)
            end
        end
    end
    table.sort(names)
    return table.concat(names, ", ")
end

function tests.repeat_safe_and_pinned_are_the_lists_they_replace()
    print("Testing repeat_safe and pin_on_compaction mark exactly the tools the old lists named")
    check(names_with("repeat_safe") == "document.children, document.search, entity.fields, entity.get, entity.list_types, entity.relationships",
        "repeat_safe tools changed: " .. names_with("repeat_safe"))
    check(names_with("pin_on_compaction") == "entity.fields, entity.list_types, entity.relationships",
        "pin_on_compaction tools changed: " .. names_with("pin_on_compaction"))
    check(agent.builtin_tool_has("entity.get", "repeat_safe") == true, "builtin_tool_has reads the record")
    check(agent.builtin_tool_has("entity.get", "pin_on_compaction") == false, "entity.get isn't pinned")
    check(agent.builtin_tool_has("entity.create", "repeat_safe") == false, "a write is never repeat_safe")
    check(agent.builtin_tool_has("widgets.lookup", "repeat_safe") == false, "an unknown or extension tool is never repeat_safe")
    check(agent.builtin_tool_has("nodot", "repeat_safe") == false, "a name without a dot isn't a tool")
end

-- run_turn handles a turn-ending kind from its row alone, so the row must
-- say everything it needs.
function tests.turn_ending_kinds_are_complete()
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

function tests.research_may_call()
    print("Testing research_may_call: read-only, in_research, and no control kind")
    check(agent.research_may_call({destructive = false, in_research = true}) == true, "a read-only in_research tool is allowed")
    check(agent.research_may_call({destructive = false}) == false, "a tool without in_research is not")
    check(agent.research_may_call({destructive = true, in_research = true}) == false, "a destructive tool never is")
    check(agent.research_may_call({destructive = false, in_research = true, control = "research"}) == false, "a control tool never is")
    check(agent.research_may_call(nil) == false, "an unknown tool is not")
end

function tests.extension_tools_become_records_in_manifest_order()
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

function tests.an_extension_named_after_a_builtin_group_is_refused()
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

function tests.an_extension_declaring_a_tool_twice_is_refused()
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

-- The dispatcher (agent_tools.execute_tool): a record's own handler runs
-- before the old chain, and a failed call gets its recover hint. A fake
-- group is added to AGENT_TOOLS for the call and removed after; the
-- registry is built per call, so it sees it.
function with_fake_tool(record, fn)
    agent_tools.AGENT_TOOLS.zz_test = {probe = record}
    ok, err = pcall(fn)
    agent_tools.AGENT_TOOLS.zz_test = nil
    check(ok, "the test itself raised: " .. tostring(err))
end

function fake_record(handler, recover)
    return {destructive = false, description = "probe", parameters = {type = "object"}, handler = handler, recover = recover}
end

function tests.a_record_handler_runs_before_the_chain(db_path)
    print("Testing a record's handler is called with ctx and args, before the old chain")
    with_fake_tool(fake_record(function(ctx, args)
        return "handled by " .. ctx.author .. " in " .. ctx.session_id .. ": " .. tostring(args.n)
    end), function()
        result, err = agent_tools.execute_tool(db_path, "alice", "s1", "zz_test", "probe", {n = 7})
        check(result == "handled by alice in s1: 7", "expected the handler's result, got " .. tostring(result) .. " / " .. tostring(err))
    end)
end

function tests.recover_adds_to_a_failed_call(db_path)
    print("Testing recover adds its hint to a failed call's error, and only then")
    with_fake_tool(fake_record(function(ctx, args) return nil, "bad input" end,
        function(ctx, args, err) return "try " .. tostring(args.n + 1) end), function()
        result, err = agent_tools.execute_tool(db_path, "alice", "s1", "zz_test", "probe", {n = 1})
        check(result == nil and err == "bad input -- try 2", "expected the error with the hint, got " .. tostring(err))
    end)

    called = false
    with_fake_tool(fake_record(function(ctx, args) return "fine" end,
        function(ctx, args, err)
            called = true
            return "never"
        end), function()
        result, err = agent_tools.execute_tool(db_path, "alice", "s1", "zz_test", "probe", {})
        check(result == "fine" and err == nil, "a successful call is returned as it is")
    end)
    check(called == false, "recover must not run after a success")

    for _, broken in ipairs({
        function(ctx, args, err) return nil end,
        function(ctx, args, err) return "" end,
        function(ctx, args, err) error("recover itself failed") end,
    }) do
        with_fake_tool(fake_record(function(ctx, args) return nil, "bad input" end, broken), function()
            result, err = agent_tools.execute_tool(db_path, "alice", "s1", "zz_test", "probe", {})
            check(err == "bad input", "a recover with no hint, or one that fails, leaves the error as it was; got " .. tostring(err))
        end)
    end
end

-- The groups #6 has moved so far, one step at a time: every tool in them
-- runs from its record. A step adds its groups here, in the same commit
-- that deletes their branches from execute_tool_chain.
MOVED_GROUPS = {"document", "entity", "knowledge", "view", "template", "result", "calc", "stats", "plot",
    "research", "background", "clarify"}

-- The one tool without a handler is one whose control kind ends the turn
-- (clarify.ask): run_turn does that from its CONTROL_KINDS row, so a
-- handler there would never run.
function tests.every_tool_in_a_moved_group_has_a_handler()
    print("Testing every tool in a moved group runs from its record")
    for _, group in ipairs(MOVED_GROUPS) do
        check(agent_tools.AGENT_TOOLS[group] != nil, "no tool group " .. group)
        if agent_tools.AGENT_TOOLS[group] != nil then
            for method, record in pairs(agent_tools.AGENT_TOOLS[group]) do
                if agent.turn_ending_kind(record) != nil then
                    check(record.handler == nil, group .. "." .. method .. " ends the turn, so it has no handler")
                else
                    check(type(record.handler) == "function", group .. "." .. method .. " has no handler")
                end
            end
        end
    end
end

-- Step 1: document.update's precheck says what reject_before_approval
-- used to, word for word.
function tests.document_update_has_its_precheck()
    print("Testing document.update's precheck")
    update = agent_tools.AGENT_TOOLS.document.update
    check(type(update.precheck) == "function", "document.update has no precheck")
    check(update.precheck({}, {}) == "nothing to update: pass title, content or parent_id",
        "document.update's precheck text changed")
    check(update.precheck({}, {title = "New title"}) == nil, "a document.update with a field to change goes to approval")
end

-- Step 2: entity.update's precheck takes the last case
-- reject_before_approval had, which is gone.
function tests.entity_update_has_its_precheck()
    print("Testing entity.update's precheck")
    update = agent_tools.AGENT_TOOLS.entity.update
    check(type(update.precheck) == "function", "entity.update has no precheck")
    check(update.precheck({}, {entity_type = "task", entity_id = 1}) ==
        "nothing to update: pass each field to change as its own argument, e.g. status = \"finished\"",
        "entity.update's precheck text changed")
    check(update.precheck({}, {entity_type = "task", entity_id = 1, reason = "why"}) != nil,
        "a reason alone is not a field to change")
    check(update.precheck({}, {entity_type = "task", entity_id = 1, status = "done"}) == nil,
        "an entity.update with a field to change goes to approval")
    check(agent_tools.reject_before_approval == nil, "reject_before_approval should be gone")
end

-- The hints that moved into shared helpers still read exactly as before:
-- what the model is told must not change during the migration.
function tests.moved_hints_keep_their_text(db_path)
    print("Testing the shared hints produce the texts tools wrote out before")
    result, err = agent_tools.execute_tool(db_path, "test", 0, "entity", "list", {entity_type = "zz_nope"})
    check(err == "unknown entity type: zz_nope -- call entity.list_types for the full list",
        "entity.list's unknown-type error changed: " .. tostring(err))
    check(agent_tools.hint_result_columns({"id", "od"}) == "actual columns: id, od", "hint_result_columns changed")
    check(agent_tools.hint_entity_type({db_path = db_path}, "zz_nope") == "call entity.list_types for the full list",
        "hint_entity_type without a near match changed")
end

dir = os.tmpname()
os.remove(dir)
lfs.mkdir(dir)
init.do_init({}, dir)
db_path = dir .. "/.store/store.db"

-- The dispatcher tests call execute_tool, which needs a store; the rest
-- ignore the argument. A failure exits inside unit.run and leaves the
-- temp store behind to look at; a clean run removes it.
unit.run(tests, db_path)
os.execute("rm -rf '" .. dir .. "'")
