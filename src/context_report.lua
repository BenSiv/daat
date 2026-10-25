-- `daat agent context-report [--since YYYY-MM-DD]`: how big the agent's
-- context gets and what fills it, from what's already stored
-- (agent_model_call's per-call token counts, agent_message's history).
-- Read-only, so it can be run against production. It is the baseline
-- every step of doc/context-management-plan.md is measured against;
-- the 2026-10-23 numbers in doc/context-management-research.md are
-- this report's first run.
--
-- The SQL is deliberately plain (no JSON functions, no window
-- functions) so it runs the same on SQLite and MySQL; grouping and
-- percentiles are done here in Lua, which is fine at this volume
-- (thousands of rows).

db = require("database")
json = require("dkjson")

context_report = {}

-- Arguments compared as canonical JSON (keys sorted), since a Lua
-- table's own key order isn't stable -- the same function the agent's
-- own repeat check uses (agent.canonical_json).
canonical_json = require("agent").canonical_json

-- The tool calls in one stored assistant message: {{name, args_key}, ...}.
function assistant_tool_calls(content)
    calls = {}
    decoded, _, _ = json.decode(content)
    if type(decoded) != "table" or type(decoded.blocks) != "table" then
        return calls
    end
    for _, block in ipairs(decoded.blocks) do
        if type(block) == "table" and block.type == "toolCall" then
            args = block.arguments
            if args == nil then
                args = {}
            end
            table.insert(calls, {name = tostring(block.name), args_key = canonical_json(args)})
        end
    end
    return calls
end

-- context_report.count_exact_repeats(rows) -> {tool = {calls = N, repeats = M}}, total_repeats
-- `rows` are agent_message rows ({session_id, role, content}); only
-- assistant rows are read. A repeat is a call whose (session, tool,
-- arguments) already appeared earlier.
function context_report.count_exact_repeats(rows)
    seen = {}
    by_tool = {}
    total = 0
    for _, row in ipairs(rows) do
        if row.role == "assistant" then
            for _, call in ipairs(assistant_tool_calls(row.content)) do
                key = tostring(row.session_id) .. "\1" .. call.name .. "\1" .. call.args_key
                stats = by_tool[call.name]
                if stats == nil then
                    stats = {calls = 0, repeats = 0}
                    by_tool[call.name] = stats
                end
                stats.calls = stats.calls + 1
                if seen[key] == true then
                    stats.repeats = stats.repeats + 1
                    total = total + 1
                end
                seen[key] = true
            end
        end
    end
    return by_tool, total
end

function since_clause(column, since)
    if since == nil then
        return ""
    end
    return " AND " .. column .. " >= " .. db.quote(since)
end

function rows_or_empty(rows)
    if rows == nil then
        return {}
    end
    return rows
end

function round(x)
    if x == nil then
        return "-"
    end
    return tostring(math.floor(x + 0.5))
end

-- Admin accounts are reported apart from everyone else: on a typical
-- deployment they're the people testing and configuring the agent, and
-- their sessions look nothing like day-to-day use.
function account_classes(db_path)
    classes = {}
    for _, row in ipairs(rows_or_empty(db.query(db_path, "SELECT login, cap FROM auth_user;"))) do
        cap = row.cap
        if cap == nil then
            cap = ""
        end
        if string.find(cap, "a", 1, true) != nil then
            classes[row.login] = "admin accounts"
        else
            classes[row.login] = "other accounts"
        end
    end
    return classes
end

function new_stats()
    return {n = 0, sum = 0, max = 0, over20k = 0, over32k = 0, with_usage = 0}
end

function add_tokens(stats, tokens)
    stats.n = stats.n + 1
    if tokens != nil then
        stats.with_usage = stats.with_usage + 1
        stats.sum = stats.sum + tokens
        if tokens > stats.max then
            stats.max = tokens
        end
        if tokens > 20000 then
            stats.over20k = stats.over20k + 1
        end
        if tokens > 32000 then
            stats.over32k = stats.over32k + 1
        end
    end
end

function mean(stats)
    if stats.with_usage == 0 then
        return nil
    end
    return stats.sum / stats.with_usage
end

function sorted_keys(t)
    keys = {}
    for k, _ in pairs(t) do
        table.insert(keys, k)
    end
    table.sort(keys)
    return keys
end

