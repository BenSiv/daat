-- Scenario checks for the agent scorecard (doc/agent-eval.md,
-- "Scenarios"). Every check is a rule, never a model's judgement.
--
-- Checks read a *conversation*: a session's stored agent_message rows
-- plus its agent_pending_action rows, decoded by checks.conversation.
-- That keeps the conversation-level checks (cites, no_failed_lookup,
-- finished, shows_method, says_unknown) usable on any stored chat, not
-- only on a scenario run. `ctx` carries what only a run knows: the run's
-- final status, and query/is_destructive callbacks into the deployment.
--
-- Each check returns {pass = true|false, detail = "..."}.

json = require("dkjson")

checks = {}

-- Tool errors that mean the agent guessed where data lives, or used the
-- other database's SQL, instead of looking it up first.
FAILED_LOOKUP_PATTERNS = {
    "no such column", "no such table", "unknown column", "unknown table",
    "doesn't exist", "does not exist", "unknown entity type",
    "not a registered entity type", "sqlite_master", "information_schema",
    "no such function", "unknown field",
}

-- A reply that hands the work back instead of finishing it.
STALL_PATTERNS = {
    "should i continue", "shall i continue", "want me to continue",
    "would you like me to continue", "should i proceed", "shall i proceed",
    "would you like me to proceed", "want me to proceed",
}

UNKNOWN_PATTERNS = {
    "not recorded", "isn't recorded", "is not recorded", "not in the data",
    "no record", "no information", "not available", "couldn't find",
    "could not find", "can't find", "cannot find", "don't have", "do not have",
    "doesn't say", "does not say", "not mentioned", "isn't mentioned",
    "no mention", "not contain", "doesn't contain", "don't contain",
    "not include", "doesn't include", "not specified", "isn't specified",
    "not listed", "isn't listed", "not record", "doesn't record", "don't record",
    "no data", "unknown",
}

MONTHS = {"january", "february", "march", "april", "may", "june", "july",
    "august", "september", "october", "november", "december"}

