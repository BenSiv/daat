-- tst/integration/lua/run_tool_gate.lua
-- agent.run_tool runs a destructive tool only against an agent_pending_action
-- row this request claimed (doc/agent-tools.md, "Invariants", rule 1; #6),
-- with the arguments from that row. Run by agent.bats from TEST_DIR, as a
-- user named alice; prints one line per case for the test to match.

db = require("database")
config = require("config")
agent = require("agent")
json = require("dkjson")

db_path = config.db_path(".")
agent.init_schema(db_path)
session_id = agent.create_session(db_path, "alice", "gate")

function pending(method, title)
    db.exec(db_path, string.format(
        "INSERT INTO agent_pending_action (session_id, tool, method, args_json) VALUES (%s, 'document', %s, %s);",
        db.quote(session_id), db.quote(method), db.quote(json.encode({title = title, content = "x"}))
    ))
    return tonumber(db.query(db_path, "SELECT MAX(id) AS id FROM agent_pending_action;")[1].id)
end

function report(case, result, err)
    print(case .. ": " .. tostring(result) .. " | " .. tostring(err))
end

-- No approval at all: a caller that forgot to go through approve_pending.
report("no approval", agent.run_tool(db_path, "alice", session_id, "document", "create", {title = "no approval", content = "x"}))

-- A row claimed by another request: its token isn't this one.
id = pending("create", "someone else")
agent.claim_pending_action(db_path, id, "running")
report("not our claim", agent.run_tool(db_path, "alice", session_id, "document", "create", nil, nil, {id = id, token = "not-ours"}))

-- Our claim, but for a different tool than the one being run.
id = pending("update", "other tool")
claimed, token = agent.claim_pending_action(db_path, id, "running")
report("other tool", agent.run_tool(db_path, "alice", session_id, "document", "create", nil, nil, {id = id, token = token}))

-- Our claim, for this call: it runs, with the row's arguments, not the
-- caller's.
id = pending("create", "from the row")
claimed, token = agent.claim_pending_action(db_path, id, "running")
report("claimed", agent.run_tool(db_path, "alice", session_id, "document", "create",
    {title = "from the caller", content = "x"}, nil, {id = id, token = token}))

-- A read-only tool needs no approval.
report("read-only", agent.run_tool(db_path, "alice", session_id, "document", "search", {query = "row"}))
