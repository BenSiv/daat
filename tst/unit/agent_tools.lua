-- tst/unit/agent_tools.lua
-- Consistency of the agent's built-in tools (#2): every tool declared in
-- agent_tools.AGENT_TOOLS has a well-formed declaration, reaches a
-- handler, and translates cleanly for both providers; every handler in
-- execute_tool is declared. A safety net for the tool-record migration
-- (#6): it checks behaviour (calling execute_tool), not where a handler
-- lives, so it stays valid while handlers move into records.

agent = require("agent")
agent_tools = require("agent_tools")
agent_claude = require("provider.agent_claude")
agent_vertex = require("provider.agent_vertex")
init = require("init")
json = require("dkjson")
lfs = require("lfs")

unit = require("unit")
check = unit.check
tests = unit.suite()

-- Declared, but deliberately not handled by execute_tool.
NOT_IN_EXECUTE_TOOL = {
    ["clarify.ask"] = "agent.run_turn handles it: asking ends the turn",
}

-- Declared with parameters = EMPTY_OBJECT_SCHEMA, which is nil in
-- agent_tools.lua: agent.lua assigns it at its own top level, and a bare
-- top-level assignment is local to its file in luam. So these go out
-- with no parameters at all (Vertex accepts that; Claude needs an
-- input_schema). Fixing it changes what the model sees, so it's its own
-- measured PR (#20); remove each name here when it lands.
KNOWN_WITHOUT_PARAMETERS = {
    ["entity.list_types"] = true,
    ["entity.relationships"] = true,
    ["template.list"] = true,
    ["knowledge.stats"] = true,
    ["view.list"] = true,
}

function each_declared(fn)
    for group, methods in pairs(agent_tools.AGENT_TOOLS) do
        for method, spec in pairs(methods) do
            fn(group, method, spec)
        end
    end
end

function tests.every_declaration_is_well_formed()
    print("Testing every declared tool has a description, an object schema and a boolean destructive")
    each_declared(function(group, method, spec)
        name = group .. "." .. method
        check(type(spec.description) == "string" and spec.description != "", name .. ": description must be a non-empty string")
        -- Luam's type() calls a boolean a "flag".
        check(type(spec.destructive) == "flag", name .. ": destructive must be true or false")
        params = spec.parameters
        if KNOWN_WITHOUT_PARAMETERS[name] == true then
            check(params == nil, name .. " now has parameters: remove it from KNOWN_WITHOUT_PARAMETERS")
        else
            check(type(params) == "table" and params.type == "object", name .. ": parameters must be a JSON Schema with type = \"object\"")
        end
        if type(params) == "table" and params.required != nil then
            properties = params.properties
            if properties == nil then
                properties = {}
            end
            for _, field in ipairs(params.required) do
                check(properties[field] != nil, name .. ": required names '" .. tostring(field) .. "', which isn't in properties")
            end
        end
    end)
end

-- Empty arguments: every handler checks its arguments before it touches
-- anything, so this reaches each handler without side effects. Any
-- result, error or raised error means a handler exists; only the
-- fall-through "unknown tool" result means it doesn't.
function tests.every_declared_method_reaches_a_handler(db_path)
    print("Testing every declared tool reaches a handler in execute_tool")
    each_declared(function(group, method, spec)
        name = group .. "." .. method
        ok, result, err = pcall(agent_tools.execute_tool, db_path, "test", 0, group, method, {})
        unknown = ok == true and result == nil and err == "unknown tool: " .. name
        if NOT_IN_EXECUTE_TOOL[name] != nil then
            check(unknown, name .. " is listed as not handled by execute_tool, but it is: remove it from NOT_IN_EXECUTE_TOOL")
        else
            check(unknown == false, name .. " is declared, but execute_tool has no handler for it")
        end
    end)
end

-- Every tool runs from its record's handler, and execute_tool is a lookup
-- (#6). A `tool_name == "x" and method_name == "y"` test anywhere in
-- agent_tools.lua would be a tool dispatched by name again, the way the
-- old if-chain did, and possibly in two places.
function tests.no_tool_is_dispatched_by_name()
    print("Testing agent_tools.lua dispatches no tool by name")
    f = io.open("src/agent_tools.lua", "r")
    check(f != nil, "can't open src/agent_tools.lua (run from the repo root)")
    if f == nil then
        return
    end
    source = io.read(f, "*a")
    io.close(f)
    for group, method in string.gmatch(source, "tool_name == \"([%w_]+)\" and method_name == \"([%w_]+)\"") do
        check(false, "agent_tools.lua dispatches " .. group .. "." .. method .. " by name; give its record a handler instead")
    end
end

-- The whole declaration list, as each provider receives it. A schema a
-- translation can't handle breaks every tool-calling turn, not just
-- calls to that tool. Empty `properties` must encode as {}: Vertex
-- refuses [] (see EMPTY_OBJECT_SCHEMA in agent.lua).
function tests.declarations_translate_for_both_providers(db_path)
    print("Testing every declaration translates and encodes for Claude and Vertex")
    declarations = agent.tool_declarations(db_path)
    check(#declarations > 0, "agent.tool_declarations returned nothing")
    translators = {
        {"claude", agent_claude.claude_tools_from_canonical},
        {"vertex", agent_vertex.vertex_tools_from_canonical},
    }
    for _, pair in ipairs(translators) do
        provider = pair[1]
        ok, translated = pcall(pair[2], declarations)
        check(ok, provider .. ": translation raised: " .. tostring(translated))
        if ok == true then
            check(#translated == #declarations, provider .. ": expected " .. #declarations .. " tools, got " .. #translated)
            encoded_ok, encoded = pcall(json.encode, translated)
            check(encoded_ok, provider .. ": the translated tools don't encode as JSON: " .. tostring(encoded))
            if encoded_ok == true then
                check(string.find(encoded, "\"properties\":[]", 1, true) == nil,
                    provider .. ": an empty properties object encodes as [] instead of {}")
            end
        end
    end
end

-- What the model is shown, byte for byte (#6): moving tools into records
-- must not change a single declaration, and a change that should is its
-- own measured PR. One declaration per line, so a diff of a fixture
-- names the tool that changed. The order is pairs() over AGENT_TOOLS,
-- which is the same from run to run. After an intended change,
-- regenerate with DAAT_UPDATE_SNAPSHOT=1 and say why in the PR.
-- The research sub-agent's list is pinned the same way: it is what that
-- model is shown, and #6 keeps it to the same 21 tools.
SNAPSHOTS = {
    {path = "tst/unit/fixtures/tool_declarations.json", name = "agent.tool_declarations", list = function(db_path)
        return agent.tool_declarations(db_path)
    end},
    {path = "tst/unit/fixtures/research_tool_declarations.json", name = "agent_tools.research_tool_declarations", list = function(db_path)
        return agent_tools.research_tool_declarations(db_path)
    end},
}

function declarations_snapshot(declarations)
    lines = {}
    for _, declaration in ipairs(declarations) do
        table.insert(lines, json.encode(declaration))
    end
    return table.concat(lines, "\n") .. "\n"
end

function tests.declarations_match_the_snapshots(db_path)
    for _, snapshot in ipairs(SNAPSHOTS) do
        current = declarations_snapshot(snapshot.list(db_path))
        if os.getenv("DAAT_UPDATE_SNAPSHOT") == "1" then
            f = io.open(snapshot.path, "w")
            io.write(f, current)
            io.close(f)
            print("  wrote " .. snapshot.path)
        else
            f = io.open(snapshot.path, "r")
            check(f != nil, "can't open " .. snapshot.path .. " (run from the repo root)")
            if f != nil then
                expected = io.read(f, "*a")
                io.close(f)
                check(current == expected, snapshot.name .. " no longer matches " .. snapshot.path ..
                    ": what the model sees changed. If that's intended, regenerate it with DAAT_UPDATE_SNAPSHOT=1 and say why in the PR")
            end
        end
    end
end

dir = os.tmpname()
os.remove(dir)
lfs.mkdir(dir)
init.do_init({}, dir)
db_path = dir .. "/.store/store.db"

-- A failure exits inside unit.run and leaves the temp store behind to
-- look at; a clean run removes it.
unit.run(tests, db_path)
os.execute("rm -rf '" .. dir .. "'")