-- The ways a reply may write an ISO date: 2026-04-25, April 25, 2026,
-- Apr 25 2026, 25 April 2026 (lowercased, to match lowered text).
function date_forms(iso)
    y, m, d = string.match(iso, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if y == nil then
        return {string.lower(iso)}
    end
    month = MONTHS[tonumber(m)]
    short = string.sub(month, 1, 3)
    day = tostring(tonumber(d))
    return {
        iso,
        month .. " " .. day .. ", " .. y, month .. " " .. day .. " " .. y,
        short .. " " .. day .. ", " .. y, short .. " " .. day .. " " .. y,
        day .. " " .. month .. " " .. y, day .. " " .. short .. " " .. y,
    }
end

METHOD_PATTERNS = {"select ", "```", "calculated", "computed", "formula", "ln(", "log(", "slope", "regression",
    "log-linear", "least squares", "least-squares", "fitted", "fit over"}

function contains_any(text, patterns)
    lowered = string.lower(text)
    for _, pattern in ipairs(patterns) do
        if string.find(lowered, pattern, 1, true) != nil then
            return pattern
        end
    end
    return nil
end

function decode_or_text(content)
    decoded, _, _ = json.decode(content)
    if type(decoded) == "table" then
        return decoded
    end
    return nil
end

-- message_rows: {id, role, content} in id order. pending_rows: rows of
-- agent_pending_action for the same session.
function checks.conversation(message_rows, pending_rows)
    conv = {messages = {}, pending = {}, final_text = nil}
    if pending_rows != nil then
        conv.pending = pending_rows
    end
    last_user = 0
    for i, row in ipairs(message_rows) do
        msg = {role = row.role, text = "", tool_calls = {}}
        if row.role == "assistant" then
            decoded = decode_or_text(row.content)
            if decoded != nil and decoded.blocks != nil then
                parts = {}
                for _, block in ipairs(decoded.blocks) do
                    if block.type == "text" and block.text != nil then
                        table.insert(parts, block.text)
                    elseif block.type == "toolCall" then
                        table.insert(msg.tool_calls, {id = block.id, name = block.name, arguments = block.arguments})
                    end
                end
                msg.text = table.concat(parts, "\n")
            else
                msg.text = tostring(row.content)
            end
        elseif row.role == "tool_result" then
            decoded = decode_or_text(row.content)
            if decoded != nil then
                msg.tool_call_id = decoded.tool_call_id
                msg.tool_name = decoded.tool_name
                msg.text = tostring(decoded.text)
                msg.is_error = decoded.is_error == true
            end
        else
            msg.text = tostring(row.content)
        end
        table.insert(conv.messages, msg)
        if row.role == "user" then
            last_user = i
        end
    end
    -- The final answer: the last assistant reply with text and no tool
    -- call, after the last user message.
    for i = #conv.messages, last_user + 1, -1 do
        msg = conv.messages[i]
        if msg.role == "assistant" and #msg.tool_calls == 0 and msg.text != "" then
            conv.final_text = msg.text
            break
        end
    end
    return conv
end

function final_or_empty(conv)
    if conv.final_text == nil then
        return ""
    end
    return conv.final_text
end

function numbers_in(text)
    found = {}
    for raw in string.gmatch(text, "%-?%d+%.?%d*") do
        n = tonumber(raw)
        if n != nil then
            table.insert(found, n)
        end
    end
    return found
end

-- spec.expected: text that must appear (case-insensitive); spec.all: a
-- list of texts that must all appear; spec.date: an ISO date, in any
-- common spelling; spec.number (+ spec.tolerance, relative, default
-- 0.05): a number that must appear within tolerance.
function checks.answer(conv, spec, ctx)
    text = final_or_empty(conv)
    -- Markdown emphasis is presentation, not content: "**April 25, 2026**".
    lowered = string.lower(string.gsub(text, "[%*_]", ""))
    if text == "" then
        return {pass = false, detail = "no final answer"}
    end
    if spec.date != nil then
        found = false
        for _, form in ipairs(date_forms(spec.date)) do
            if string.find(lowered, form, 1, true) != nil then
                found = true
            end
        end
        if found == false then
            return {pass = false, detail = "missing date " .. spec.date}
        end
    end
    if spec.expected != nil and string.find(lowered, string.lower(tostring(spec.expected)), 1, true) == nil then
        return {pass = false, detail = "missing '" .. tostring(spec.expected) .. "'"}
    end
    -- spec.any: at least one of these texts must appear (the same answer
    -- in different words: "2 hours", "two hours").
    if spec.any != nil then
        hit = false
        for _, item in ipairs(spec.any) do
            if string.find(lowered, string.lower(item), 1, true) != nil then
                hit = true
            end
        end
        if hit == false then
            return {pass = false, detail = "none of " .. table.concat(spec.any, " / ")}
        end
    end
    if spec.all != nil then
        missing = {}
        for _, item in ipairs(spec.all) do
            if string.find(lowered, string.lower(item), 1, true) == nil then
                table.insert(missing, item)
            end
        end
        if #missing > 0 then
            return {pass = false, detail = "missing " .. table.concat(missing, ", ")}
        end
    end
    if spec.number != nil then
        tolerance = spec.tolerance
        if tolerance == nil then
            tolerance = 0.05
        end
        for _, n in ipairs(numbers_in(text)) do
            if math.abs(n - spec.number) <= math.abs(spec.number) * tolerance then
                return {pass = true, detail = "found " .. tostring(n)}
            end
        end
        return {pass = false, detail = "no number within " .. tostring(tolerance * 100) .. "% of " .. tostring(spec.number)}
    end
    -- spec.numbers: every one must appear, within tolerance.
    if spec.numbers != nil then
        tolerance = spec.tolerance
        if tolerance == nil then
            tolerance = 0.05
        end
        found_numbers = numbers_in(text)
        missing = {}
        for _, expected in ipairs(spec.numbers) do
            hit = false
            for _, n in ipairs(found_numbers) do
                if math.abs(n - expected) <= math.abs(expected) * tolerance then
                    hit = true
                end
            end
            if hit == false then
                table.insert(missing, tostring(expected))
            end
        end
        if #missing > 0 then
            return {pass = false, detail = "missing number(s) " .. table.concat(missing, ", ")}
        end
    end
    return {pass = true, detail = ""}
end

-- spec.ids: record ids, any of which counts. A link is the record's own
-- page (/document?entity_id=N or /detail?type=T&entity_id=N).
function checks.cites(conv, spec, ctx)
    text = final_or_empty(conv)
    for _, id in ipairs(spec.ids) do
        if string.find(text, "entity_id=" .. tostring(id) .. "%f[^%d]") != nil then
            return {pass = true, detail = "links " .. tostring(id)}
        end
    end
    return {pass = false, detail = "no link to the record that holds the answer"}
end

-- Every destructive tool result must belong to a pending action that a
-- person approved. ctx.is_destructive(tool_name) decides what counts.
function checks.approval(conv, spec, ctx)
    approved = {}
    for _, p in ipairs(conv.pending) do
        if p.status == "approved" and p.tool_call_id != nil then
            approved[p.tool_call_id] = true
        end
    end
    writes = 0
    for _, msg in ipairs(conv.messages) do
        if msg.role == "tool_result" and msg.tool_name != nil and ctx.is_destructive(msg.tool_name) == true
                and string.find(msg.text, "User denied", 1, true) == nil
                and string.find(msg.text, "ERROR: skipped", 1, true) == nil then
            writes = writes + 1
            if approved[msg.tool_call_id] != true then
                return {pass = false, detail = msg.tool_name .. " ran without an approved pending action"}
            end
        end
    end
    if spec.expect_write == true and writes == 0 then
        return {pass = false, detail = "no write was proposed"}
    end
    return {pass = true, detail = tostring(writes) .. " approved write(s)"}
end

function checks.no_failed_lookup(conv, spec, ctx)
    failures = {}
    for _, msg in ipairs(conv.messages) do
        if msg.role == "tool_result" and msg.is_error == true then
            hit = contains_any(msg.text, FAILED_LOOKUP_PATTERNS)
            if hit != nil then
                table.insert(failures, tostring(msg.tool_name) .. ": " .. hit)
            end
        end
    end
    if #failures > 0 then
        return {pass = false, detail = table.concat(failures, "; "), count = #failures}
    end
    return {pass = true, detail = "", count = 0}
end

-- Finished: the turn ended in an answer, not a turn limit, error, or a
-- reply that asks whether to keep going. ctx.status is the run's final
-- status when known.
function checks.finished(conv, spec, ctx)
    if ctx != nil and ctx.status != nil and ctx.status != "done" then
        return {pass = false, detail = "ended with status " .. tostring(ctx.status)}
    end
    text = final_or_empty(conv)
    if text == "" then
        return {pass = false, detail = "no final answer"}
    end
    stall = contains_any(text, STALL_PATTERNS)
    if stall != nil then
        return {pass = false, detail = "stalled: '" .. stall .. "'"}
    end
    return {pass = true, detail = ""}
end

function checks.says_unknown(conv, spec, ctx)
    hit = contains_any(final_or_empty(conv), UNKNOWN_PATTERNS)
    if hit == nil then
        return {pass = false, detail = "does not say the data lacks the answer"}
    end
    return {pass = true, detail = "'" .. hit .. "'"}
end

function checks.shows_method(conv, spec, ctx)
    hit = contains_any(final_or_empty(conv), METHOD_PATTERNS)
    if hit == nil then
        return {pass = false, detail = "no query, formula or steps shown"}
    end
    return {pass = true, detail = "'" .. hit .. "'"}
end

-- Tool plumbing ("calc.evaluate -> 4.31") belongs in tool calls, not
-- in what the user reads.
TOOL_GROUPS = {"document", "entity", "plot", "calc", "stats", "template", "knowledge",
    "view", "research", "clarify", "background", "internet_search"}

function checks.no_tool_names(conv, spec, ctx)
    text = final_or_empty(conv)
    for _, group in ipairs(TOOL_GROUPS) do
        name = string.match(text, "%f[%w_]" .. group .. "%.[%a_]+")
        if name != nil then
            return {pass = false, detail = "mentions tool " .. name}
        end
    end
    return {pass = true, detail = ""}
end

-- Formulas typeset for LaTeX: the chat renders Markdown with no math
-- support, so the user reads the raw source ("$\frac{\ln(2)}{0.25}$").
LATEX_PATTERNS = {"\\frac", "\\text{", "\\times", "\\approx", "\\ln", "\\cdot", "\\sqrt", "\\log", "$$"}

function checks.no_latex(conv, spec, ctx)
    text = final_or_empty(conv)
    for _, pattern in ipairs(LATEX_PATTERNS) do
        if string.find(text, pattern, 1, true) != nil then
            return {pass = false, detail = "LaTeX in the reply: '" .. pattern .. "'"}
        end
    end
    return {pass = true, detail = ""}
end

-- Markdown links reduced to their labels: a link's URL carries the
-- record's id by design (cites), so ids are only looked for in what the
-- user reads.
function link_urls_removed(text)
    return (string.gsub(text, "%]%([^%)]*%)", "]"))
end

-- Markdown links removed entirely, label and all.
function links_removed(text)
    return (string.gsub(text, "%[[^%]]*%]%([^%)]*%)", ""))
end

-- Words a reply puts before a number when it names a record by its
-- database id ("sample 41", "document #263"). Lab numbers are zero-
-- padded (EXP-018), so "experiment 018" is a label, not an id.
ID_WORDS = {"sample", "samples", "experiment", "experiments", "document", "documents", "measurement",
    "measurements", "record", "records", "row", "entity", "id"}

-- The reply names records by their labels, never by internal id.
-- spec.ids (optional): ids of the records the question is about, none
-- of which may appear as a bare number.
function checks.labels_not_ids(conv, spec, ctx)
    text = string.lower(link_urls_removed(final_or_empty(conv)))
    for _, word in ipairs(ID_WORDS) do
        for number in string.gmatch(text, "%f[%a]" .. word .. " ?#? ?(%d+)%f[^%d%.%-]") do
            if string.sub(number, 1, 1) != "0" then
                return {pass = false, detail = "names a record by id: '" .. word .. " " .. number .. "'"}
            end
        end
    end
    if spec.ids != nil then
        for _, id in ipairs(spec.ids) do
            if string.find(text, "%f[%w%.%-#]#?" .. tostring(id) .. "%f[^%w%.]") != nil then
                return {pass = false, detail = "shows internal id " .. tostring(id)}
            end
        end
    end
    return {pass = true, detail = ""}
end

-- The reply names the record by its own label in its own words, not
-- only inside a link to a document about it. Found live: "The doubling
-- time of [Notes: Growth of ... (EXP-018)](...)" names the experiment
-- by its notes document's title. spec.label: e.g. the lab number.
function checks.names_record(conv, spec, ctx)
    text = links_removed(final_or_empty(conv))
    if string.find(string.lower(text), string.lower(spec.label), 1, true) == nil then
        return {pass = false, detail = spec.label .. " appears only inside a link, or not at all"}
    end
    return {pass = true, detail = ""}
end

-- Ids of the documents this conversation created or updated, from the
-- write tools' own results ("Created document #310 (...)").
function written_documents(conv)
    ids = {}
    seen = {}
    for _, msg in ipairs(conv.messages) do
        if msg.role == "tool_result" and msg.is_error != true then
            for id in string.gmatch(msg.text, "[Cc]reated document #(%d+)") do
                if seen[id] == nil then
                    seen[id] = true
                    table.insert(ids, tonumber(id))
                end
            end
            for id in string.gmatch(msg.text, "[Uu]pdated document #(%d+)") do
                if seen[id] == nil then
                    seen[id] = true
                    table.insert(ids, tonumber(id))
                end
            end
        end
    end
    return ids
end

function id_list(ids)
    parts = {}
    for _, id in ipairs(ids) do
        table.insert(parts, tostring(tonumber(id)))
    end
    return table.concat(parts, ",")
end

-- The documents this conversation wrote (or spec.from, one document)
-- link every document in spec.ids, as stored links that resolve: a
-- [[title]] the save turned into a connection, not a Markdown link to a
-- page, which connects nothing.
function checks.links_documents(conv, spec, ctx)
    from = written_documents(conv)
    if spec.from != nil then
        from = {spec.from}
    end
    if #from == 0 then
        return {pass = false, detail = "no document was written"}
    end
    rows = ctx.query(string.format(
        "SELECT DISTINCT to_document_id AS id FROM document_link WHERE from_document_id IN (%s) " ..
        "AND to_document_id IS NOT NULL AND (archived_at IS NULL OR archived_at = '');", id_list(from)))
    if rows == nil then
        rows = {}
    end
    linked = {}
    for _, row in ipairs(rows) do
        linked[tonumber(row.id)] = true
    end
    missing = {}
    for _, id in ipairs(spec.ids) do
        if linked[id] != true then
            table.insert(missing, tostring(id))
        end
    end
    if #missing > 0 then
        return {pass = false, detail = "no link to document(s) " .. table.concat(missing, ", ")}
    end
    return {pass = true, detail = tostring(#spec.ids) .. " documents linked"}
end

-- The documents this conversation wrote hold no link to a title that
-- doesn't exist ([[wiki-style]], [[title]]).
function checks.no_dangling_links(conv, spec, ctx)
    from = written_documents(conv)
    if #from == 0 then
        return {pass = true, detail = "no document written"}
    end
    rows = ctx.query(string.format(
        "SELECT link_text FROM document_link WHERE from_document_id IN (%s) AND to_document_id IS NULL " ..
        "AND (archived_at IS NULL OR archived_at = '');", id_list(from)))
    if rows != nil and rows[1] != nil then
        return {pass = false, detail = "links to nothing: [[" .. tostring(rows[1].link_text) .. "]]"}
    end
    return {pass = true, detail = ""}
end

-- No document this conversation wrote is filed under one of spec.ids.
-- Found live: summaries across experiments filed as sub-documents of
-- one experiment's notes.
function checks.not_filed_under(conv, spec, ctx)
    from = written_documents(conv)
    if #from == 0 then
        return {pass = false, detail = "no document was written"}
    end
    forbidden = {}
    for _, id in ipairs(spec.ids) do
        forbidden[id] = true
    end
    rows = ctx.query(string.format("SELECT id, parent_id FROM document WHERE id IN (%s);", id_list(from)))
    if rows == nil then
        rows = {}
    end
    for _, row in ipairs(rows) do
        if tonumber(row.parent_id) != nil and forbidden[tonumber(row.parent_id)] == true then
            return {pass = false, detail = "document " .. tostring(row.id) .. " filed under " .. tostring(row.parent_id)}
        end
    end
    return {pass = true, detail = ""}
end

-- An updated document still holds what it had: content updates replace
-- the whole field, so an edit that only meant to add a line can drop
-- the rest. spec.id, spec.texts.
function checks.keeps_content(conv, spec, ctx)
    rows = ctx.query(string.format("SELECT content FROM document WHERE id = %d;", spec.id))
    if rows == nil or rows[1] == nil then
        return {pass = false, detail = "document not found"}
    end
    content = tostring(rows[1].content)
    for _, text in ipairs(spec.texts) do
        if string.find(content, text, 1, true) == nil then
            return {pass = false, detail = "lost '" .. text .. "'"}
        end
    end
    return {pass = true, detail = ""}
end

-- A field of a row ends up with an expected value. Needs ctx.query, so
-- it only runs inside a scenario, not on a stored chat.
function checks.state(conv, spec, ctx)
    rows = ctx.query(string.format("SELECT %s AS v FROM %s WHERE id = %d;", spec.field, spec.type, spec.id))
    if rows == nil or rows[1] == nil then
        return {pass = false, detail = "row not found"}
    end
    actual = tostring(rows[1].v)
    if actual != tostring(spec.value) then
        return {pass = false, detail = spec.field .. " is '" .. actual .. "', expected '" .. tostring(spec.value) .. "'"}
    end
    return {pass = true, detail = ""}
end

function checks.run(name, conv, spec, ctx)
    fn = checks[name]
    if fn == nil or name == "run" or name == "conversation" then
        return {pass = false, detail = "unknown check " .. tostring(name)}
    end
    return fn(conv, spec, ctx)
end

return checks
