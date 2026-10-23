-- Runs one scenario against a demo-lab deployment in the current
-- directory (a per-run copy made by bld/eval.sh -- see
-- doc/agent-eval.md, "Runner and report").
--
--   luam run_scenario.lua script <scenario.lua>
--       prints the scenario's scripted replies for test mode, joined
--       the way AGENT_TEST_RESPONSES expects
--   luam run_scenario.lua run <scenario.lua> <mode> <repeat> <set>
--       plays the conversation, runs its checks, prints one JSON line
--       (nothing if the scenario isn't in <set>: core, growth or all)
--   luam run_scenario.lua rescore <scenario.lua> <mode> <repeat> <set> <session_id> <status>
--       runs the checks again on a conversation already played here, so
--       a corrected check never needs the model calls paid twice
--
-- A scenario file returns function(facts, s) -> scenario table:
--   name, set ("core" | "growth"), traps = {...}, turns = {"..."},
--   approval ("approve" | "deny" | "leave", for pending actions),
--   script = {...} (test mode: s.tool(...) / s.final(...) entries),
--   checks = {{kind = "answer", ...}, ...} (see tst/eval/checks.lua)
-- `facts` is the deployment's facts.json; s.id(key) gives a record's
-- real id.

json = require("dkjson")
db = require("database")
config = require("config")
agent = require("agent")
agent_tools = require("agent_tools")
context_report = require("context_report")

checks = dofile(string.match(arg[0], "^(.*)/[^/]*$") .. "/checks.lua")

function read_file(path)
    file = io.open(path, "r")
    if file == nil then
        error("cannot read " .. path)
    end
    text = io.read(file, "*all")
    io.close(file)
    return text
end

facts = json.decode(read_file("facts.json"))

-- Scripted-reply builders for test mode, in the canonical shape the
-- test provider's converse() decodes (src/provider/agent_test.lua).
helpers = {next_call = 0}

function helpers.id(key)
    id = facts.ids[key]
    if id == nil then
        error("no record with key " .. tostring(key))
    end
    return id
end

function helpers.tool(name, arguments)
    helpers.next_call = helpers.next_call + 1
    if arguments == nil then
        arguments = setmetatable({}, {__jsontype = "object"})
    end
    return json.encode({
        content = {{type = "toolCall", id = "call_" .. helpers.next_call, name = name, arguments = arguments}},
        stopReason = "toolUse",
    })
end

-- A final answer, followed by the self-check's CONFIRM: run_turn asks
-- the model to check every final answer before it goes out.
function helpers.final(text)
    return {
        json.encode({content = {{type = "text", text = text}}, stopReason = "stop"}),
        json.encode({content = {{type = "text", text = "CONFIRM"}}, stopReason = "stop"}),
    }
end

function load_scenario(path)
    builder = dofile(path)
    return builder(facts, helpers)
end

function flatten(list, out)
    for _, item in ipairs(list) do
        if type(item) == "table" then
            flatten(item, out)
        else
            table.insert(out, item)
        end
    end
    return out
end

command = arg[1]
scenario_path = arg[2]
if command == nil or scenario_path == nil then
    print("Usage: luam run_scenario.lua script <scenario.lua> | run|rescore <scenario.lua> <mode> <repeat> <set> [<session_id> <status>]")
    os.exit(2)
end
scenario = load_scenario(scenario_path)

if command == "script" then
    script = {}
    if scenario.script != nil then
        script = flatten(scenario.script, {})
    end
    io.write(table.concat(script, "\1"))
    os.exit(0)
end

mode = arg[3]
repeat_index = tonumber(arg[4])
wanted_set = arg[5]
if wanted_set != nil and wanted_set != "all" and wanted_set != scenario.set then
    os.exit(0)
end

db_path = config.db_path(".")
-- The demo-lab copy is cached across code changes (bld/eval-env.sh), so
-- bring its tables up to date the way a web request would.
knowledge = require("knowledge")
knowledge.init_schema(db_path)
login = facts.user
model = agent.default_model()
started = os.time()

status = nil
run_error = nil
session_id = nil
turns = scenario.turns
if command == "rescore" then
    session_id = arg[6]
    status = arg[7]
    turns = {}
else
    session_id = agent.create_session(db_path, login, scenario.name)
end
for _, turn_text in ipairs(turns) do
    result, err = agent.run_turn(db_path, session_id, login, nil, model, turn_text)
    -- Approvals resume the same turn; bounded so a scenario can never
    -- loop forever on a model that keeps proposing writes.
    approvals = 0
    while result != nil and result.status == "pending_approval" and approvals < 10 do
        approvals = approvals + 1
        if scenario.approval == "approve" then
            result, err = agent.approve_pending(db_path, result.pending_id, login, nil, model)
        elseif scenario.approval == "deny" then
            result, err = agent.deny_pending(db_path, result.pending_id, login, nil, model)
        else
            break
        end
    end
    if result == nil then
        status = "error"
        run_error = tostring(err)
        break
    end
    status = result.status
end

message_rows = db.query(db_path, string.format(
    "SELECT id, role, content FROM agent_message WHERE session_id = %s ORDER BY id;", db.quote(session_id)))
pending_rows = db.query(db_path, string.format(
    "SELECT id, tool, method, status, tool_call_id FROM agent_pending_action WHERE session_id = %s ORDER BY id;", db.quote(session_id)))
conv = checks.conversation(message_rows, pending_rows)

ctx = {
    status = status,
    query = function(sql) return db.query(db_path, sql) end,
    is_destructive = function(full_name)
        dot = string.find(full_name, ".", 1, true)
        if dot == nil then
            return false
        end
        return agent.is_destructive(db_path, string.sub(full_name, 1, dot - 1), string.sub(full_name, dot + 1))
    end,
}

results = {}
all_pass = true
for _, spec in ipairs(scenario.checks) do
    outcome = checks.run(spec.kind, conv, spec, ctx)
    outcome.kind = spec.kind
    table.insert(results, outcome)
    if outcome.pass != true then
        all_pass = false
    end
end

-- A readable transcript beside the run's database, for the report to
-- point at when a check fails.
lines = {"# " .. scenario.name .. " (" .. tostring(mode) .. ", repeat " .. tostring(repeat_index) .. ")", ""}
for _, msg in ipairs(conv.messages) do
    if msg.role == "tool_result" then
        marker = ""
        if msg.is_error == true then
            marker = " (error)"
        end
        table.insert(lines, "**tool result** `" .. tostring(msg.tool_name) .. "`" .. marker ..
            ":\n\n```\n" .. msg.text .. "\n```\n")
    else
        table.insert(lines, "**" .. msg.role .. "**: " .. msg.text)
        for _, call in ipairs(msg.tool_calls) do
            table.insert(lines, "- calls `" .. tostring(call.name) .. "` " .. json.encode(call.arguments))
        end
        table.insert(lines, "")
    end
end
file = io.open("transcript.md", "w")
io.write(file, table.concat(lines, "\n"))
io.close(file)

usage = db.query(db_path, string.format(
    "SELECT COALESCE(SUM(total_tokens), 0) AS tokens, COUNT(*) AS calls, COALESCE(MAX(prompt_tokens), 0) AS peak FROM knowledge_context WHERE session_id = %s;",
    db.quote(session_id)))[1]

-- Context cost beyond total tokens (doc/context-management-plan.md,
-- Phase 0): re-fetches of an identical call, and compactions.
repeat_rows = {}
compactions = 0
for _, row in ipairs(message_rows) do
    table.insert(repeat_rows, {session_id = session_id, role = row.role, content = row.content})
    if row.role == "compaction_summary" then
        compactions = compactions + 1
    end
end
_, exact_repeats = context_report.count_exact_repeats(repeat_rows)

print(json.encode({
    scenario = scenario.name,
    set = scenario.set,
    traps = scenario.traps,
    mode = mode,
    ["repeat"] = repeat_index,
    status = status,
    error = run_error,
    pass = all_pass,
    checks = results,
    final_text = conv.final_text,
    tokens = tonumber(usage.tokens),
    model_calls = tonumber(usage.calls),
    peak_prompt_tokens = tonumber(usage.peak),
    exact_repeat_calls = exact_repeats,
    compactions = compactions,
    seconds = os.time() - started,
    session_id = session_id,
}))
