-- The chat/agent subsystem: real per-user sessions and DB-backed
-- conversation history (not brain-ex's hardcoded single 'default'
-- session -- every session belongs to a specific login, and every
-- lookup checks that ownership), context-window compaction, and (see
-- the tool-use section further down) a bounded turn loop that can act
-- on the platform's own data through a small, explicit tool registry.
--
-- Nothing here is ever deleted. Compacting history marks old messages
-- out-of-context (in_context = 0) rather than removing them -- the
-- full conversation stays in SQL, only the live prompt sent to the
-- model shrinks.

db = require("db")
agent_provider = require("agent_provider")
document = require("document")
entity = require("entity")
schema = require("schema")
knowledge = require("knowledge")
auth = require("auth")
template = require("template")
config = require("config")

agent = {}

DEFAULT_COMPACTION_THRESHOLD = 4000
MAX_TURNS = 10
DEFAULT_MODEL = "gemini-2.5-flash"

-- Same default cgi.lua's own chat routes already use (AGENT_MODEL env
-- var, not hardcoded, since a real model name is a deployment choice)
-- -- exposed here too so main.lua's CLI dispatch (task #87's `platform
-- knowledge review`) doesn't need its own copy of the fallback.
function agent.default_model()
    model = os.getenv("AGENT_MODEL")
    if model == nil or model == "" then
        model = DEFAULT_MODEL
    end
    return model
end

AGENT_SCHEMA = """
-- VARCHAR(255), not TEXT -- MariaDB/InnoDB refuses a bare TEXT column
-- as a key without an explicit length; see ledger.lua's own SCHEMA
-- comment for the full reasoning.
CREATE TABLE IF NOT EXISTS agent_session (
    id VARCHAR(255) PRIMARY KEY,
    login TEXT NOT NULL,
    title TEXT,
    created_at TEXT DEFAULT (%s),
    updated_at TEXT DEFAULT (%s)
);

CREATE TABLE IF NOT EXISTS agent_message (
    id INTEGER PRIMARY KEY %s,
    session_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    in_context INTEGER DEFAULT 1,
    created_at TEXT DEFAULT (%s)
);

-- A destructive tool call the model has proposed but not yet run --
-- see "Tool use" below for why this has to be a real, persisted state
-- rather than a blocking prompt: a single CGI request can't pause
-- mid-call waiting on a human's real-world response time.
CREATE TABLE IF NOT EXISTS agent_pending_action (
    id INTEGER PRIMARY KEY %s,
    session_id TEXT NOT NULL,
    tool TEXT NOT NULL,
    method TEXT NOT NULL,
    args_json TEXT NOT NULL,
    -- VARCHAR(32), not TEXT -- see extension.lua's extension_job.status
    -- for why: real MySQL 8.0 rejects a literal DEFAULT on TEXT columns.
    status VARCHAR(32) NOT NULL DEFAULT 'pending',
    created_at TEXT DEFAULT (%s),
    resolved_at TEXT
);
"""

function agent_schema_sql(db_path)
    return string.format(AGENT_SCHEMA,
        db.now_expr(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path)
    )
end

function agent.init_schema(db_path)
    return db.exec(db_path, agent_schema_sql(db_path))
end

--------------------------------------------------------------------------
-- Sessions
--------------------------------------------------------------------------