-- Section 1 and 2: calls by kind and account class, and per-turn
-- totals for chat. Rows from before step_kind existed are labelled
-- "unlabelled" -- on those, chat steps can still be grouped into turns
-- by message_id, which is what the per-turn section does.
function call_sections(db_path, since, out)
    classes = account_classes(db_path)
    length_fn = "LENGTH"
    if db.is_mariadb(db_path) then
        length_fn = "CHAR_LENGTH"
    end
    -- The model-call log is agent_model_call. A store not yet migrated
    -- (e.g. production read before a deploy) still has it as
    -- knowledge_context, without a kind column on older layouts; those
    -- rows report as "unlabelled".
    source = "agent_model_call"
    kind_expr = "k.kind AS step_kind"
    if not db.table_exists(db_path, "agent_model_call") then
        source = "knowledge_context"
        kind_expr = "NULL AS step_kind"
        for _, name in ipairs(db.get_columns(db_path, "knowledge_context")) do
            if name == "step_kind" then
                kind_expr = "k.step_kind"
            end
        end
    end
    rows = rows_or_empty(db.query(db_path,
        "SELECT k.session_id, k.message_id, " .. kind_expr .. ", k.prompt_tokens, " .. length_fn .. "(k.prompt) AS prompt_chars, s.login " ..
        "FROM " .. source .. " k LEFT JOIN agent_session s ON s.id = k.session_id WHERE 1 = 1" ..
        since_clause("k.created_at", since) .. " ORDER BY k.id;"))

    groups = {}
    for _, row in ipairs(rows) do
        kind = row.step_kind
        if kind == nil or kind == "" then
            kind = "unlabelled"
        end
        class = classes[row.login]
        if class == nil then
            class = "other accounts"
        end
        key = kind .. " / " .. class
        if groups[key] == nil then
            groups[key] = new_stats()
        end
        add_tokens(groups[key], tonumber(row.prompt_tokens))
    end

    table.insert(out, "## Model calls")
    table.insert(out, "")
    table.insert(out, "kind / accounts\tcalls\tavg prompt tokens\tmax\tover 20k\tover 32k")
    for _, key in ipairs(sorted_keys(groups)) do
        g = groups[key]
        table.insert(out, string.format("%s\t%d\t%s\t%d\t%d\t%d", key, g.n, round(mean(g)), g.max, g.over20k, g.over32k))
    end
    table.insert(out, "")

    -- Turns: chat calls (labelled "chat", or unlabelled ones tied to a
    -- message) between one user message and the next.
    user_rows = rows_or_empty(db.query(db_path,
        "SELECT id, session_id FROM agent_message WHERE role = 'user'" .. since_clause("created_at", since) .. " ORDER BY id;"))
    users_by_session = {}
    for _, u in ipairs(user_rows) do
        list = users_by_session[u.session_id]
        if list == nil then
            list = {}
            users_by_session[u.session_id] = list
        end
        table.insert(list, tonumber(u.id))
    end
    turns = {}
    for _, row in ipairs(rows) do
        kind = row.step_kind
        message_id = tonumber(row.message_id)
        is_chat = kind == "chat" or ((kind == nil or kind == "") and message_id != nil)
        if is_chat and message_id != nil then
            turn_user = nil
            for _, uid in ipairs(rows_or_empty(users_by_session[row.session_id])) do
                if uid < message_id then
                    turn_user = uid
                end
            end
            if turn_user != nil then
                key = tostring(row.session_id) .. ":" .. tostring(turn_user)
                t = turns[key]
                if t == nil then
                    class = classes[row.login]
                    if class == nil then
                        class = "other accounts"
                    end
                    t = {class = class, steps = 0, peak = 0, total = 0}
                    turns[key] = t
                end
                t.steps = t.steps + 1
                tokens = tonumber(row.prompt_tokens)
                if tokens != nil then
                    t.total = t.total + tokens
                    if tokens > t.peak then
                        t.peak = tokens
                    end
                end
            end
        end
    end
    by_class = {}
    for _, t in pairs(turns) do
        c = by_class[t.class]
        if c == nil then
            c = {turns = 0, steps = 0, max_steps = 0, peak_sum = 0, peak_max = 0, total_sum = 0}
            by_class[t.class] = c
        end
        c.turns = c.turns + 1
        c.steps = c.steps + t.steps
        c.peak_sum = c.peak_sum + t.peak
        c.total_sum = c.total_sum + t.total
        if t.steps > c.max_steps then
            c.max_steps = t.steps
        end
        if t.peak > c.peak_max then
            c.peak_max = t.peak
        end
    end
    table.insert(out, "## Chat turns")
    table.insert(out, "")
    table.insert(out, "accounts\tturns\tavg steps\tmax steps\tavg peak prompt tokens\tmax peak\tavg prompt tokens per turn (all steps)")
    for _, class in ipairs(sorted_keys(by_class)) do
        c = by_class[class]
        table.insert(out, string.format("%s\t%d\t%.1f\t%d\t%s\t%d\t%s", class, c.turns, c.steps / c.turns, c.max_steps,
            round(c.peak_sum / c.turns), c.peak_max, round(c.total_sum / c.turns)))
    end
    table.insert(out, "")

    -- Fixed overhead and characters per token: a least-squares line
    -- through (stored prompt characters, real prompt tokens) on chat
    -- calls. The stored prompt is the message history only, so the
    -- intercept is what the system prompt and tool definitions cost.
    n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
    for _, row in ipairs(rows) do
        x = tonumber(row.prompt_chars)
        y = tonumber(row.prompt_tokens)
        kind = row.step_kind
        if x != nil and y != nil and (kind == "chat" or kind == nil or kind == "") then
            n = n + 1
            sx = sx + x
            sy = sy + y
            sxx = sxx + x * x
            sxy = sxy + x * y
        end
    end
    table.insert(out, "## Token estimate")
    table.insert(out, "")
    denominator = n * sxx - sx * sx
    if n >= 2 and denominator != 0 then
        slope = (n * sxy - sx * sy) / denominator
        intercept = (sy - slope * sx) / n
        if slope > 0 then
            table.insert(out, string.format("Over %d chat calls: prompt tokens = %s fixed + 1 token per %.1f characters of history.", n, round(intercept), 1 / slope))
        else
            table.insert(out, "Not enough spread in the data to fit a line.")
        end
    else
        table.insert(out, "Not enough calls with token counts.")
    end
    table.insert(out, "")
