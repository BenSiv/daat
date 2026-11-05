-- tst/integration/lua/turn_heartbeats.lua
-- When the main turn loop beats the detached turn's heartbeat (#3): once
-- before every step, and once after every tool it runs, so a slow tool
-- or a step with several tool calls can't leave the turn looking stalled
-- (agent_turn_stale_seconds). Run by agent.bats from TEST_DIR with
-- AGENT_TEST_RESPONSES set; prints the order of events on one line:
-- "beat", "model" (a call with tools), "check" (a call without: the
-- self-check), "tool:<name>".

config = require("config")
agent = require("agent")
agent_provider = require("agent_provider")

db_path = config.db_path(".")
agent.init_schema(db_path)
session_id = agent.create_session(db_path, "alice", "beats")

events = {}

real_beat = agent.turn_heartbeat
agent.turn_heartbeat = function(path, id)
    table.insert(events, "beat")
    return real_beat(path, id)
end

real_converse = agent_provider.converse
agent_provider.converse = function(model, system_prompt, messages, tools)
    if tools == nil or #tools == 0 then
        table.insert(events, "check")
    else
        table.insert(events, "model")
    end
    return real_converse(model, system_prompt, messages, tools)
end

real_run_tool = agent.run_tool
agent.run_tool = function(path, login, id, tool_name, method_name, ...)
    table.insert(events, "tool:" .. tostring(tool_name) .. "." .. tostring(method_name))
    return real_run_tool(path, login, id, tool_name, method_name, ...)
end

result = agent.run_turn(db_path, session_id, "alice", nil, nil, "what is there?")
print("status: " .. tostring(result.status))
print("events: " .. table.concat(events, " "))