-- Self-contained (not calling auth.lua's identical helper) so this
-- module has no load-order dependency on auth.lua being required
-- first -- it isn't conceptually an auth concern, just a source of
-- unguessable ids, so it gets its own copy rather than an implicit
-- cross-file dependency on one.
function random_session_token()
    urandom = io.open("/dev/urandom", "rb")
    if urandom == nil then
        return nil, "cannot open /dev/urandom"
    end
    raw = io.read(urandom, 16)
    io.close(urandom)
    if raw == nil or string.len(raw) != 16 then
        return nil, "short read from /dev/urandom"
    end
    hex = {}
    for i = 1, string.len(raw) do
        table.insert(hex, string.format("%02x", string.byte(raw, i)))
    end
    return table.concat(hex)
end

function agent.create_session(db_path, login, title)
    session_id, err = random_session_token()
    if session_id == nil then
        return nil, err
    end
    db.exec(db_path, string.format(
        "INSERT INTO agent_session (id, login, title) VALUES (%s, %s, %s);",
        db.quote(session_id), db.quote(login), db.literal(title)
    ))
    return session_id
end

-- Requires the session to belong to `login` -- one user can never
-- read or continue another user's conversation just by guessing or
-- reusing a session id.
function agent.get_session(db_path, session_id, login)
    rows = db.query(db_path, string.format(
        "SELECT * FROM agent_session WHERE id = %s AND login = %s;",
        db.quote(session_id), db.quote(login)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

-- Derives a short session title from a real user message, once, if the
-- session doesn't already have one -- avoids leaving chats "Untitled"
-- in history/knowledge-pool listings just because chat-start's own
-- optional title field was left blank, which is the common case (see
-- render_chat_sessions_list's own "Untitled chat" fallback). Only ever
-- fires on the first message that finds an empty title, so in the
-- normal case that's the session's actual first message; a title set
-- explicitly at chat-start is never overwritten. Reuses
-- document.guess_title_from_body's own text-to-title logic (skip
-- headings, strip bullet/quote prefixes, ~72-char word-boundary
-- cutoff) rather than duplicating it -- same underlying problem
-- (turn a blob of text into a short display title), and
-- agent.display_content strips the [Current user: ...]/[Current
-- page: ...] annotations first, or they'd end up as the "title"
-- instead of the actual question.
function agent.maybe_set_title_from_message(db_path, session_id, login, user_message)
    session = agent.get_session(db_path, session_id, login)
    if session == nil or (session.title != nil and session.title != "") then
        return
    end
    clean_message = agent.display_content(user_message)
    title = document.guess_title_from_body(clean_message)
    if title == "Untitled note" then
        return
    end
    db.exec(db_path, string.format(
        "UPDATE agent_session SET title = %s WHERE id = %s;",
        db.quote(title), db.quote(session_id)
    ))
end

function agent.list_sessions(db_path, login)
    rows = db.query(db_path, string.format(
        "SELECT * FROM agent_session WHERE login = %s ORDER BY updated_at DESC;",
        db.quote(login)
    ))
    if rows == nil then
        return {}
    end
    return rows
end

function agent.touch_session(db_path, session_id)
    db.exec(db_path, string.format(
        "UPDATE agent_session SET updated_at = %s WHERE id = %s;",
        db.now_expr(db_path), db.quote(session_id)
    ))
end

--------------------------------------------------------------------------
-- Messages
--------------------------------------------------------------------------

-- Fixed (task #87, in passing): this used to re-derive the new
-- message's id via SELECT MAX(id), the exact same real concurrent-CGI
-- race ledger.lua's append_create/append_update already had fixed
-- under task #77 -- two simultaneous chat-message requests could both
-- read the same MAX(id) and collide. db.exec's own second return
-- value (last_insert_rowid()/insert_id) is read on the very same
-- connection the insert itself just ran on, so it can't see another
-- connection's insert regardless of timing. Needed correctly now that
-- knowledge_context/knowledge_chat_eval key off this id directly.
function agent.add_message(db_path, session_id, role, content, in_context)
    if in_context == nil then
        in_context = true
    end
    in_context_flag = 0
    if in_context == true then
        in_context_flag = 1
    end
    _, message_id = db.exec(db_path, string.format(
        "INSERT INTO agent_message (session_id, role, content, in_context) VALUES (%s, %s, %s, %d);",
        db.quote(session_id), db.quote(role), db.quote(content), in_context_flag
    ))
    agent.touch_session(db_path, session_id)
    return tonumber(message_id)
end

function agent.active_messages(db_path, session_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM agent_message WHERE session_id = %s AND in_context = 1 ORDER BY id ASC;",
        db.quote(session_id)
    ))
    if rows == nil then
        return {}
    end
    return rows
end

-- Cleans a message's content for DISPLAY only -- never called on what
-- active_messages/build_history_prompt feeds back to the model itself,
-- which still needs its own raw <tool>/<method>/<args>/<done> tag
-- protocol and the real page-context text intact to make sense of its
-- own prior turns. A human reading the transcript doesn't need any of
-- that literally: a <done>...</done>-wrapped final answer should just
-- read as its own inner text, a tool call as a short "-> what ran"
-- line instead of raw tags, and the [Current user: ...]/[Current
-- page: ...] annotations html.render_chat_widget's own JS prepends to
-- every user message (see its own comment on why every message, not
-- just the first) are there for the model, not for the user to see
-- restated back to them.
function agent.display_content(content)
    if content == nil then
        return content
    end
    content = string.gsub(content, "^%[Current user: .-%]\n", "")
    content = string.gsub(content, "^%[Current page: .-%]\n\n", "")
    done_message = string.match(content, "^%s*<done>%s*(.-)%s*</done>%s*$")
    if done_message != nil then
        return done_message
    end
    tool_name = string.match(content, "<tool>%s*(.-)%s*</tool>")
    method_name = string.match(content, "<method>%s*(.-)%s*</method>")
    if tool_name != nil and method_name != nil then
        return "-> " .. tool_name .. "." .. method_name .. "(...)"
    end
    return content
end

-- Every message, active or compacted-away -- the full, never-deleted
-- transcript, for a "show full history" view.
-- task #87: which session a message belongs to, so /api/chat-widget-
-- feedback can check ownership (via agent.get_session) before
-- recording feedback -- without this, any authenticated user could
-- submit feedback against any message_id, not just their own
-- conversations, just by guessing/incrementing the id.
function agent.message_session_id(db_path, message_id)
    rows = db.query(db_path, string.format(
        "SELECT session_id FROM agent_message WHERE id = %d;", tonumber(message_id)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1].session_id
end

function agent.all_messages(db_path, session_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM agent_message WHERE session_id = %s ORDER BY id ASC;",
        db.quote(session_id)
    ))
    if rows == nil then
        return {}
    end
    for _, row in ipairs(rows) do
        row.content = agent.display_content(row.content)
    end
    return rows
end

--------------------------------------------------------------------------
-- Context-window compaction
--------------------------------------------------------------------------

-- A simple chars/4 heuristic, not a real tokenizer -- ported as-is
-- from brain-ex: cheap, no model-specific vocabulary to keep in sync,
-- and only needs to be roughly right (the threshold check it feeds has
-- headroom built in, not a hard model context limit).
function agent.estimate_tokens(text)
    if text == nil then
        return 0
    end
    return math.ceil(string.len(text) / 4)
end

-- Summarizes everything except the last `keep_last` active messages
-- into one new 'compaction_summary' message once the active window's
-- estimated token count crosses the threshold, then marks the
-- summarized originals in_context = 0 -- ported from brain-ex's
-- agent_engine.run_agent, same threshold/keep-last defaults. Never
-- deletes anything; the summary is itself just another additive
-- message.
function agent.compact_if_needed(db_path, session_id, system_prompt, model)
    active = agent.active_messages(db_path, session_id)

    threshold = DEFAULT_COMPACTION_THRESHOLD
    env_threshold = tonumber(os.getenv("AGENT_COMPACTION_THRESHOLD"))
    if env_threshold != nil then
        threshold = env_threshold
    end

    keep_last = 4
    if #active <= keep_last then
        return false
    end

    total_tokens = agent.estimate_tokens(system_prompt)
    for _, msg in ipairs(active) do
        total_tokens = total_tokens + agent.estimate_tokens(msg.content)
    end

    if total_tokens <= threshold then
        return false
    end

    to_compact = {}
    for i = 1, #active - keep_last do
        table.insert(to_compact, active[i])
    end

    summary_prompt = "You are a context compaction engine. Please summarize the following " ..
        "conversation history into a concise, structured Markdown summary of goals, key " ..
        "information established, and progress. Focus on preserving factual details and " ..
        "state, so that a future model invocation has all the necessary context. Keep the " ..
        "summary under 300 words.\n\nConversation to summarize:\n"
    for _, msg in ipairs(to_compact) do
        summary_prompt = summary_prompt .. string.upper(msg.role) .. ": " .. msg.content .. "\n"
    end

    summary, err, usage = agent_provider.generate(model, "You are a concise summarizer.", summary_prompt)
    if summary == nil or err != nil then
        return false, err
    end

    summary_message_id = agent.add_message(db_path, session_id, "compaction_summary", summary, true)
    -- task #87: a real model call, same audit-trail bar as any chat
    -- turn -- but not a knowledge_chat_eval candidate, since that
    -- table classifies conversational *replies* the user actually
    -- sees, and a compaction summary is never shown as one.
    knowledge.record_context(db_path, session_id, summary_message_id, summary_prompt, model, nil, usage)

    ids = {}
    for _, msg in ipairs(to_compact) do
        table.insert(ids, tostring(msg.id))
    end
    db.exec(db_path, "UPDATE agent_message SET in_context = 0 WHERE id IN (" .. table.concat(ids, ",") .. ");")

    return true
end

--------------------------------------------------------------------------
-- Tool use
--------------------------------------------------------------------------
--
-- A small, explicit built-in registry (not an open-ended plugin
-- system the way extensions are) -- the model can only ever call
-- exactly what's listed here, with no escape hatch. Each entry is
-- marked destructive or not; the turn loop below auto-executes
-- non-destructive calls and pauses destructive ones for a human to
-- approve, replacing brain-ex's blocking terminal y/N prompt (which
-- assumes a synchronous, long-lived process -- CGI has neither) with a
-- real two-phase state machine: a destructive request is persisted as
-- an agent_pending_action row and the turn loop returns immediately;
-- a *separate* later request (agent.approve_pending/deny_pending)
-- executes it (or records the denial) and resumes the loop from there.

AGENT_TOOLS = {
    document = {
        search = {destructive = false},
        create = {destructive = true},
        update = {destructive = true},
    },
    -- Generic entity access -- any registered schema, not a curated
    -- subset (schema.lua/entity.lua's own validation is the safety
    -- boundary, same as the HTTP/CLI layer already relies on). list_types
    -- and fields exist so the model can discover real entity types and
    -- their field names/types itself rather than the system prompt
    -- needing to hardcode every schema that might ever be registered.
    entity = {
        list_types = {destructive = false},
        fields = {destructive = false},
        list = {destructive = false},
        get = {destructive = false},
        create = {destructive = true},
        update = {destructive = true},
        archive = {destructive = true},
        unarchive = {destructive = true},
    },
    -- Reusable Entry templates (src/template.lua) -- a separate,
    -- filesystem-based system from `document`, invisible to every other
    -- tool. Read-only, same no-capability-check precedent as
    -- document.search: lets the model discover a template exists and
    -- get its rendered content, then hand that straight to
    -- document.create's own content arg.
    template = {
        list = {destructive = false},
        get = {destructive = false},
    },
    -- Read-only introspection into the knowledge pool's own tiering/
    -- retrieval activity (see knowledge.lua), plus one destructive tool
    -- (task #107): `distill` writes a genuinely new, single-idea
    -- document extracted from a source -- a real write (a new
    -- document/entity_event row), so it needs the same human-approval
    -- gate every other destructive tool has.
    knowledge = {
        stats = {destructive = false},
        list = {destructive = false},
        distill = {destructive = true},
    },
}

function agent.is_known_tool(tool_name, method_name)
    group = AGENT_TOOLS[tool_name]
    if group == nil then
        return false
    end
    return group[method_name] != nil
end

function agent.is_destructive(tool_name, method_name)
    group = AGENT_TOOLS[tool_name]
    if group == nil or group[method_name] == nil then
        return false
    end
    return group[method_name].destructive == true
end

function issues_summary(issues)
    if issues == nil or #issues == 0 then
        return "failed"
    end
    parts = {}
    for _, issue in ipairs(issues) do
        if issue.severity == "error" then
            table.insert(parts, tostring(issue.message))
        end
    end
    if #parts == 0 then
        return "failed"
    end
    return table.concat(parts, "; ")
end

-- Grounds the agent's own answers in real page content (found live:
-- document.search's tool result used to return only "#id title" lines
-- -- document.search itself already fetches full content for scoring,
-- but the tool wrapper around it threw that away, so the model could
-- learn *which* pages might be relevant but never actually read one
-- before answering). Bounded per result (not the full page verbatim)
-- so a search that matches several long pages doesn't balloon every
-- turn's prompt/token cost -- trimmed to the last whole word rather
-- than cutting mid-word.
SEARCH_EXCERPT_LENGTH = 1200

function excerpt(text, max_length)
    if text == nil or text == "" then
        return ""
    end
    if string.len(text) <= max_length then
        return text
    end
    truncated = string.sub(text, 1, max_length)
    trimmed = string.match(truncated, "^(.*)%s%S*$")
    if trimmed != nil and string.len(trimmed) > max_length - 40 then
        truncated = trimmed
    end
    return truncated .. "..."
end

-- Compact "field=value; field=value" text for one entity.get/list row,
-- for the model to read -- sorted so output is deterministic rather
-- than depending on pairs()'s unspecified iteration order.
function row_summary(row)
    parts = {}
    for k, v in pairs(row) do
        table.insert(parts, tostring(k) .. "=" .. tostring(v))
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

-- Whether the agent itself is allowed to write to entity_type. The
-- agent's own capability is independently configured, exactly like any
-- other API key -- not derived from whichever human happens to be
-- chatting (auth.lua's own principle for api_key rows: "a key's
-- capabilities are its own, not derived from whoever created it").
-- Without this, a plain baseline user's chat session could write to an
-- admin_write_only type the same user's own /register form would
-- refuse -- confirmed live as a real gap, not hypothetical.
--
-- Reuses the api_key table/admin UI wholesale via a well-known
-- reserved label ("chat-agent") rather than inventing a new concept --
-- an admin configures the agent's own capability the exact same way
-- they'd configure any other integration's key, via
-- /admin-api-keys or `platform api-key create/capabilities`. Fails
-- closed: no such key yet means no admin-gated writes at all, not a
-- silent default of full access.
function agent.check_write_capability(db_path, entity_type)
    if schema.admin_write_only(db_path, entity_type) == false then
        return true
    end
    agent_key = auth.get_api_key(db_path, "chat-agent")
    cap = ""
    if agent_key != nil then
        cap = agent_key.cap
    end
    return string.find(cap, "a", 1, true) != nil
end

-- Runs one already-approved (or non-destructive) tool call. `author`
-- is the real, authenticated login the call runs as -- tool actions
-- are attributed the same way any other write in this system is, never
-- to a separate "agent" identity. `session_id` is recorded as the
-- write's source (entity_event.source_notebook_entry_id) so the ledger
-- can still distinguish *how* a change happened -- via this chat
-- session, not the direct edit form -- without that ever affecting who
-- it's attributed to.
function agent.execute_tool(db_path, author, session_id, tool_name, method_name, args)
    source = {notebook_entry_id = "agent-session:" .. tostring(session_id)}

    if tool_name == "document" and method_name == "search" then
        results = knowledge.search_and_log(db_path, args.query, 5, true, session_id, author)
        if #results == 0 then
            return "No matching pages found."
        end
        -- Structural, not just a prompt reminder: multiple pages
        -- genuinely sharing a title is real and common here (293
        -- duplicate titles in production, mostly repeated Benchling
        -- resyncs) -- rather than relying on the model to notice and
        -- remember not to ask the human for a raw id every time, the
        -- tool result itself surfaces the distinguishing fields
        -- (creation date, external_id) and calls out the collision
        -- explicitly whenever this batch of results actually has one.
        title_counts = {}
        for _, r in ipairs(results) do
            current_count = title_counts[r.title]
            if current_count == nil then
                current_count = 0
            end
            title_counts[r.title] = current_count + 1
        end
        lines = {}
        for _, r in ipairs(results) do
            detail_bits = {}
            if r.created_at != nil and r.created_at != "" then
                table.insert(detail_bits, "created " .. string.sub(r.created_at, 1, 10))
            end
            if r.external_id != nil and r.external_id != "" then
                table.insert(detail_bits, "external_id=" .. r.external_id)
            end
            header = "#" .. tostring(r.id) .. " " .. r.title
            if #detail_bits > 0 then
                header = header .. " (" .. table.concat(detail_bits, ", ") .. ")"
            end
            if title_counts[r.title] > 1 then
                header = header .. " [one of " .. tostring(title_counts[r.title]) ..
                    " pages titled '" .. r.title .. "' -- distinguish by date/external_id/content above, never by asking the user for the id]"
            end
            table.insert(lines, header .. "\n" .. excerpt(r.content, SEARCH_EXCERPT_LENGTH))
        end
        return table.concat(lines, "\n\n")
    end

    if tool_name == "document" and method_name == "create" then
        if agent.check_write_capability(db_path, "document") == false then
            return nil, "Forbidden: this requires the chat agent's own Admin capability -- ask an admin to grant it via /admin-api-keys."
        end
        parent_id = tonumber(args.parent_id)
        created_id, issues = document.create_page(db_path, author, args.title, parent_id, args.content, source)
        if created_id == nil then
            return nil, issues_summary(issues)
        end
        return "Created page #" .. tostring(created_id) .. " (" .. tostring(args.title) .. ")"
    end

    if tool_name == "document" and method_name == "update" then
        if agent.check_write_capability(db_path, "document") == false then
            return nil, "Forbidden: this requires the chat agent's own Admin capability -- ask an admin to grant it via /admin-api-keys."
        end
        target_id = tonumber(args.entity_id)
        if target_id == nil then
            return nil, "update requires entity_id"
        end
        parent_id = tonumber(args.parent_id)
        updated_id, issues = document.update_page(db_path, author, target_id, args.title, parent_id, args.content, source)
        if updated_id == nil then
            return nil, issues_summary(issues)
        end
        return "Updated page #" .. tostring(updated_id)
    end

    if tool_name == "entity" and method_name == "list_types" then
        types = schema.list(db_path)
        if #types == 0 then
            return "No entity types registered."
        end
        names = {}
        for _, t in ipairs(types) do
            table.insert(names, t.name)
        end
        return table.concat(names, ", ")
    end

    if tool_name == "entity" and method_name == "fields" then
        if args.entity_type == nil then
            return nil, "fields requires entity_type"
        end
        fields = schema.fields(db_path, args.entity_type)
        if #fields == 0 then
            return nil, "unknown entity type, or it has no fields: " .. tostring(args.entity_type)
        end
        lines = {}
        for _, f in ipairs(fields) do
            required = ""
            if tonumber(f.required) == 1 then
                required = ", required"
            end
            table.insert(lines, string.format("%s (%s%s)", f.name, f.type, required))
        end
        return table.concat(lines, "\n")
    end

    if tool_name == "entity" and method_name == "list" then
        if args.entity_type == nil then
            return nil, "list requires entity_type"
        end
        limit = tonumber(args.limit)
        if limit == nil then
            limit = 20
        end
        offset = tonumber(args.offset)
        -- Same GET-list shape /api/v1 already offers (filter_field +
        -- limit/offset) -- a plain entity.list otherwise, unchanged.
        rows = nil
        if args.filter_field != nil and args.filter_value != nil then
            rows = entity.list_by_field(db_path, args.entity_type, args.filter_field, args.filter_value, limit, offset, false)
        else
            rows = entity.list(db_path, args.entity_type, limit, offset, false)
        end
        if #rows == 0 then
            return "No " .. tostring(args.entity_type) .. " rows found."
        end
        lines = {}
        for _, row in ipairs(rows) do
            table.insert(lines, "#" .. tostring(row.id) .. " " .. row_summary(row))
        end
        return table.concat(lines, "\n")
    end

    if tool_name == "entity" and method_name == "get" then
        target_id = tonumber(args.entity_id)
        if args.entity_type == nil or target_id == nil then
            return nil, "get requires entity_type and entity_id"
        end
        row = entity.get(db_path, args.entity_type, target_id)
        if row == nil then
            return nil, "no such " .. tostring(args.entity_type) .. " #" .. tostring(target_id)
        end
        return row_summary(row)
    end

    if tool_name == "entity" and method_name == "create" then
        if args.entity_type == nil then
            return nil, "create requires entity_type"
        end
        if agent.check_write_capability(db_path, args.entity_type) == false then
            return nil, "Forbidden: " .. tostring(args.entity_type) .. " requires the chat agent's own Admin capability -- ask an admin to grant it via /admin-api-keys."
        end
        values = {}
        for k, v in pairs(args) do
            if k != "entity_type" then
                values[k] = v
            end
        end
        created_id, issues = entity.create(db_path, args.entity_type, values, author, source)
        if created_id == nil then
            return nil, issues_summary(issues)
        end
        return "Created " .. tostring(args.entity_type) .. " #" .. tostring(created_id)
    end

    if tool_name == "entity" and method_name == "update" then
        target_id = tonumber(args.entity_id)
        if args.entity_type == nil or target_id == nil then
            return nil, "update requires entity_type and entity_id"
        end
        if agent.check_write_capability(db_path, args.entity_type) == false then
            return nil, "Forbidden: " .. tostring(args.entity_type) .. " requires the chat agent's own Admin capability -- ask an admin to grant it via /admin-api-keys."
        end
        -- reason (task #93) is metadata about the change, not a field
        -- being changed on the entity itself -- pulled out the same way
        -- entity_type/entity_id already are, so it never ends up as a
        -- literal column update.
        values = {}
        for k, v in pairs(args) do
            if k != "entity_type" and k != "entity_id" and k != "reason" then
                values[k] = v
            end
        end
        updated_id, issues = entity.update(db_path, args.entity_type, target_id, values, author, source, args.reason)
        if updated_id == nil then
            return nil, issues_summary(issues)
        end
        return "Updated " .. tostring(args.entity_type) .. " #" .. tostring(updated_id)
    end

    if tool_name == "entity" and method_name == "archive" then
        target_id = tonumber(args.entity_id)
        if args.entity_type == nil or target_id == nil then
            return nil, "archive requires entity_type and entity_id"
        end
        if agent.check_write_capability(db_path, args.entity_type) == false then
            return nil, "Forbidden: " .. tostring(args.entity_type) .. " requires the chat agent's own Admin capability -- ask an admin to grant it via /admin-api-keys."
        end
        archived_id, issues = entity.archive(db_path, args.entity_type, target_id, author, source, args.reason)
        if archived_id == nil then
            return nil, issues_summary(issues)
        end
        return "Archived " .. tostring(args.entity_type) .. " #" .. tostring(archived_id)
    end

    if tool_name == "entity" and method_name == "unarchive" then
        target_id = tonumber(args.entity_id)
        if args.entity_type == nil or target_id == nil then
            return nil, "unarchive requires entity_type and entity_id"
        end
        if agent.check_write_capability(db_path, args.entity_type) == false then
            return nil, "Forbidden: " .. tostring(args.entity_type) .. " requires the chat agent's own Admin capability -- ask an admin to grant it via /admin-api-keys."
        end
        unarchived_id, issues = entity.unarchive(db_path, args.entity_type, target_id, author, source)
        if unarchived_id == nil then
            return nil, issues_summary(issues)
        end
        return "Unarchived " .. tostring(args.entity_type) .. " #" .. tostring(unarchived_id)
    end

    if tool_name == "template" and method_name == "list" then
        templates_dir = config.templates_dir()
        names = template.names(templates_dir)
        if #names == 0 then
            return "No templates available."
        end
        lines = {}
        for _, name in ipairs(names) do
            def, err = template.load(templates_dir, name)
            if def != nil then
                description = def.description
                if description == nil then
                    description = ""
                end
                table.insert(lines, name .. " (" .. tostring(def.label) .. "): " .. description)
            end
        end
        return table.concat(lines, "\n")
    end

    if tool_name == "template" and method_name == "get" then
        if args.name == nil then
            return nil, "get requires name"
        end
        def, err = template.load(config.templates_dir(), args.name)
        if def == nil then
            return nil, "no such template: " .. tostring(args.name) .. " (" .. tostring(err) .. ")"
        end
        rendered = template.render(def)
        default_path = def.default_path
        if default_path == nil then
            default_path = def.label
        end
        return "Suggested page name: " .. tostring(default_path) .. "\n\n" .. rendered
    end

    if tool_name == "knowledge" and method_name == "stats" then
        stats = knowledge.stats(db_path)
        return string.format(
            "tier0=%d tier1=%d tier2=%d tier3=%d notes=%d retrievals=%d reviewed=%d sessions=%d",
            stats.tier_counts[0], stats.tier_counts[1], stats.tier_counts[2], stats.tier_counts[3],
            stats.note_count, stats.retrieval_count, stats.reviewed_note_count, stats.session_count
        )
    end

    -- Read-only listing (task #87, updated #106/#107) -- surfaces the
    -- pool's real document ids/tiers/atomicity to the model. Atomicity
    -- (task #107) is what the distillation pass reads to decide what's
    -- actually worth distilling from -- "ok" already covers one focused
    -- idea, nothing to extract that isn't already there. Optional
    -- args.tier filters, same as the CLI.
    if tool_name == "knowledge" and method_name == "list" then
        rows = knowledge.list_documents(db_path, tonumber(args.tier))
        if #rows == 0 then
            return "No knowledge pool documents found."
        end
        lines = {}
        for _, row in ipairs(rows) do
            body = row.content
            if body == nil then
                body = ""
            end
            table.insert(lines, string.format(
                "#%s [tier %s, %s] %s (heat=%.2f, retrievals=%s)",
                tostring(row.id), tostring(row.tier), document.atomicity_status(body), tostring(row.title),
                row.effective_heat, tostring(row.retrieval_count)
            ))
        end
        return table.concat(lines, "\n")
    end

    -- Destructive (task #107): writes a new, concise, single-idea
    -- document distilled from a source the agent has read -- the real
    -- counterpart to knowledge.create_document_note's reasoning-note
    -- path. A genuine write (a new document/entity_event row), so this
    -- goes through the same pending-action approval flow as
    -- document.create/entity.create.
    if tool_name == "knowledge" and method_name == "distill" then
        if args.title == nil or args.content == nil then
            return nil, "distill requires title and content"
        end
        document_id, err = knowledge.distill_document(db_path, author, tonumber(args.source_document_id), args.title, args.content)
        if document_id == nil then
            return nil, tostring(err)
        end
        return "Distilled document #" .. tostring(document_id) .. " (source #" .. tostring(args.source_document_id) .. ")"
    end

    return nil, "unknown tool: " .. tostring(tool_name) .. "." .. tostring(method_name)
end

function agent.create_pending_action(db_path, session_id, tool_name, method_name, args)
    json = require("dkjson")
    db.exec(db_path, string.format(
        "INSERT INTO agent_pending_action (session_id, tool, method, args_json) VALUES (%s, %s, %s, %s);",
        db.quote(session_id), db.quote(tool_name), db.quote(method_name), db.quote(json.encode(args))
    ))
    rows = db.query(db_path, "SELECT MAX(id) AS id FROM agent_pending_action;")
    return tonumber(rows[1].id)
end

-- Requires the pending action's own session to belong to `login` --
-- same ownership discipline as agent.get_session.
function agent.get_pending_action(db_path, pending_id, login)
    rows = db.query(db_path, string.format("""
        SELECT p.* FROM agent_pending_action p
        JOIN agent_session s ON s.id = p.session_id
        WHERE p.id = %d AND s.login = %s;
    """, tonumber(pending_id), db.quote(login)))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

function agent.resolve_pending_action(db_path, pending_id, status)
    db.exec(db_path, string.format(
        "UPDATE agent_pending_action SET status = %s, resolved_at = %s WHERE id = %d;",
        db.quote(status), db.now_expr(db_path), tonumber(pending_id)
    ))
end

-- The most recent unresolved pending action for a session, if any --
-- what a chat UI checks to decide whether to show an approve/deny
-- prompt instead of a plain message input.
function agent.latest_pending(db_path, session_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM agent_pending_action WHERE session_id = %s AND status = 'pending' ORDER BY id DESC LIMIT 1;",
        db.quote(session_id)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

--------------------------------------------------------------------------
-- The turn loop
--------------------------------------------------------------------------

function build_history_prompt(messages)
    parts = {}
    for _, msg in ipairs(messages) do
        if msg.role == "compaction_summary" then
            table.insert(parts, "[COMPACTED HISTORY SUMMARY]:\n" .. msg.content)
        elseif msg.role == "user" then
            table.insert(parts, "User: " .. msg.content)
        elseif msg.role == "assistant" then
            table.insert(parts, "Assistant: " .. msg.content)
        elseif msg.role == "tool_result" then
            table.insert(parts, "Tool Output:\n" .. msg.content)
        end
    end
    return table.concat(parts, "\n\n")
end

function strip_spaces(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Splits on "\n" only (not gmatch's "[^\r\n]+", which silently drops
-- every blank line -- exactly the lines a real multi-paragraph
-- Markdown document is full of). Keeps empty lines as empty strings so
-- a value spanning them is reconstructed byte-for-byte, not collapsed.
function split_lines(s)
    lines = {}
    start = 1
    while true do
        nl = string.find(s, "\n", start, true)
        if nl == nil then
            table.insert(lines, string.sub(s, start))
            return lines
        end
        table.insert(lines, string.sub(s, start, nl - 1))
        start = nl + 1
    end
end

-- A real, previously-undiscovered bug (found live: `content=# Heading`
-- followed by several more lines of Markdown -- headings, a blank
-- line, a table -- came back from a real document.create call holding
-- only "# Heading", everything else silently gone): the old
-- implementation split on "[^\r\n]+" (dropping every blank line
-- outright) and re-matched "^(.-)=(.*)$" per line, so ANY multi-line
-- value -- which any real page content is -- lost everything past its
-- own first line, with no error anywhere.
--
-- A value now continues across as many following lines as don't
-- themselves look like a new key=value pair -- new-key detection is
-- deliberately narrow (a bare identifier: letters/digits/underscore,
-- starting with a letter or underscore, immediately before "=") so a
-- real content line is never mistaken for one just because it happens
-- to contain an "=" somewhere. This can still misfire on a content
-- line that itself starts with something identifier-shaped immediately
-- followed by "=" (e.g. "x=5 is the answer" as literally the first
-- line of a value) -- a narrower edge case than the guaranteed data
-- loss this replaces, not a fully general escaping scheme.
function parse_tool_call(result)
    tool_name = string.match(result, "<tool>%s*(.-)%s*</tool>")
    method_name = string.match(result, "<method>%s*(.-)%s*</method>")
    args_str = string.match(result, "<args>%s*(.-)%s*</args>")
    args = {}
    if args_str != nil then
        current_key = nil
        for _, raw_line in ipairs(split_lines(args_str)) do
            line = (string.gsub(raw_line, "\r$", ""))
            key, value = string.match(line, "^([%a_][%w_]*)=(.*)$")
            if key != nil then
                current_key = key
                args[current_key] = value
            elseif current_key != nil then
                args[current_key] = args[current_key] .. "\n" .. line
            end
        end
    end
    return tool_name, method_name, args
end

-- The default system prompt teaching the model the tag protocol and
-- listing the tools in AGENT_TOOLS -- hand-maintained text, not
-- generated from the registry, so a new tool needs a line added here
-- too (see AGENT_TOOLS' own comment).
--
-- Appends theme.json's own system_prompt_extra, if a deployment set
-- one (task #70) -- deployment-specific instructions (domain
-- vocabulary, house style, use-case reminders) without editing
-- platform-wip's own source. Every real call site (run_turn's own
-- fallback, approve_pending, deny_pending) already reaches this
-- function exactly when no caller-supplied system_prompt was given,
-- so this is the one place that needs to change for every one of them
-- to pick it up -- see doc/architecture.md's "Chat" section.
function agent.default_system_prompt()
    config = require("config")
    theme = config.load_theme(config.find_root())
    extra = ""
    if theme.system_prompt_extra != nil then
        extra = "\n\n" .. theme.system_prompt_extra
    end
    return """
You are an assistant embedded in a data platform. Answer directly when you can, or use a tool to look up or change data.

Some of your messages start with "[Current user: ...]" and/or "[Current
page: ...]" lines, automatically added by the app, not typed by the user --
never treat them as part of what the user actually typed.
- "[Current user: ...]" is the real login of the person you're talking to.
  Use it as the sensible default whenever you create or update something with
  an owner/assignee-style field and the user didn't name someone else.
- "[Current page: ...]" tells you what page the user is actually looking at
  right now (its type, title, and, where relevant, the entity type/id or view
  name it shows). Trust it as ground truth (e.g. answer "what page am I on"
  directly from it).

When creating or updating a record, fill in optional fields you can
reasonably infer from the request instead of leaving them blank (e.g. a
concise subject/title summarizing what was asked, a sensible due date if one
is clearly implied) -- the same judgment call a person filling out the same
form by hand would make. If a field is genuinely ambiguous, ask rather than
guessing.

When asked to write a Markdown table with specific rows and/or columns,
actually include every named row as a real data row, not just a header --
a table needs a header row, a separator row (|---|---|), and one data row
per item named in the request. Before finishing, check your own output has
all three parts and every item asked for; a header-only table is an
incomplete answer, not a done one.

If your first attempt at something (a search, a lookup) doesn't find what
you need, try again a different way (different search terms, a broader or
narrower query, a different tool) before giving up or asking the user for
help. You have room for several tool calls in a single turn -- use them
when the question genuinely calls for it, rather than answering from a
single attempt that came up empty or ambiguous.

Multiple records can genuinely share the same title (e.g. several
Benchling-synced pages all named after the same experiment number) --
when that happens, never ask the user for a raw internal id to
disambiguate; they don't think in ids and shouldn't have to. Instead use
what document.search or entity.get already gives you -- content excerpt,
creation date, an external_id if the row has one -- to either tell the
candidates apart yourself, or describe them to the user in those terms
("there are two pages titled X, one from March about Y and one from June
about Z -- which do you mean?").

Available tools:
- document.search -- search pages by keyword or topic; returns each matching page's id, title, and a real content excerpt so you can answer from what the page actually says, not just its title. Args: query=<search text>
- document.create -- create a new page. Args: title=<title>, parent_id=<optional parent page id>, content=<markdown content>
- document.update -- update an existing page. Args: entity_id=<page id>, title=<optional new title>, parent_id=<optional new parent id>, content=<optional new content>
- entity.list_types -- list every registered entity type (samples, tasks, experiments, whatever this deployment has). No args.
- entity.fields -- list an entity type's fields and their types, so you know what's valid before creating/updating one. Args: entity_type=<name>
- entity.list -- list rows of an entity type, optionally filtered to rows where one field equals a value. Args: entity_type=<name>, filter_field=<optional field name>, filter_value=<optional value, only used with filter_field>, limit=<optional, default 20>, offset=<optional, for paging past the first page>
- entity.get -- fetch one entity row by id. Args: entity_type=<name>, entity_id=<id>
- entity.create -- create a new entity row. Args: entity_type=<name>, plus one arg per field (e.g. status=open, due_date=2026-08-01)
- entity.update -- update fields on an existing entity row. Args: entity_type=<name>, entity_id=<id>, reason=<optional: why this change is being made>, plus one arg per field to change. Some entity types require a reason -- if the tool result says one is required, ask the user why before retrying.
- entity.archive -- archive (soft-remove) an entity row. Args: entity_type=<name>, entity_id=<id>, reason=<optional: why this change is being made>. Some entity types require a reason.
- entity.unarchive -- restore a previously archived entity row. Args: entity_type=<name>, entity_id=<id>
- template.list -- list reusable Entry templates (name, label, description) available to build a new page from. No args.
- template.get -- get one template's rendered content, ready to pass straight to document.create's own content arg, plus its suggested default page name. Args: name=<template name>
- knowledge.stats -- summarize the knowledge pool's tier distribution and retrieval activity. No args.
- knowledge.list -- list knowledge pool documents with their id, tier, atomicity (ok/thin/needs-split), heat, and retrieval count. Args: tier=<optional, filter to one tier 0-3>
- knowledge.distill -- write a new, concise, single-idea document distilled from a source you've actually read (e.g. via entity.get). Not a raw copy -- extract the one core idea in your own words. Only do this for a source that's genuinely not already atomic ("thin"/"ok" sources have nothing worth extracting). Args: title=<title>, content=<the distilled markdown text>, source_document_id=<optional: the existing document this was distilled from>. Requires human approval before anything is actually written.

If you don't already know an entity type's fields, call entity.fields first rather than guessing field names.

Each tool name above has two parts separated by a dot: the part before the
dot is the <tool> tag's value, the part after is the <method> tag's value --
never put the dot inside either tag, and never repeat the method name in
both. template.list means <tool>template</tool><method>list</method>, not
<tool>template.list</tool><method>list</method>.

To call a tool, reply with EXACTLY this shape and nothing else:
<tool>document</tool>
<method>search</method>
<args>
query=some search text
</args>

Each argument starts on its own line as key=value. A value can span multiple lines -- including blank lines, e.g. real Markdown page content -- everything up to the next key=value line (or the closing </args>) belongs to it, real newlines and all. Only start a new line with key= when you actually mean a new, different argument. After a tool call you will be given its result as a new turn, and can call another tool or give a final answer.

When you have a final answer for the user, reply with EXACTLY:
<done>Your final answer here.</done>

Never mix a tool call and a <done> reply in the same turn.
""" .. extra
end

ROLE_LABELS = {user = "User", assistant = "Assistant", tool_result = "Tool result"}

-- A human-readable transcript of a session's full message history (task
-- #108 follow-up, explicit user direction: "every conversation with the
-- agent is itself saved as a document" -- full session persistence, not
-- just the individual prompt/reasoning audit rows knowledge_context
-- already keeps per turn). Reuses agent.all_messages' own display_
-- content cleanup (strips the [Current user:...]/[Current page:...]
-- annotations, renders a tool call as "-> tool.method(...)") rather
-- than a second rendering path.
function build_session_transcript(messages)
    lines = {}
    for _, msg in ipairs(messages) do
        label = ROLE_LABELS[msg.role]
        if label == nil then
            label = msg.role
        end
        table.insert(lines, label .. ": " .. tostring(msg.content))
    end
    return table.concat(lines, "\n\n")
end

-- Keeps this session's own document (knowledge.sync_session_document)
-- in sync with its current transcript -- find-or-create, then update in
-- place every time a turn concludes, so it always reflects the
-- conversation so far, not a one-time snapshot. Filed under the
-- Knowledge Pool folder like any other system-derived document, so a
-- heavily-revisited conversation naturally becomes part of the same
-- tiered/searchable pool as everything else, and can itself cross into
-- distillation (knowledge.maybe_distill) the same way any other
-- document does -- no separate "combine what a conversation touched
-- into something durable" mechanism needed on top.
function sync_session_document(db_path, login, session_id)
    session = agent.get_session(db_path, session_id, login)
    title = "Untitled chat"
    if session != nil and session.title != nil and session.title != "" then
        title = session.title
    end
    messages = agent.all_messages(db_path, session_id)
    transcript = build_session_transcript(messages)
    knowledge.sync_session_document(db_path, login, session_id, "Chat: " .. title, transcript)
end

-- Runs the turn loop starting from the session's current active-message
-- state. `user_message`, if given, is recorded as a new user turn
-- before the loop starts; pass nil when resuming after a tool
-- approval/denial -- the loop just continues from whatever's already
-- in the active history. Returns a table:
--   {status = "done", message = "..."}
--   {status = "pending_approval", pending_id = N, tool = "...", method = "...", args = {...}}
--   {status = "turn_limit", message = "..."}
--   {status = "error", message = "..."}
--
-- Each call gets its own fresh MAX_TURNS budget, even a resume after a
-- pause -- deliberate, not an oversight: the approval pause is itself
-- a human circuit breaker, so restarting the budget on resume doesn't
-- reopen an unbounded-loop risk the way it would in a fully autonomous
-- run with no pauses at all.
function agent.run_turn(db_path, session_id, login, system_prompt, model, user_message)
    if system_prompt == nil or system_prompt == "" then
        system_prompt = agent.default_system_prompt()
    end

    if user_message != nil and user_message != "" then
        agent.add_message(db_path, session_id, "user", user_message, true)
        agent.maybe_set_title_from_message(db_path, session_id, login, user_message)
    end

    agent.compact_if_needed(db_path, session_id, system_prompt, model)

    for turn = 1, MAX_TURNS do
        active = agent.active_messages(db_path, session_id)
        prompt = build_history_prompt(active)

        result, err, usage = agent_provider.generate(model, system_prompt, prompt)
        if result == nil then
            -- Persisted, not just returned -- every run_turn call site
            -- (chat-message, chat-widget-send/approve/deny) previously
            -- discarded this return value entirely, so a provider
            -- failure was completely invisible: the turn just vanished
            -- with no trace in the transcript.
            error_message_id = agent.add_message(db_path, session_id, "tool_result", "ERROR: " .. tostring(err), true)
            -- task #87: still recorded even on failure -- what was
            -- actually sent is exactly as much an audit fact as what
            -- came back, and usage/reasoning simply don't apply here.
            context_id = knowledge.record_context(db_path, session_id, error_message_id, prompt, model, nil, nil)
            knowledge.record_chat_eval(db_path, session_id, context_id, error_message_id, agent_provider.name(), model, true, nil)
            return {status = "error", message = tostring(err)}
        end

        message_id = agent.add_message(db_path, session_id, "assistant", result, true)

        -- task #87: persist the exact prompt/reasoning/tokens for this
        -- turn. A reply that leaks visible reasoning (see
        -- knowledge.reply_has_visible_reasoning) gets that reasoning
        -- split out into its own document (source_type='reasoning',
        -- task #106: a real Notebook page under the Knowledge Pool
        -- folder, not a separate knowledge_note) -- it then goes
        -- through the same tiering/retrieval/decay pipeline as every
        -- other pool document, rather than sitting in a second,
        -- parallel log only this table can see.
        reasoning_document_id = nil
        if knowledge.reply_has_visible_reasoning(result) then
            reasoning_document_id = knowledge.create_document_note(db_path, login,
                "Chat reasoning (session " .. tostring(session_id) .. ")", result,
                "reasoning", message_id, tostring(session_id))
        end
        context_id = knowledge.record_context(db_path, session_id, message_id, prompt, model, reasoning_document_id, usage)
        knowledge.record_chat_eval(db_path, session_id, context_id, message_id, agent_provider.name(), model, false, result)

        done_message = string.match(result, "<done>%s*(.-)%s*</done>")
        if done_message != nil then
            sync_session_document(db_path, login, session_id)
            return {status = "done", message = done_message}
        end

        tool_name, method_name, args = parse_tool_call(result)
        if tool_name == nil or method_name == nil then
            sync_session_document(db_path, login, session_id)
            return {status = "done", message = result}
        end

        if not agent.is_known_tool(tool_name, method_name) then
            agent.add_message(db_path, session_id, "tool_result",
                "ERROR: unknown tool " .. tostring(tool_name) .. "." .. tostring(method_name), true)
        elseif agent.is_destructive(tool_name, method_name) then
            pending_id = agent.create_pending_action(db_path, session_id, tool_name, method_name, args)
            sync_session_document(db_path, login, session_id)
            return {status = "pending_approval", pending_id = pending_id, tool = tool_name, method = method_name, args = args}
        else
            tool_result, tool_err = agent.execute_tool(db_path, login, session_id, tool_name, method_name, args)
            summary = tostring(tool_result)
            if tool_err != nil then
                summary = "ERROR: " .. tostring(tool_err)
            end
            agent.add_message(db_path, session_id, "tool_result", summary, true)
        end
    end

    sync_session_document(db_path, login, session_id)
    return {status = "turn_limit", message = "Unable to complete tool-assisted run in " .. tostring(MAX_TURNS) .. " turns."}
end

-- task #107: the agent-driven distillation pass -- unlike knowledge.
-- review_retrieval (rule-based, runs automatically after every real
-- search), this is a genuine model call: actually read a candidate
-- document's full content (via entity.get, not just knowledge.list's
-- own summary) and write a new, concise, single-idea document distilled
-- from it, rather than just promoting a tier number the way the old
-- (task #106-removed) materialize pass did. Not automatic on every
-- search -- a real, ongoing LLM cost for something that isn't
-- time-critical -- triggered explicitly (CLI `platform knowledge
-- distill`; task #108's queue is the actual automated trigger once it
-- exists).
--
-- Deliberately just a normal chat session/turn, not a separate
-- pipeline: knowledge.distill is a destructive tool, so a call to it
-- here pauses for approval exactly like any user-initiated chat does
-- (agent.run_turn's own pending_approval path) -- a human still has to
-- approve every distillation from the resulting session in the normal
-- chat UI, same as any other destructive tool call.
KNOWLEDGE_DISTILL_SYSTEM_PROMPT = """
You are reviewing this deployment's knowledge pool: documents captured from real retrieval activity, tiered by how often and how reliably they've proven useful (tier 0 raw intake, tier 1 working set, tier 2 curated draft, tier 3 atomic durable record). Heat decays over time, so tier and retrieval count alone don't guarantee current relevance -- effective_heat (from knowledge.list) reflects that.

Use knowledge.list to see current pool documents: id, tier, atomicity (ok / thin / needs-split), effective heat, retrieval count. For a document flagged "needs-split" (covers more than one real idea, or is unusually long/unfocused), read its full content with entity.get (entity_type=document) and write ONE genuinely atomic, single-idea document distilled from it with knowledge.distill -- concise, self-contained, in your own words, not a verbatim copy of the source. Do not distill from a document that's already "ok" or "thin" -- there's nothing worth extracting that isn't already there as-is.

Distilling nothing this pass is a completely acceptable outcome -- do not distill from a document you're unsure about; say why you're leaving it alone instead. When you're done, summarize what you reviewed and what you did (or didn't) distill, and end with a <done> message.
"""

function agent.run_knowledge_distillation(db_path, login, model)
    session_id, err = agent.create_session(db_path, login, "Knowledge Pool Distillation")
    if session_id == nil then
        return nil, err
    end
    result = agent.run_turn(db_path, session_id, login, KNOWLEDGE_DISTILL_SYSTEM_PROMPT, model,
        "Review the current knowledge pool and distill any documents that are genuinely ready.")
    return session_id, result
end

-- Executes an approved pending action, records its result, and resumes
-- the turn loop from there.
function agent.approve_pending(db_path, pending_id, login, system_prompt, model)
    pending = agent.get_pending_action(db_path, pending_id, login)
    if pending == nil then
        return nil, "no such pending action"
    end
    if pending.status != "pending" then
        return nil, "action already " .. tostring(pending.status)
    end

    json = require("dkjson")
    args, _, _ = json.decode(pending.args_json)
    if args == nil then
        args = {}
    end

    tool_result, tool_err = agent.execute_tool(db_path, login, pending.session_id, pending.tool, pending.method, args)
    summary = tostring(tool_result)
    if tool_err != nil then
        summary = "ERROR: " .. tostring(tool_err)
    end
    agent.add_message(db_path, pending.session_id, "tool_result", summary, true)
    agent.resolve_pending_action(db_path, pending_id, "approved")

    return agent.run_turn(db_path, pending.session_id, login, system_prompt, model, nil)
end

-- Denies a pending action, records the denial as a tool_result (so the
-- model sees it and can react), and resumes the turn loop -- a denial
-- is just another outcome the model gets to respond to, not a dead end.
function agent.deny_pending(db_path, pending_id, login, system_prompt, model)
    pending = agent.get_pending_action(db_path, pending_id, login)
    if pending == nil then
        return nil, "no such pending action"
    end
    if pending.status != "pending" then
        return nil, "action already " .. tostring(pending.status)
    end

    agent.add_message(db_path, pending.session_id, "tool_result", "User denied execution of this action.", true)
    agent.resolve_pending_action(db_path, pending_id, "denied")

    return agent.run_turn(db_path, pending.session_id, login, system_prompt, model, nil)
end

return agent
