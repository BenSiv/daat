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

USAGE = "Usage: luam run_scenario.lua script <scenario.lua> | run|rescore <scenario.lua> <mode> <repeat> <set> [<session_id> <status>]"

function read_file(path)
    file = io.open(path, "r")
    if file == nil then
        error("cannot read " .. path)
    end
    text = io.read(file, "*all")
    io.close(file)
    return text
end

-- Scripted-reply builders for test mode, in the canonical shape the
-- test provider's converse() decodes (src/provider/agent_test.lua),
-- handed to a scenario file as its `s`. Built per run around the
-- deployment's facts, which s.id reads.
function make_helpers(facts)
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

    -- A final answer. run_turn's self-check after it is a no-tools call,
    -- which the test provider answers with CONFIRM by itself without
    -- taking from the script (src/provider/agent_test.lua) -- a scripted
    -- CONFIRM here would be read as the next turn's first reply.
    function helpers.final(text)
        return json.encode({content = {{type = "text", text = text}}, stopReason = "stop"})
    end

    return helpers
end

function load_scenario(path, facts)
    builder = dofile(path)
    return builder(facts, make_helpers(facts))
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

-- `script`: the scenario's scripted replies, joined the way
-- AGENT_TEST_RESPONSES expects.
function print_script(scenario)
    script = {}
    if scenario.script != nil then
        script = flatten(scenario.script, {})
    end
    io.write(table.concat(script, "\1"))
end

-- Plays every turn of the scenario in a new session, answering pending
-- actions as scenario.approval says. Returns the session id, the last
-- turn's status, and the error that stopped it, if any.
function play(db_path, login, model, scenario)
    session_id = agent.create_session(db_path, login, scenario.name)
    status = nil
    for _, turn_text in ipairs(scenario.turns) do
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
            return session_id, "error", tostring(err)
        end
        status = result.status
    end
    return session_id, status, nil
end

-- Runs the scenario's checks on the session's conversation. Returns
-- the conversation, each check's outcome, and whether all passed.
function score(db_path, scenario, session_id, status, message_rows)
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
    return conv, results, all_pass
end

-- A readable transcript beside the run's database, for the report to
-- point at when a check fails.
function write_transcript(path, scenario, mode, repeat_index, conv)
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
    file = io.open(path, "w")
    io.write(file, table.concat(lines, "\n"))
    io.close(file)
end

-- What the session cost: tokens and model calls, and context cost
-- beyond total tokens (doc/context-management-plan.md, Phase 0) --
-- re-fetches of an identical call, compactions, and whole-document
-- reads after searching (doc/passage-retrieval-plan.md), which say
-- whether search excerpts were enough.
function session_cost(db_path, session_id, message_rows)
    usage = db.query(db_path, string.format(
        "SELECT COALESCE(SUM(total_tokens), 0) AS tokens, COUNT(*) AS calls, COALESCE(MAX(prompt_tokens), 0) AS peak FROM agent_model_call WHERE session_id = %s;",
        db.quote(session_id)))[1]

    repeat_rows = {}
    compactions = 0
    for _, row in ipairs(message_rows) do
        table.insert(repeat_rows, {session_id = session_id, role = row.role, content = row.content})
        if row.role == "compaction_summary" then
            compactions = compactions + 1
        end
    end
    by_tool, exact_repeats = context_report.count_exact_repeats(repeat_rows)
    entity_get_calls = 0
    if by_tool["entity.get"] != nil then
        entity_get_calls = by_tool["entity.get"].calls
    end
    return {
        tokens = tonumber(usage.tokens),
        model_calls = tonumber(usage.calls),
        peak_prompt_tokens = tonumber(usage.peak),
        exact_repeat_calls = exact_repeats,
        compactions = compactions,
        entity_get_calls = entity_get_calls,
    }
end

-- `run` plays the scenario and scores it; `rescore` scores a session
-- already played here. Either way, one JSON line on stdout.
function run_and_score(command, argv, scenario, login)
    mode = argv[3]
    repeat_index = tonumber(argv[4])
    wanted_set = argv[5]
    if wanted_set != nil and wanted_set != "all" and wanted_set != scenario.set then
        return
    end

    db_path = config.db_path(".")
    -- The demo-lab copy is cached across code changes (bld/eval-env.sh), so
    -- bring its tables up to date the way a web request would.
    require("store").migrate(db_path)
    agent.init_schema(db_path)
    started = os.time()

    session_id = nil
    status = nil
    run_error = nil
    if command == "rescore" then
        session_id = argv[6]
        status = argv[7]
    else
        session_id, status, run_error = play(db_path, login, agent.default_model(), scenario)
    end

    message_rows = db.query(db_path, string.format(
        "SELECT id, role, content FROM agent_message WHERE session_id = %s ORDER BY id;", db.quote(session_id)))
    conv, results, all_pass = score(db_path, scenario, session_id, status, message_rows)
    write_transcript("transcript.md", scenario, mode, repeat_index, conv)
    cost = session_cost(db_path, session_id, message_rows)

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
        tokens = cost.tokens,
        model_calls = cost.model_calls,
        peak_prompt_tokens = cost.peak_prompt_tokens,
        exact_repeat_calls = cost.exact_repeat_calls,
        compactions = cost.compactions,
        entity_get_calls = cost.entity_get_calls,
        seconds = os.time() - started,
        session_id = session_id,
    }))
end

function main(argv)
    command = argv[1]
    scenario_path = argv[2]
    if command == nil or scenario_path == nil then
        print(USAGE)
        os.exit(2)
    end
    facts = json.decode(read_file("facts.json"))
    scenario = load_scenario(scenario_path, facts)
    if command == "script" then
        print_script(scenario)
    elseif command == "run" or command == "rescore" then
        run_and_score(command, argv, scenario, facts.user)
    else
        print(USAGE)
        os.exit(2)
    end
end

main(arg)
