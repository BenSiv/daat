-- Scores stored chat history with the scorecard's conversation-level
-- checks (doc/agent-eval.md, "The same scores on real use").
--
--   <rows as JSON lines> | luam score_chats.lua [--exclude login,login]
--
-- Each input line is one agent_message row joined to its session:
--   {"session_id": "...", "login": "...", "id": 1, "role": "user",
--    "content": "...", "created_at": "2026-10-01 09:00:00"}
-- Rows are read from stdin so a deployment's chats never have to be
-- written to a file; only totals are printed, never message content.
--
-- Every user message starts an exchange: the rows up to the next user
-- message are the agent's work on it. Each exchange is scored with
-- finished, no_failed_lookup, cites and shows_method (the last only for
-- answers that state a decimal value).

json = require("dkjson")
checks = dofile(string.match(arg[0], "^(.*)/[^/]*$") .. "/checks.lua")

excluded = {}
i = 1
while arg[i] != nil do
    if arg[i] == "--exclude" and arg[i + 1] != nil then
        for login in string.gmatch(arg[i + 1], "[^,]+") do
            excluded[login] = true
        end
        i = i + 2
    else
        i = i + 1
    end
end

sessions = {}
session_order = {}
for line in io.lines() do
    if line != "" then
        row = json.decode(line)
        if row != nil and excluded[tostring(row.login)] != true then
            if sessions[row.session_id] == nil then
                sessions[row.session_id] = {login = row.login, rows = {}}
                table.insert(session_order, row.session_id)
            end
            table.insert(sessions[row.session_id].rows, row)
        end
    end
end

totals = {
    sessions = 0, users = 0, exchanges = 0, finished = 0, no_reply = 0,
    with_failed_lookup = 0, failed_lookups = 0, cited = 0,
    numeric = 0, numeric_with_method = 0, tool_calls = 0,
}
first_at = nil
last_at = nil
users = {}

for _, sid in ipairs(session_order) do
    session = sessions[sid]
    table.sort(session.rows, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
    totals.sessions = totals.sessions + 1
    users[tostring(session.login)] = true
    exchange = nil
    exchanges = {}
    for _, row in ipairs(session.rows) do
        if row.role == "user" then
            exchange = {row}
            table.insert(exchanges, exchange)
        elseif exchange != nil then
            table.insert(exchange, row)
        end
        if row.created_at != nil then
            if first_at == nil or row.created_at < first_at then
                first_at = row.created_at
            end
            if last_at == nil or row.created_at > last_at then
                last_at = row.created_at
            end
        end
    end
    for _, rows in ipairs(exchanges) do
        conv = checks.conversation(rows, {})
        totals.exchanges = totals.exchanges + 1
        for _, msg in ipairs(conv.messages) do
            totals.tool_calls = totals.tool_calls + #msg.tool_calls
        end
        if conv.final_text == nil then
            totals.no_reply = totals.no_reply + 1
        end
        if checks.finished(conv, {}, {}).pass == true then
            totals.finished = totals.finished + 1
        end
        lookup = checks.no_failed_lookup(conv, {}, {})
        if lookup.pass != true then
            totals.with_failed_lookup = totals.with_failed_lookup + 1
            totals.failed_lookups = totals.failed_lookups + lookup.count
        end
        -- Any link to one of the deployment's own record pages.
        if conv.final_text != nil and string.find(conv.final_text, "entity_id=%d") != nil then
            totals.cited = totals.cited + 1
        end
        -- A decimal value marks a calculated answer; dates, ids and lab
        -- numbers ("EXP-027") don't.
        if conv.final_text != nil and string.find(conv.final_text, "%d%.%d") != nil then
            totals.numeric = totals.numeric + 1
            if checks.shows_method(conv, {}, {}).pass == true then
                totals.numeric_with_method = totals.numeric_with_method + 1
            end
        end
    end
end
for _, _ in pairs(users) do
    totals.users = totals.users + 1
end

function pct(n, d)
    if d == 0 then
        return "-"
    end
    return string.format("%.0f%% (%d/%d)", 100 * n / d, n, d)
end

print(string.format("Chats %s .. %s: %d sessions, %d users, %d questions, %d tool calls",
    tostring(first_at), tostring(last_at), totals.sessions, totals.users, totals.exchanges, totals.tool_calls))
print(string.format("%-34s %s", "Finished", pct(totals.finished, totals.exchanges)))
print(string.format("%-34s %s", "No reply at all", pct(totals.no_reply, totals.exchanges)))
print(string.format("%-34s %s", "Questions with a failed lookup", pct(totals.with_failed_lookup, totals.exchanges)))
if totals.exchanges > 0 then
    print(string.format("%-34s %.2f", "Failed lookups per question", totals.failed_lookups / totals.exchanges))
end
print(string.format("%-34s %s", "Answers linking a record", pct(totals.cited, totals.exchanges - totals.no_reply)))
print(string.format("%-34s %s", "Decimal answers showing method", pct(totals.numeric_with_method, totals.numeric)))