end

-- Section 3 and 4: what fills the history, and exact re-fetches.
function history_sections(db_path, since, out)
    rows = rows_or_empty(db.query(db_path,
        "SELECT session_id, role, content FROM agent_message WHERE 1 = 1" .. since_clause("created_at", since) .. " ORDER BY id;"))

    total_chars = 0
    tools = {}
    compactions = {}
    for _, row in ipairs(rows) do
        size = string.len(tostring(row.content))
        total_chars = total_chars + size
        if row.role == "tool_result" then
            name = "(unknown)"
            decoded, _, _ = json.decode(row.content)
            if type(decoded) == "table" and decoded.tool_name != nil then
                name = tostring(decoded.tool_name)
            end
            t = tools[name]
            if t == nil then
                t = {n = 0, sum = 0, max = 0, over8k = 0, over24k = 0}
                tools[name] = t
            end
            t.n = t.n + 1
            t.sum = t.sum + size
            if size > t.max then
                t.max = size
            end
            if size > 8000 then
                t.over8k = t.over8k + 1
            end
            if size > 24000 then
                t.over24k = t.over24k + 1
            end
        elseif row.role == "compaction_summary" then
            current = compactions[row.session_id]
            if current == nil then
                current = 0
            end
            compactions[row.session_id] = current + 1
        end
    end

    tool_total = 0
    names = {}
    for name, t in pairs(tools) do
        tool_total = tool_total + t.sum
        table.insert(names, name)
    end
    table.sort(names, function(a, b) return tools[a].sum > tools[b].sum end)
    table.insert(out, "## Tool results")
    table.insert(out, "")
    if total_chars > 0 then
        table.insert(out, string.format("Tool results are %d%% of stored history (%d of %d characters).",
            math.floor(100 * tool_total / total_chars + 0.5), tool_total, total_chars))
        table.insert(out, "")
    end
    table.insert(out, "tool\tresults\tavg chars\tmax chars\tover 8k\tover 24k")
    for _, name in ipairs(names) do
        t = tools[name]
        table.insert(out, string.format("%s\t%d\t%s\t%d\t%d\t%d", name, t.n, round(t.sum / t.n), t.max, t.over8k, t.over24k))
    end
    table.insert(out, "")

    by_tool, total_repeats = context_report.count_exact_repeats(rows)
    calls_total = 0
    repeat_names = {}
    for name, stats in pairs(by_tool) do
        calls_total = calls_total + stats.calls
        if stats.repeats > 0 then
            table.insert(repeat_names, name)
        end
    end
    table.sort(repeat_names, function(a, b) return by_tool[a].repeats > by_tool[b].repeats end)
    table.insert(out, "## Exact repeat calls (same session, tool and arguments)")
    table.insert(out, "")
    table.insert(out, string.format("%d of %d tool calls repeat an earlier one.", total_repeats, calls_total))
    table.insert(out, "")
    table.insert(out, "tool\tcalls\trepeats")
    for _, name in ipairs(repeat_names) do
        table.insert(out, string.format("%s\t%d\t%d", name, by_tool[name].calls, by_tool[name].repeats))
    end
    table.insert(out, "")

    compacted, twice, most = 0, 0, 0
    for _, count in pairs(compactions) do
        compacted = compacted + 1
        if count > 1 then
            twice = twice + 1
        end
        if count > most then
            most = count
        end
    end
    table.insert(out, "## Compaction")
    table.insert(out, "")
    table.insert(out, string.format("%d sessions compacted, %d more than once, at most %d times in one session.", compacted, twice, most))
    table.insert(out, "")
end

-- context_report.build(db_path, since) -> report text
function context_report.build(db_path, since)
    out = {"# Agent context report"}
    if since != nil then
        table.insert(out, "")
        table.insert(out, "Since " .. since .. ".")
    end
    table.insert(out, "")
    call_sections(db_path, since, out)
    history_sections(db_path, since, out)
    return table.concat(out, "\n")
end

return context_report
