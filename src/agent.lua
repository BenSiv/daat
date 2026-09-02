-- The chat/agent subsystem: real per-user sessions and DB-backed
-- conversation history -- every session belongs to a specific login,
-- and every lookup checks that ownership -- context-window
-- compaction, and (see the tool-use section further down) a bounded
-- turn loop that can act on the platform's own data through a small,
-- explicit tool registry.
--
-- Nothing here is ever deleted. Compacting history marks old messages
-- out-of-context (in_context = 0) rather than removing them -- the
-- full conversation stays in SQL, only the live prompt sent to the
-- model shrinks.

db = require("db")
json = require("dkjson")
agent_provider = require("agent_provider")
document = require("document")
entity = require("entity")
schema = require("schema")
knowledge = require("knowledge")
auth = require("auth")
template = require("template")
config = require("config")
view = require("view")
search_provider = require("search_provider")
extension = require("extension")

agent = {}

-- Turn-budget/size constants in this file are read fresh from
-- config.platform_config() every time rather than hardcoded (see
-- doc/architecture.md's "Chat" config table for the full list and
-- defaults) -- the right value genuinely depends on deployment
-- choices (which model is configured, that provider's own latency,
-- how much data a deployment actually holds), and a slow-to-converge
-- self-check loop that runs long enough to exceed the load balancer's
-- own timeout is a real, current reason a fixed constant would be
-- wrong here.

-- Same default cgi.lua's own chat routes already use (a real model
-- name is a deployment choice, never hardcoded, read fresh from
-- config.platform_config()) -- exposed here too so main.lua's CLI
-- dispatch (`daat knowledge distill`, `daat agent
-- run-pending-background`) doesn't need its own copy of the fallback.
function agent.default_model()
    return config.platform_config().agent_model
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

-- A background.start request (see AGENT_TOOLS.background below) --
-- mirrors extension_job's own queue shape (status/attempts/last_error),
-- not agent_pending_action's: there's nothing here for a human to
-- approve/deny, just a question that needs more turns than one HTTP
-- request affords. Drained by a real, separate process (the CLI's
-- "daat agent run-pending-background", meant to be invoked
-- periodically the same way extension_job's own "daat extension
-- run-pending" already is), never inline in a chat turn.
CREATE TABLE IF NOT EXISTS agent_background_task (
    id INTEGER PRIMARY KEY %s,
    session_id TEXT NOT NULL,
    question TEXT NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    result TEXT,
    created_at TEXT DEFAULT (%s),
    updated_at TEXT DEFAULT (%s)
);
"""

function agent_schema_sql(db_path)
    return string.format(AGENT_SCHEMA,
        db.now_expr(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path), db.now_expr(db_path)
    )
end

-- Same treatment as document.lua's KNOWLEDGE_POOL_SQL_COLUMNS:
-- agent_session is hand-rolled, not schema.register()'d, so
-- entity.fields would otherwise fall through to "unknown entity type"
-- for it. agent_message/agent_pending_action/agent_background_task are
-- deliberately NOT given this treatment, even though they're just as
-- hand-rolled -- agent_message holds every chat turn's raw content
-- across every user's session, and agent_pending_action holds
-- not-yet-approved destructive tool-call arguments; view.lua's
-- run_agent_query security-boundary comment already names both as
-- tables that "must stay opaque to the model." This is a deliberate
-- exclusion, not an oversight -- do not extend this note to include them.
AGENT_SESSION_SQL_COLUMNS = {
    {name = "id", note = "primary key, VARCHAR(255)"},
    {name = "login", note = "the session's owner -- every read/write is ownership-checked against this"},
    {name = "title", note = "chat title, may be NULL until set"},
    {name = "created_at", note = "timestamp the session started"},
    {name = "updated_at", note = "timestamp of the session's last activity"},
}

function agent.session_sql_columns_text()
    lines = {}
    for _, col in ipairs(AGENT_SESSION_SQL_COLUMNS) do
        table.insert(lines, string.format("%s -- %s", col.name, col.note))
    end
    return table.concat(lines, "\n")
end

-- tool_call_id: the id for the toolCall block that produced this
-- pending action -- needed to correlate the eventual approved/denied
-- result back to it via a real toolResult message. This codebase's own
-- bookkeeping, not something Vertex's real wire protocol requires or
-- even has a concept of (functionCall/functionResponse carry no id at
-- all there -- correlation is by name instead) -- each provider
-- synthesizes one fresh per response purely so this correlation works.
-- Added via migration, not AGENT_SCHEMA, so an existing production
-- agent_pending_action table gets it without a destructive rebuild --
-- same pattern as document.lua's ensure_document_knowledge_columns.
function ensure_agent_pending_action_columns(db_path)
    existing = db.get_columns(db_path, "agent_pending_action")
    have = {}
    for _, name in ipairs(existing) do
        have[name] = true
    end
    if have["tool_call_id"] == nil then
        db.exec(db_path, "ALTER TABLE agent_pending_action ADD COLUMN tool_call_id VARCHAR(255);")
    end
end

-- Lets a human interrupt an in-progress turn loop between steps -- see
-- agent.request_cancel below. Added via migration, same pattern/reasoning
-- as ensure_agent_pending_action_columns above.
function ensure_agent_session_columns(db_path)
    existing = db.get_columns(db_path, "agent_session")
    have = {}
    for _, name in ipairs(existing) do
        have[name] = true
    end
    if have["cancel_requested"] == nil then
        db.exec(db_path, "ALTER TABLE agent_session ADD COLUMN cancel_requested INTEGER NOT NULL DEFAULT 0;")
    end
end

function agent.init_schema(db_path)
    ok, err = db.exec(db_path, agent_schema_sql(db_path))
    ensure_agent_pending_action_columns(db_path)
    ensure_agent_session_columns(db_path)
    return ok, err
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

-- Lets a human interrupt an in-progress turn loop between steps, not
-- mid-model-call -- there's no way to abort an in-flight provider
-- request from a separate process, so agent.run_turn's own loop (below)
-- only checks this at the top of each turn, before spending the next
-- model call. Ownership-checked via agent.get_session the same way
-- every other session-scoped write already is: a user can only stop
-- their own session, never someone else's by guessing a session id.
-- Mechanically this works the same way an approval decision reaches a
-- running turn today: a real, persisted flag a concurrent request writes,
-- checked by whichever process is actually looping (see cgi.lua's CGI
-- process-per-request model -- a second /api/chat-widget-stop request
-- runs in its own process while the first request's run_turn is still
-- executing, both against the same store).
function agent.request_cancel(db_path, session_id, login)
    session = agent.get_session(db_path, session_id, login)
    if session == nil then
        return false
    end
    db.exec(db_path, string.format("UPDATE agent_session SET cancel_requested = 1 WHERE id = %s;", db.quote(session_id)))
    return true
end

function agent.cancel_requested(db_path, session_id)
    rows = db.query(db_path, string.format("SELECT cancel_requested FROM agent_session WHERE id = %s;", db.quote(session_id)))
    if rows == nil or rows[1] == nil then
        return false
    end
    return tonumber(rows[1].cancel_requested) == 1
end

function agent.clear_cancel(db_path, session_id)
    db.exec(db_path, string.format("UPDATE agent_session SET cancel_requested = 0 WHERE id = %s;", db.quote(session_id)))
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

-- Uses db.exec's own second return value (last_insert_rowid()/
-- insert_id), read on the very same connection the insert itself just
-- ran on -- not a SELECT MAX(id) after the fact, which two
-- simultaneous chat-message requests could both read identically and
-- collide on (the same class of race ledger.lua's own
-- append_create/append_update guard against). Needed correctly here
-- since knowledge_context/knowledge_chat_eval key off this id
-- directly.
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

-- Records one tool's result as a real, structured tool_result message
-- -- JSON-encoded the same way an assistant row is (see
-- build_history_messages), carrying the tool_call_id/tool_name needed
-- to correlate it back to the model's own toolCall block via a real
-- toolResult message on the next turn.
function agent.add_tool_result_message(db_path, session_id, tool_call_id, tool_name, text, is_error)
    content = json.encode({tool_call_id = tool_call_id, tool_name = tool_name, text = text, is_error = is_error == true})
    return agent.add_message(db_path, session_id, "tool_result", content, true)
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

-- Renders a structured assistant reply (a decoded {blocks = [...]}
-- content value -- see build_history_messages' own comment for the
-- storage shape) into human-readable text: a text block reads as
-- itself, a thinking block (Gemini 2.5's own thought-summary output,
-- see extract_thinking_text below) as its own reasoning text -- shown
-- here, not just split out to a separate Knowledge Pool document (see
-- run_turn's own reasoning_document_id handling, which still happens in
-- parallel for search/tiering purposes; this is about what a human
-- reading the conversation sees inline).
--
-- `include_tool_calls` (default true when nil) controls a toolCall
-- block: a short "-> what ran" line when true, dropped entirely when
-- false. The false case is what agent.all_messages passes for the
-- live-facing chat view (cgi.lua's /chat and the floating widget) --
-- a tool call and its raw result are working detail the model needed,
-- not something a human reading the conversation needs inline; the
-- full record (every tool call, every raw result) is untouched in
-- agent_message and in the complete session document
-- sync_session_document keeps synced (always called with the default,
-- true). clarify.ask is the one toolCall rendered as its real payload
-- regardless of include_tool_calls -- its argument IS a real message
-- meant for the user (the question to answer), not internal plumbing;
-- showing "-> clarify.ask(...)" instead of the actual question would
-- leave the person reading the transcript with nothing to respond to.
function display_blocks(blocks, include_tool_calls)
    if blocks == nil then
        return ""
    end
    if include_tool_calls == nil then
        include_tool_calls = true
    end
    parts = {}
    for _, block in ipairs(blocks) do
        if block.type == "text" and block.text != nil then
            table.insert(parts, block.text)
        elseif block.type == "thinking" and block.thinking != nil then
            table.insert(parts, block.thinking)
        elseif block.type == "toolCall" and block.name == "clarify.ask" then
            question = nil
            if block.arguments != nil then
                question = block.arguments.question
            end
            if question == nil then
                question = "(no question given)"
            end
            table.insert(parts, question)
        elseif block.type == "toolCall" and include_tool_calls == true then
            table.insert(parts, "-> " .. tostring(block.name) .. "(...)")
        end
    end
    return table.concat(parts, "\n")
end

-- Just the real "text" blocks -- no thinking, no toolCall lines. Used
-- specifically where a caller needs to judge the model's actual answer
-- (run_self_check's own CONFIRM check), as opposed to display_blocks'
-- own job of rendering something a human should read, which rightly
-- includes thinking.
function text_only_blocks(blocks)
    if blocks == nil then
        return ""
    end
    parts = {}
    for _, block in ipairs(blocks) do
        if block.type == "text" and block.text != nil then
            table.insert(parts, block.text)
        end
    end
    return table.concat(parts, "\n")
end

-- Pulls out Gemini 2.5's own thought-summary blocks (requested via the
-- provider's own thinking config -- see agent_vertex.lua's own
-- .converse()), a real structural signal, not text-pattern matching.
-- Returns nil (not "") when there's nothing to pull, so callers can
-- tell "no thinking this turn" apart from "thinking was an empty
-- string" and fall back to the legacy text-based
-- knowledge.reply_has_visible_reasoning check for models/providers
-- that leak reasoning as plain text instead of a real block type.
function extract_thinking_text(blocks)
    if blocks == nil then
        return nil
    end
    parts = {}
    for _, block in ipairs(blocks) do
        if block.type == "thinking" and block.thinking != nil then
            table.insert(parts, block.thinking)
        end
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, "\n\n")
end

-- Cleans a message's content for DISPLAY only -- never called on what
-- active_messages/build_history_messages feeds back to the model
-- itself, which still needs the real structured blocks (or, for a
-- pre-migration row, the raw tag text) intact to make sense of its own
-- prior turns. A human reading the transcript doesn't need any of that
-- literally: a final text reply should just read as its own text, a
-- tool call as a short "-> what ran" line, and the [Current user:
-- ...]/[Current page: ...] annotations html.render_chat_widget's own
-- JS prepends to every user message (see its own comment on why every
-- message, not just the first) are there for the model, not for the
-- user to see restated back to them.
--
-- `role` picks how `content` is decoded: assistant/tool_result rows
-- store JSON (see build_history_messages); json.decode on anything
-- else (plain user text, or an older row still holding the pre-JSON
-- <done>/<tool> tag text -- nothing here is ever deleted, see this
-- file's header) simply fails to find the expected shape and falls
-- through to the legacy tag-parsing/plain-text path below, so old
-- sessions keep rendering correctly with no separate migration step
-- needed.
function agent.display_content(content, role, include_tool_calls)
    if content == nil then
        return content
    end
    content = string.gsub(content, "^%[Attached file: .-%]\n%-%-%-\n.-\n%-%-%-\n\n", "")
    content = string.gsub(content, "^%[Current user: .-%]\n", "")
    content = string.gsub(content, "^%[Current page: .-%]\n\n", "")

    if role == "assistant" then
        decoded, _, _ = json.decode(content)
        if decoded != nil and decoded.blocks != nil then
            return display_blocks(decoded.blocks, include_tool_calls)
        end
    elseif role == "tool_result" then
        decoded, _, _ = json.decode(content)
        if decoded != nil and decoded.text != nil then
            return decoded.text
        end
        return content
    end

    -- Legacy fallback: a pre-migration assistant row (or content with
    -- no role given) holding the old tag-text protocol directly.
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

-- Which session a message belongs to, so /api/chat-widget-feedback can
-- check ownership (via agent.get_session) before recording feedback --
-- without this, any authenticated user could submit feedback against
-- any message_id, not just their own conversations, just by
-- guessing/incrementing the id.
function agent.message_session_id(db_path, message_id)
    rows = db.query(db_path, string.format(
        "SELECT session_id FROM agent_message WHERE id = %d;", tonumber(message_id)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1].session_id
end

-- `include_tool_calls` (default true when nil) is the same switch
-- display_blocks takes, plus one more consequence at this level: a
-- 'tool_result' row (raw tool output) is dropped from the result
-- entirely when false, and an 'assistant' row that turns out to have no
-- visible content left after filtering (a turn that was pure tool
-- calls, nothing else) is dropped too, rather than rendering as an
-- empty bubble. Pass false for a live, human-facing view (cgi.lua's
-- /chat and the floating widget); the default (true) is the complete,
-- unfiltered record -- every row, always -- used by
-- sync_session_document's own full session-document sync. Nothing is
-- ever deleted from agent_message either way; this only changes what a
-- given caller gets back.
-- The arguments of the most recent `tool_name` toolCall block in this
-- session (nil if none yet) -- for surfacing a specific tool call's
-- real structured input to a page-specific client feature (e.g. the
-- SQL console prefilling itself from the agent's own entity.query
-- calls, see chat_widget_state). Deliberately bypasses agent.all_
-- messages/display_content/display_blocks: those intentionally
-- collapse a toolCall down to a human-readable "-> name(...)" string
-- for the widget's own transcript, discarding `arguments` entirely --
-- correct for that purpose, useless for this one. Reads raw
-- agent_message rows directly instead; nothing here changes what the
-- human-facing transcript itself ever shows.
function agent.last_tool_call_arguments(db_path, session_id, tool_name)
    rows = db.query(db_path, string.format(
        "SELECT content FROM agent_message WHERE session_id = %s AND role = 'assistant' ORDER BY id DESC;",
        db.quote(session_id)
    ))
    if rows == nil then
        return nil
    end
    for _, row in ipairs(rows) do
        decoded, _, _ = json.decode(row.content)
        if decoded != nil and decoded.blocks != nil then
            for _, block in ipairs(decoded.blocks) do
                if block.type == "toolCall" and block.name == tool_name then
                    return block.arguments
                end
            end
        end
    end
    return nil
end

-- Extracts a SQL statement from the model's own plain-text final answer --
-- for when a "write me a query" request gets answered as prose/a fenced
-- code block instead of an actual entity.query tool call (e.g. the model
-- calls entity.list_types(), then writes back
-- "```sql\nSELECT * FROM sampling\n```" as its own text, never calling
-- entity.query at all). Deliberately conservative: a fenced ```sql block
-- or a fenced block starting with a SQL keyword is trusted outright; an
-- unfenced statement is only trusted at a line start or right after
-- "...: " AND only if it also contains FROM -- avoids misfiring on prose
-- that merely mentions "select" in passing ("you can select any of the
-- options above").
function agent.extract_sql_from_text(text)
    if text == nil then
        return nil
    end
    candidate = string.match(text, "```sql%s*\n(.-)```")
    if candidate == nil then
        candidate = string.match(text, "```%s*\n%s*([Ss][Ee][Ll][Ee][Cc][Tt].-)```")
    end
    if candidate == nil then
        candidate = string.match(text, "\n%s*([Ss][Ee][Ll][Ee][Cc][Tt][^`\n]*[Ff][Rr][Oo][Mm][^`\n]*)$")
    end
    if candidate == nil then
        candidate = string.match(text, "^%s*([Ss][Ee][Ll][Ee][Cc][Tt][^`\n]*[Ff][Rr][Oo][Mm][^`\n]*)$")
    end
    if candidate == nil then
        candidate = string.match(text, ":%s*([Ss][Ee][Ll][Ee][Cc][Tt][^`\n]*[Ff][Rr][Oo][Mm][^`\n]*)$")
    end
    if candidate == nil then
        return nil
    end
    candidate = string.gsub(candidate, "^%s+", "")
    candidate = string.gsub(candidate, "%s+$", "")
    if candidate == "" then
        return nil
    end
    return candidate
end

-- The console-prefill value for a session: the most recent of either an
-- entity.query tool call's own `sql` argument, or SQL the model wrote out
-- as plain final-answer text (see agent.extract_sql_from_text) -- whichever
-- happened more recently, scanning assistant messages newest-first so a
-- later plain-text answer correctly overrides an older real tool call and
-- vice versa. Used only by chat_widget_state for the /sql console's
-- client-side prefill; every other caller wanting a specific tool's raw
-- arguments should use agent.last_tool_call_arguments instead.
function agent.last_console_query_sql(db_path, session_id)
    rows = db.query(db_path, string.format(
        "SELECT content FROM agent_message WHERE session_id = %s AND role = 'assistant' ORDER BY id DESC;",
        db.quote(session_id)
    ))
    if rows == nil then
        return nil
    end
    for _, row in ipairs(rows) do
        decoded, _, _ = json.decode(row.content)
        if decoded != nil and decoded.blocks != nil then
            for _, block in ipairs(decoded.blocks) do
                if block.type == "toolCall" and block.name == "entity.query" and block.arguments != nil and block.arguments.sql != nil then
                    return block.arguments.sql
                end
                if block.type == "text" then
                    sql = agent.extract_sql_from_text(block.text)
                    if sql != nil then
                        return sql
                    end
                end
            end
        end
    end
    return nil
end

-- True exactly for an assistant row that is a turn's real, final reply
-- -- i.e. the response run_turn (this file) accepted with no
-- toolCall block attached (stopReason "stop"/"length"), as opposed to
-- an earlier round in the same turn that narrated some text ("Let me
-- check that...") alongside a toolCall it also proposed. Both kinds
-- of row have the same `role` ("assistant") and, once narration is
-- present, both can have non-empty display text -- this is the one
-- signal that tells them apart for the chat widget (html.lua's
-- render()), so it's computed from the raw stored blocks, before
-- agent.display_content collapses them down to plain text.
function agent.assistant_message_is_final(content)
    if content == nil then
        return false
    end
    decoded, _, _ = json.decode(content)
    if decoded == nil or decoded.blocks == nil then
        return false
    end
    for _, block in ipairs(decoded.blocks) do
        if block.type == "toolCall" then
            return false
        end
    end
    return true
end

function agent.all_messages(db_path, session_id, include_tool_calls)
    if include_tool_calls == nil then
        include_tool_calls = true
    end
    rows = db.query(db_path, string.format(
        "SELECT * FROM agent_message WHERE session_id = %s ORDER BY id ASC;",
        db.quote(session_id)
    ))
    if rows == nil then
        return {}
    end
    result = {}
    for _, row in ipairs(rows) do
        if include_tool_calls == false and row.role == "tool_result" then
            -- skip: raw tool output, not for a human reading the live
            -- transcript -- see this function's own comment.
        else
            if row.role == "assistant" then
                row.is_final = agent.assistant_message_is_final(row.content)
            end
            row.content = agent.display_content(row.content, row.role, include_tool_calls)
            skip_empty_assistant = include_tool_calls == false and row.role == "assistant" and
                (row.content == nil or string.gsub(row.content, "%s", "") == "")
            if skip_empty_assistant == false then
                table.insert(result, row)
            end
        end
    end
    return result
end

--------------------------------------------------------------------------
-- Context-window compaction
--------------------------------------------------------------------------

-- A simple chars/4 heuristic, not a real tokenizer -- cheap, no
-- model-specific vocabulary to keep in sync, and only needs to be
-- roughly right (the threshold check it feeds has headroom built in,
-- not a hard model context limit).
function agent.estimate_tokens(text)
    if text == nil then
        return 0
    end
    return math.ceil(string.len(text) / 4)
end

-- Summarizes everything except the last `keep_last` active messages
-- into one new 'compaction_summary' message once the active window's
-- estimated token count crosses the threshold, then marks the
-- summarized originals in_context = 0. Never deletes anything; the
-- summary is itself just another additive message.
function agent.compact_if_needed(db_path, session_id, system_prompt, model)
    active = agent.active_messages(db_path, session_id)

    threshold = config.platform_config().agent_compaction_threshold

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
        summary_prompt = summary_prompt .. string.upper(msg.role) .. ": " .. agent.display_content(msg.content, msg.role) .. "\n"
    end

    summary, err, usage = agent_provider.generate(model, "You are a concise summarizer.", summary_prompt)
    if summary == nil or err != nil then
        return false, err
    end

    summary_message_id = agent.add_message(db_path, session_id, "compaction_summary", summary, true)
    -- A real model call, same audit-trail bar as any chat turn -- but
    -- not a knowledge_chat_eval candidate, since that table classifies
    -- conversational *replies* the user actually sees, and a
    -- compaction summary is never shown as one.
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
-- approve via a real two-phase state machine (see doc/architecture.md's
-- "Chat" section for why a blocking prompt doesn't work under CGI): a
-- destructive request is persisted as an agent_pending_action row and
-- the turn loop returns immediately; a *separate* later request
-- (agent.approve_pending/deny_pending) executes it (or records the
-- denial) and resumes the loop from there.

-- `parameters` is daat's own neutral tool-calling protocol
-- (see doc/agent-protocol.md) -- plain, standard JSON Schema, not any
-- one vendor's dialect. Each agent_provider_<name>.lua translates this
-- into whatever its own vendor actually requires on the wire (e.g.
-- agent_vertex.lua converts to Gemini's uppercase proto enum,
-- "OBJECT"/"STRING"/"INTEGER", before calling Vertex -- this file
-- never speaks that dialect directly; see agent-protocol.md for why
-- this schema is vendor-neutral rather than Vertex's own convention).
-- `additionalProperties = true` works for the open-ended "one arg per
-- field" tools (entity.create/update) -- a real Vertex call produces
-- exactly the extra fields asked for alongside the declared ones.
-- `description` here is what the model actually sees per tool
-- (replacing the old hand-written system-prompt bullet list);
-- `destructive` is unchanged, still gates the pending-approval flow
-- below.
--
-- properties = {} (a plain empty Lua table) is genuinely ambiguous to
-- dkjson.encode: it comes out as a JSON array ("[]"), not an object
-- ("{}") -- the same empty-table-encoding ambiguity that bit
-- schema.lua's own JSON columns elsewhere in this codebase. A real
-- Vertex AI call rejects the resulting {"type":"OBJECT",
-- "properties":[]} with a 400 INVALID_ARGUMENT -- every no-arg tool
-- (entity.list_types/template.list/knowledge.stats) would break every
-- real tool-calling turn merely by being *declared*, before the model
-- even chose one. dkjson's own __jsontype = "object" metatable marker
-- forces object encoding regardless of emptiness -- this is a dkjson
-- serialization quirk, not a Vertex-specific concern, so it stays
-- regardless of which provider's translation runs afterward.
EMPTY_OBJECT_SCHEMA = {type = "object", properties = setmetatable({}, {__jsontype = "object"})}

function agent.is_known_tool(db_path, tool_name, method_name)
    agent_tools = require("agent_tools")
    group = agent_tools.AGENT_TOOLS[tool_name]
    if group != nil then
        return group[method_name] != nil
    end
    manifest, tool = agent_tools.find_extension_tool(db_path, tool_name, method_name)
    return tool != nil
end

function agent.is_destructive(db_path, tool_name, method_name)
    agent_tools = require("agent_tools")
    group = agent_tools.AGENT_TOOLS[tool_name]
    if group != nil then
        if group[method_name] == nil then
            return false
        end
        return group[method_name].destructive == true
    end
    manifest, tool = agent_tools.find_extension_tool(db_path, tool_name, method_name)
    if tool == nil then
        return false
    end
    return tool.destructive == true
end

-- Flattens AGENT_TOOLS into the function-declaration list the real
-- Vertex/Gemini function-calling API expects -- one entry per method,
-- named "toolname.methodname" (dots are valid in a Gemini function
-- name) so agent.execute_tool's own tool_name/method_name
-- split-on-dot dispatch needs no remapping table at all in either
-- direction. Approved extension tools are appended the same way, under
-- their own manifest.name, so the model sees them with no
-- special-casing on the provider side.
function agent.tool_declarations(db_path)
    agent_tools = require("agent_tools")
    declarations = {}
    for tool_name, methods in pairs(agent_tools.AGENT_TOOLS) do
        for method_name, spec in pairs(methods) do
            table.insert(declarations, {
                name = tool_name .. "." .. method_name,
                description = spec.description,
                parameters = spec.parameters,
            })
        end
    end
    for _, entry in ipairs(extension.approved_with_tools(db_path, config.extensions_dir())) do
        for _, tool in ipairs(entry.manifest.capabilities.tools) do
            table.insert(declarations, {
                name = entry.name .. "." .. tool.name,
                description = tool.description,
                parameters = tool.parameters,
            })
        end
    end
    return declarations
end

function agent.create_pending_action(db_path, session_id, tool_name, method_name, args, tool_call_id)
    db.exec(db_path, string.format(
        "INSERT INTO agent_pending_action (session_id, tool, method, args_json, tool_call_id) VALUES (%s, %s, %s, %s, %s);",
        db.quote(session_id), db.quote(tool_name), db.quote(method_name), db.quote(json.encode(args)), db.literal(tool_call_id)
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

-- Builds the real, structured message list agent_provider.converse
-- sends to the model (this codebase's own canonical shape -- see
-- doc/agent-protocol.md, and agent_vertex.lua's own header
-- for how a provider translates it to/from its real wire format) from
-- this session's agent_message rows.
--
-- assistant/tool_result rows store JSON (see agent.add_message's
-- callers below and agent.add_tool_result_message) -- decoded back
-- into real content blocks / a toolResult message here. A row that
-- fails to decode into the expected shape is an older row still
-- holding the pre-JSON <done>/<tool> tag text (nothing here is ever
-- deleted): degraded gracefully rather than dropped -- an old assistant
-- reply becomes a single text block (via agent.display_content's own
-- legacy-tag rendering), an old tool_result becomes a plain user-role
-- note, since Gemini's own toolResult message requires a toolCallId to
-- correlate against a prior toolCall that an old row never had.
function build_history_messages(messages)
    result = {}
    for _, msg in ipairs(messages) do
        if msg.role == "user" then
            table.insert(result, {role = "user", content = msg.content})
        elseif msg.role == "compaction_summary" then
            table.insert(result, {role = "user", content = "[COMPACTED HISTORY SUMMARY]:\n" .. msg.content})
        elseif msg.role == "assistant" then
            decoded, _, _ = json.decode(msg.content)
            if decoded != nil and decoded.blocks != nil then
                table.insert(result, {role = "assistant", content = decoded.blocks})
            else
                table.insert(result, {role = "assistant", content = {{type = "text", text = agent.display_content(msg.content, "assistant")}}})
            end
        elseif msg.role == "tool_result" then
            decoded, _, _ = json.decode(msg.content)
            if decoded != nil and decoded.text != nil then
                table.insert(result, {
                    role = "toolResult",
                    toolCallId = decoded.tool_call_id,
                    toolName = decoded.tool_name,
                    content = {{type = "text", text = decoded.text}},
                    isError = decoded.is_error == true,
                })
            else
                table.insert(result, {role = "user", content = "[Prior tool result]: " .. tostring(msg.content)})
            end
        elseif msg.role == "self_check" then
            -- Fed back as a user turn (Gemini's own wire protocol
            -- strictly alternates user/model turns -- there's no third
            -- "aside" role to inject mid-conversation), but explicitly
            -- marked as automated, not the real person. This genuinely
            -- matters: without the marker, a model facing several of
            -- these in a row (a slow-to-converge self-check loop) starts
            -- reading its own prior critiques as if the real user kept
            -- repeating things back to it ("I'm stuck in a loop, the
            -- user keeps confirming..."), spiraling into confused,
            -- self-referential reasoning about a back-and-forth that
            -- never actually happened -- which makes the loop take
            -- *longer* to converge, not shorter, and risks running past
            -- the load balancer's own timeout as a result.
            table.insert(result, {role = "user", content = "[Automated self-check, not the real user -- your own prior reply was just reviewed against the conversation and found lacking. The note below is that review, not new information from the person you're talking to; read it as your own continued investigation, then act on it.]\n\n" .. msg.content})
        end
    end
    return result
end

-- Every toolCall block in a reply, in the order the model proposed
-- them -- Gemini/Vertex can and does emit more than one per turn, and
-- every one needs to actually run to get a real result: multi-step
-- reasoning in a single turn depends on none of them being silently
-- dropped.
function all_tool_calls(blocks)
    if blocks == nil then
        return {}
    end
    calls = {}
    for _, block in ipairs(blocks) do
        if block.type == "toolCall" then
            table.insert(calls, block)
        end
    end
    return calls
end

-- AGENT_TOOLS' own function-declaration names are always "tool.method"
-- (see agent.tool_declarations()) with no dots anywhere else in either
-- half, so splitting on the first dot is exact, not a heuristic.
function split_tool_name(dotted_name)
    if dotted_name == nil then
        return nil, nil
    end
    dot = string.find(dotted_name, ".", 1, true)
    if dot == nil then
        return nil, nil
    end
    return string.sub(dotted_name, 1, dot - 1), string.sub(dotted_name, dot + 1)
end

SELF_CHECK_PROMPT = """
[Automated self-check, not the real user.] Before this reply is sent to the user, check it against the conversation and tool results above:
- Is every factual claim directly supported by a tool result you actually gathered, not assumed or guessed?
- If your answer concludes zero, none, or "not found", did you verify the underlying values genuinely don't exist (e.g. a broader search, or checking the value exists at all independent of the specific query/filter you used) rather than trusting a single query or lookup that could itself have been wrong?
- Is there an obvious next check you skipped that would meaningfully change or confirm the answer?
- Was the original request genuinely ambiguous, or missing information you couldn't reasonably infer or look up yourself -- and if so, should this have been a clarify.ask instead of a guess?
- Does the reply print any raw internal/database id (a numeric entity id, a foreign-key value) the user never asked for, instead of the entity's real name/label?
- If it summarizes multiple records, does it lead with a genuine takeaway, or does it just repeat the same shared fields once per record with no real synthesis?

If the reply holds up, respond with EXACTLY: CONFIRM
Otherwise, do not repeat the reply -- just say what to check next, as if continuing your own investigation.
"""

TURN_LIMIT_WRAPUP_PROMPT = """
[Automated: you've used your entire step budget for this task without reaching a final answer.] Write a short status update for the user, in your own words:
- What you were trying to find or do, and what you've actually confirmed or ruled out so far -- cite real values from your own tool results above, not vague generalities.
- Say plainly whether your approach so far was on track and just needs more steps, or whether -- on reflection -- a different approach would get there faster (e.g. one aggregate query instead of paging through rows one batch at a time). The user can't judge this from the raw tool history alone; your own assessment is what lets them decide.
- End with a direct question: continue as-is, or take a different approach?
Do not call any tools -- this is a plain text reply only, and no tool call would run even if you proposed one.
"""

STOP_REQUESTED_WRAPUP_PROMPT = """
[Automated: the user asked you to stop before you gave a final answer.] Write a short status update for the user, in your own words: what you were trying to find or do, and what you've actually confirmed or ruled out so far -- cite real values from your own tool results above, not vague generalities. Do not call any tools -- this is a plain text reply only, and no tool call would run even if you proposed one.
"""

-- Spends one more no-tools model call (same shape as run_self_check's
-- own) to have the model explain, in its own words, where an
-- interrupted investigation actually got to -- shared by both ways
-- agent.run_turn's loop can end without a real answer: the turn budget
-- running out, and the user hitting Stop mid-session. A canned string
-- can only ever say "I didn't finish"; the model that did the work is
-- the one that can say whether it was on the right track, which is what
-- the user actually needs to decide whether to let it continue.
-- `prompt_text` frames why the loop is stopping (see the two prompts
-- above); `fallback_text` is what gets persisted if this call itself
-- fails -- fails open, same reasoning as run_self_check's own comment:
-- there's no budget left to retry, so a plain honest message beats
-- silence.
function run_turn_wrapup(db_path, session_id, login, system_prompt, model, prompt_text, fallback_text)
    wrapup_history = build_history_messages(agent.active_messages(db_path, session_id))
    table.insert(wrapup_history, {role = "user", content = prompt_text})
    wrapup_audit_prompt = json.encode(wrapup_history)
    wrapup_response, wrapup_err, wrapup_usage = agent_provider.converse(model, system_prompt, wrapup_history, {})

    message_text = nil
    if wrapup_response != nil and wrapup_response.stopReason != "error" and wrapup_response.stopReason != "aborted" then
        wrapup_blocks = wrapup_response.content
        if wrapup_blocks == nil then
            wrapup_blocks = {}
        end
        message_text = display_blocks(wrapup_blocks)
    end
    if message_text == nil or string.gsub(message_text, "%s", "") == "" then
        message_text = fallback_text
    end

    message_id = agent.add_message(db_path, session_id, "assistant", json.encode({blocks = {{type = "text", text = message_text}}}), true)
    context_id = knowledge.record_context(db_path, session_id, message_id, wrapup_audit_prompt, model, nil, wrapup_usage)
    knowledge.record_chat_eval(db_path, session_id, context_id, message_id, agent_provider.name(), model, false, message_text)
    return message_text
end

-- A structural, code-enforced verification step, not a prompt
-- reminder -- runs on every proposed final answer, unconditionally.
-- Generalizes across any class of premature-answer mistake (a wrong
-- guess taken at face value, an unverified zero/not-found conclusion,
-- a skipped obvious next step) instead of hardcoding a fix for one
-- specific mistake (e.g. the model guessing a plain-English plural
-- table name for entity.query without checking first) -- the fix
-- isn't "detect plural guesses," it's "always double-check your own
-- conclusion before it goes out," which catches that and any other
-- class of mistake the same way, because it's judged by the same
-- reasoning engine, not a hardcoded pattern list. Reuses the exact
-- message history the real turn already built, plus one more
-- directive message, so the critique sees everything the original
-- answer saw -- no separate context to keep in sync.
--
-- Fails OPEN, not closed: if the critique call itself errors (bridge/
-- network issue), this returns true (confirmed) so the user's real
-- answer still goes out rather than being blocked on a meta-check
-- that couldn't run -- a self-check infrastructure hiccup should never
-- leave the user worse off than no self-check at all.
--
-- Returns true (answer confirmed, safe to return to the user) or
-- false (a "self_check" message has been recorded with what to check
-- next; the turn loop should continue instead of returning).
function run_self_check(db_path, session_id, system_prompt, model, active_messages)
    history_messages = build_history_messages(active_messages)
    table.insert(history_messages, {role = "user", content = SELF_CHECK_PROMPT})
    audit_prompt = json.encode(history_messages)

    response, err, usage = agent_provider.converse(model, system_prompt, history_messages, {})
    if response == nil or response.stopReason == "error" or response.stopReason == "aborted" then
        return true
    end

    content_blocks = response.content
    if content_blocks == nil then
        content_blocks = {}
    end
    critique_text = display_blocks(content_blocks)
    -- The verdict must be judged from the model's real answer alone,
    -- not from display_blocks' combined text (which includes thinking,
    -- so a human reading a self-check's own critique can see its
    -- reasoning, not just its verdict) -- thinking text narrated ahead
    -- of a literal "CONFIRM" answer would otherwise mean the combined
    -- string no longer starts with "confirm", so the anchor check below
    -- would never match and a genuinely confirmed answer would loop for
    -- the full MAX_TURNS budget instead. text_only_blocks strips
    -- thinking back out for this one check, while critique_text
    -- (thinking included) is still what actually gets stored/shown when
    -- a self-check finds something worth saying.
    answer_text = text_only_blocks(content_blocks)
    trimmed = string.gsub(answer_text, "^%s+", "")

    if string.find(string.lower(trimmed), "^confirm") != nil then
        -- Deliberately not audited via knowledge.record_context here --
        -- a confirm produces no new message and changes nothing, so
        -- there's no real event for an audit row to attach to; adding
        -- one anyway would shift "the most recent context row" away
        -- from the actual reply for any other code (or human) that
        -- reasonably assumes that row explains the latest real turn.
        -- A self-check that actually finds something to say (below)
        -- creates a real message, and gets a real audit row tied to it.
        return true
    end

    message_id = agent.add_message(db_path, session_id, "self_check", critique_text, true)
    knowledge.record_context(db_path, session_id, message_id, audit_prompt, model, nil, usage)
    return false
end

RESEARCH_SYSTEM_PROMPT = """
You are a focused research sub-agent helping answer one specific sub-question
using this deployment's own data. You have read-only tools only. Explore from
more than one angle before concluding something doesn't exist -- check
entity.relationships for a join path, not just a direct field, when a value
isn't where you first expected it; retry entity.query a different way before
trusting an empty result. A tool call that returns an ERROR is not the same
as an empty result -- it means the call itself was malformed (wrong field
name, wrong entity type, bad SQL), not that the data is missing. Read the
error message, check entity.fields/entity.list_types/entity.relationships if
the schema is what you got wrong, and retry the same tool with corrected
usage before ever concluding something doesn't exist; only a call that
actually succeeded with zero rows is real evidence of absence. If the
question is about many discrete items (a list, "every X", "across all N
experiments/entities"), track exactly how many you actually checked and say
so in your finding ("checked 12 of 44") -- a
conclusion generalized from a partial sample is a different, weaker claim
than one actually checked exhaustively, and stating the first as if it were
the second is worse than honestly running out of turns. When you're done,
reply with a concise, grounded finding -- the specific answer plus enough of
what you found (counts, ids, values) that someone could verify it -- not a
raw dump of every row. If real exploration genuinely turns up nothing, say
that plainly along with what you tried, rather than guessing.
"""

-- A disposable, isolated tool-calling loop for one focused sub-question
-- -- the actual "research" tool implementation (see AGENT_TOOLS.research
-- .investigate). Deliberately keeps its own in-memory message list
-- rather than writing anything to agent_message: the wrong-turn/
-- wrong-query noise a real investigation produces along the way is
-- exactly what shouldn't count against the main conversation's own
-- self-check (which judges the final answer against what's actually in
-- its context) or its compaction budget -- only the synthesized finding
-- returned below ever becomes part of the real session, as this tool
-- call's own tool_result message.
--
-- `max_turns` defaults to the agent_research_max_turns-configurable
-- bound (the interactive research.investigate tool's own budget) when
-- nil -- the background worker (agent.run_pending_background_tasks)
-- reuses this same loop with a looser, separately-configurable
-- agent_background_max_turns budget instead, since it isn't bound to
-- one HTTP request's lifetime the way an inline tool call is.
function agent.run_research_loop(db_path, author, session_id, model, question, max_turns)
    agent_tools = require("agent_tools")
    if max_turns == nil then
        max_turns = config.platform_config().agent_research_max_turns
    end
    messages = {{role = "user", content = question}}
    tools = agent_tools.research_tool_declarations(db_path)
    last_text = nil

    for turn = 1, max_turns do
        response, err, usage = agent_provider.converse(model, RESEARCH_SYSTEM_PROMPT, messages, tools)
        if response == nil then
            if last_text != nil then
                return "(research stopped early: " .. tostring(err) .. ") " .. last_text
            end
            return nil, "research failed: " .. tostring(err)
        end
        if response.stopReason == "error" or response.stopReason == "aborted" then
            error_message = response.errorMessage
            if error_message == nil then
                error_message = "model call failed (stopReason: " .. tostring(response.stopReason) .. ")"
            end
            if last_text != nil then
                return "(research stopped early: " .. tostring(error_message) .. ") " .. last_text
            end
            return nil, "research failed: " .. tostring(error_message)
        end

        content_blocks = response.content
        if content_blocks == nil then
            content_blocks = {}
        end
        table.insert(messages, {role = "assistant", content = content_blocks})
        last_text = display_blocks(content_blocks)

        tool_calls = all_tool_calls(content_blocks)
        if #tool_calls == 0 then
            return last_text
        end

        for _, tool_call in ipairs(tool_calls) do
            if tool_call.arguments == nil then
                tool_call.arguments = {}
            end
            tool_name, method_name = split_tool_name(tool_call.name)
            result_text = nil
            is_error = false
            if tool_name == nil or not agent.is_known_tool(db_path, tool_name, method_name) then
                result_text = "ERROR: unknown tool " .. tostring(tool_call.name)
                is_error = true
            elseif agent.is_destructive(db_path, tool_name, method_name) or tool_name == "research" or tool_name == "clarify" or tool_name == "background" then
                result_text = "ERROR: research is read-only and can't ask the user directly or hand off further -- cannot perform destructive actions, delegate further, ask a clarifying question, or start a background task; report what you've found (including any real ambiguity) instead"
                is_error = true
            else
                tool_result, tool_err = agent_tools.execute_tool(db_path, author, session_id, tool_name, method_name, tool_call.arguments)
                result_text = tostring(tool_result)
                if tool_err != nil then
                    result_text = "ERROR: " .. tostring(tool_err)
                    is_error = true
                end
            end
            table.insert(messages, {
                role = "toolResult", toolCallId = tool_call.id, toolName = tool_call.name,
                content = {{type = "text", text = result_text}}, isError = is_error,
            })
        end
    end

    if last_text == nil then
        return "(research exceeded its turn budget with no finding)"
    end
    return "(research exceeded its turn budget -- last, possibly incomplete, finding) " .. last_text
end

--------------------------------------------------------------------------
-- Background tasks (background.start / background.status)
--------------------------------------------------------------------------
--
-- A real async job queue, same shape as extension_job (status/attempts/
-- last_error, drained by a separate periodically-invoked process) --
-- not agent_pending_action's approve/deny shape, since there's nothing
-- for a human to approve here, just a question that needs more turns
-- than one HTTP request affords.

function agent.enqueue_background_task(db_path, session_id, question)
    db.exec(db_path, string.format(
        "INSERT INTO agent_background_task (session_id, question) VALUES (%s, %s);",
        db.quote(session_id), db.quote(question)
    ))
    rows = db.query(db_path, "SELECT MAX(id) AS id FROM agent_background_task;")
    return tonumber(rows[1].id)
end

-- No ownership check here (unlike agent.get_pending_action) -- callers
-- that expose this to a user-facing request (background.status, in
-- agent.execute_tool) are responsible for checking task.session_id
-- against their own current session themselves, since this is also used
-- by the worker (agent.run_pending_background_tasks), which has no
-- "current session" of its own at all.
function agent.get_background_task(db_path, task_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM agent_background_task WHERE id = %d;", tonumber(task_id)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

function agent.pending_background_tasks(db_path, limit)
    if limit == nil then
        limit = 10
    end
    rows = db.query(db_path, string.format(
        "SELECT * FROM agent_background_task WHERE status = 'pending' AND attempts < %d ORDER BY id ASC LIMIT %d;",
        config.platform_config().agent_background_max_attempts, limit
    ))
    if rows == nil then
        return {}
    end
    return rows
end

function agent.mark_background_task_done(db_path, task, result)
    db.exec(db_path, string.format(
        "UPDATE agent_background_task SET status = 'done', result = %s, updated_at = %s WHERE id = %d;",
        db.quote(result), db.now_expr(db_path), tonumber(task.id)
    ))
end

-- Same retry convention as extension.mark_job_failed: stays 'pending'
-- (so it's retried) until it has failed agent_background_max_attempts
-- times, at which point it moves to 'failed' and is no longer picked
-- up -- one broken task never blocks or affects any other.
function agent.mark_background_task_failed(db_path, task, message)
    attempts = tonumber(task.attempts) + 1
    status = "pending"
    if attempts >= config.platform_config().agent_background_max_attempts then
        status = "failed"
    end
    db.exec(db_path, string.format(
        "UPDATE agent_background_task SET status = %s, attempts = %d, last_error = %s, updated_at = %s WHERE id = %d;",
        db.quote(status), attempts, db.quote(message), db.now_expr(db_path), tonumber(task.id)
    ))
end

-- Which real login a session belongs to, with no ownership check of its
-- own -- unlike agent.get_session (an HTTP-request-scoped security
-- boundary), this is for the background worker below, which runs as a
-- system/cron process with no authenticated "current user" of its own;
-- it exists purely so a resumed task can still be attributed to the
-- same real login the original chat session belongs to, exactly as if
-- that user's own turn had just kept running.
function agent.session_login(db_path, session_id)
    rows = db.query(db_path, string.format(
        "SELECT login FROM agent_session WHERE id = %s;", db.quote(session_id)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1].login
end

-- Drains pending agent_background_task rows (oldest first, up to
-- `limit`), same "run, mark done/failed, one row's failure never
-- affects another" shape as entity.run_pending_jobs. Meant to be
-- invoked periodically by whatever the deployer already uses for
-- scheduled tasks (cron/systemd timer) -- platform is a one-shot CGI/CLI
-- process, so there's no long-lived place inside it to run this on a
-- timer itself; see "daat agent run-pending-background" in main.lua.
-- A finished task's finding is appended to its own session as a new
-- assistant message -- not routed back through agent.run_turn, since
-- the outer turn that started it already returned its own answer to the
-- user; this is a new, independent event, not a resumption of a paused
-- one (contrast agent.approve_pending/deny_pending, which genuinely
-- resume a paused turn).
function agent.run_pending_background_tasks(db_path, model, limit)
    agent_tools = require("agent_tools")
    ran = 0
    failed = 0
    for _, task in ipairs(agent.pending_background_tasks(db_path, limit)) do
        login = agent.session_login(db_path, task.session_id)
        if login == nil then
            agent.mark_background_task_failed(db_path, task, "session no longer exists")
            failed = failed + 1
        else
            finding, err = agent.run_research_loop(db_path, login, task.session_id, model, task.question,
                config.platform_config().agent_background_max_turns)
            if finding == nil then
                agent.mark_background_task_failed(db_path, task, tostring(err))
                failed = failed + 1
            else
                agent.mark_background_task_done(db_path, task, finding)
                message_text = "Background research finished: " .. finding
                agent.add_message(db_path, task.session_id, "assistant",
                    json.encode({blocks = {{type = "text", text = message_text}}}), true)
                agent_tools.sync_session_document(db_path, login, task.session_id)
                ran = ran + 1
            end
        end
    end
    return {ran = ran, failed = failed}
end

-- Runs the turn loop starting from the session's current active-message
-- state. `user_message`, if given, is recorded as a new user turn
-- before the loop starts; pass nil when resuming after a tool
-- approval/denial -- the loop just continues from whatever's already
-- in the active history. Returns a table:
--   {status = "done", message = "..."}
--   {status = "pending_approval", pending_id = N, tool = "...", method = "...", args = {...}}
--   {status = "turn_limit", message = "..."}
--   {status = "stopped", message = "..."} -- see agent.request_cancel
--   {status = "error", message = "..."}
--
-- Each call gets its own fresh turn budget (agent_max_turns, see
-- config.platform_config()), even a resume after a pause -- deliberate, not an
-- oversight: the approval pause is itself a human circuit breaker, so
-- restarting the budget on resume doesn't reopen an unbounded-loop risk
-- the way it would in a fully autonomous run with no pauses at all.
function agent.run_turn(db_path, session_id, login, system_prompt, model, user_message)
    agent_tools = require("agent_tools")
    if system_prompt == nil or system_prompt == "" then
        system_prompt = agent_tools.default_system_prompt()
    end

    if user_message != nil and user_message != "" then
        agent.add_message(db_path, session_id, "user", user_message, true)
        agent.maybe_set_title_from_message(db_path, session_id, login, user_message)
    end

    agent.compact_if_needed(db_path, session_id, system_prompt, model)

    -- Deliberately NOT cleared here at function start: the widget only
    -- ever shows a Stop button while a send is actually in flight, and a
    -- click lands as a genuinely concurrent second request (see
    -- cgi.lua's own comment on chat-widget-stop) -- it can beat this
    -- call past its own session lookup/config read and land before the
    -- loop below gets to check for it even once. Clearing the flag here
    -- unconditionally would silently swallow exactly that click. The
    -- loop's own check just below is what actually consumes the flag
    -- (checked, then cleared, every time it's found set) -- that's the
    -- only place a stale flag can ever survive past.
    max_turns = config.platform_config().agent_max_turns
    for turn = 1, max_turns do
        if agent.cancel_requested(db_path, session_id) == true then
            agent.clear_cancel(db_path, session_id)
            stop_message = run_turn_wrapup(db_path, session_id, login, system_prompt, model, STOP_REQUESTED_WRAPUP_PROMPT,
                "Stopped at your request. Whatever I found along the way is visible above in the tool call history.")
            agent_tools.sync_session_document(db_path, login, session_id)
            return {status = "stopped", message = stop_message}
        end

        active = agent.active_messages(db_path, session_id)
        history_messages = build_history_messages(active)
        audit_prompt = json.encode(history_messages)

        response, err, usage = agent_provider.converse(model, system_prompt, history_messages, agent.tool_declarations(db_path))
        if response == nil then
            -- Persisted, not just returned -- so a provider failure is
            -- never silently invisible: without a recorded row, the
            -- turn would just vanish with no trace in the transcript
            -- for any call site (chat-message, chat-widget-send/
            -- approve/deny) that doesn't happen to inspect this
            -- specific return value.
            error_message_id = agent.add_message(db_path, session_id, "tool_result", "ERROR: " .. tostring(err), true)
            -- Still recorded even on failure -- what was actually sent
            -- is exactly as much an audit fact as what came back, and
            -- usage/reasoning simply don't apply here.
            context_id = knowledge.record_context(db_path, session_id, error_message_id, audit_prompt, model, nil, nil)
            knowledge.record_chat_eval(db_path, session_id, context_id, error_message_id, agent_provider.name(), model, true, nil)
            return {status = "error", message = tostring(err)}
        end

        -- A connectivity-level infrastructure failure (nil response,
        -- handled above) is distinct from the LLM call itself failing
        -- (auth, rate limit, a malformed request) -- the provider
        -- surfaces the latter as a real, structured reply with
        -- stopReason "error"/"aborted" rather than an exception (see
        -- agent_vertex.lua's own .converse() comment); treated
        -- the same way as a connectivity failure from run_turn's own
        -- perspective, since either way there's no usable reply to act
        -- on this turn.
        if response.stopReason == "error" or response.stopReason == "aborted" then
            error_message = response.errorMessage
            if error_message == nil then
                error_message = "model call failed (stopReason: " .. tostring(response.stopReason) .. ")"
            end
            error_message_id = agent.add_message(db_path, session_id, "tool_result", "ERROR: " .. tostring(error_message), true)
            context_id = knowledge.record_context(db_path, session_id, error_message_id, audit_prompt, model, nil, usage)
            knowledge.record_chat_eval(db_path, session_id, context_id, error_message_id, agent_provider.name(), model, true, nil)
            return {status = "error", message = tostring(error_message)}
        end

        content_blocks = response.content
        if content_blocks == nil then
            content_blocks = {}
        end
        message_id = agent.add_message(db_path, session_id, "assistant", json.encode({blocks = content_blocks}), true)
        display_text = display_blocks(content_blocks)

        -- Persist the exact prompt/reasoning/tokens for this turn (see
        -- doc/architecture.md's "Knowledge pool" section, "Full
        -- prompt/reasoning/token persistence"). Real thinking content
        -- (Gemini 2.5's own thought-summary blocks, see
        -- extract_thinking_text) gets split out into its own document
        -- (source_type='reasoning', a real document under the
        -- Knowledge Pool folder, not a separate table) -- it then goes
        -- through the same tiering/retrieval/decay pipeline as every
        -- other pool document, rather than sitting in a second,
        -- parallel log only this table can see. Falls back to the
        -- legacy text-pattern check (knowledge.reply_has_visible_
        -- reasoning) only when there's no real thinking block at all
        -- -- some other provider/model might still leak reasoning as
        -- plain text instead of a real structured block.
        reasoning_document_id = nil
        thinking_text = extract_thinking_text(content_blocks)
        if thinking_text != nil then
            reasoning_document_id = knowledge.create_document_note(db_path, login,
                "Chat reasoning (session " .. tostring(session_id) .. ")", thinking_text,
                "reasoning", message_id, tostring(session_id))
        elseif knowledge.reply_has_visible_reasoning(display_text) then
            reasoning_document_id = knowledge.create_document_note(db_path, login,
                "Chat reasoning (session " .. tostring(session_id) .. ")", display_text,
                "reasoning", message_id, tostring(session_id))
        end
        context_id = knowledge.record_context(db_path, session_id, message_id, audit_prompt, model, reasoning_document_id, usage)
        knowledge.record_chat_eval(db_path, session_id, context_id, message_id, agent_provider.name(), model, false, display_text)

        tool_calls = all_tool_calls(content_blocks)
        if #tool_calls == 0 then
            -- A plain reply (stopReason "stop"/"length") is a PROPOSED
            -- final answer -- the provider's own stopReason already
            -- distinguishes "the model wants to call a tool" (toolUse)
            -- from "the model is finished" (stop/length), but
            -- "finished" isn't the same as "correct." run_self_check
            -- gets one more real turn to verify it before it actually
            -- goes out -- skipped only on the very last allowed turn,
            -- where there's no budget left to act on a critique anyway,
            -- so a real answer shouldn't be downgraded into a generic
            -- turn-limit failure instead.
            confirmed = true
            if turn < max_turns then
                active_after_answer = agent.active_messages(db_path, session_id)
                confirmed = run_self_check(db_path, session_id, system_prompt, model, active_after_answer)
            end
            if confirmed == true then
                agent_tools.sync_session_document(db_path, login, session_id)
                return {status = "done", message = display_text}
            end
        else
            -- Every non-destructive call in this turn runs now, in the
            -- order proposed -- real parallel-tool-call support (see
            -- all_tool_calls' own comment). At most one destructive call
            -- can still pause for approval per turn: the pending-approval
            -- state machine (agent_pending_action) only tracks one
            -- outstanding action per session, so the first destructive
            -- call found pauses the whole turn same as before; any
            -- destructive call after it gets an explicit "skipped" result
            -- instead of being silently dropped, so every call the model
            -- made still gets a real, visible outcome to react to.
            -- clarify.ask is handled the same "first one wins" way, but
            -- checked ahead of pending_call below: asking the user
            -- something is the safer default over auto-pausing a write
            -- proposed in the same breath, on the rare turn that proposes
            -- both.
            pending_call = nil
            clarify_call = nil
            for _, tool_call in ipairs(tool_calls) do
                if tool_call.arguments == nil then
                    tool_call.arguments = {}
                end
                tool_name, method_name = split_tool_name(tool_call.name)
                if tool_name == nil or not agent.is_known_tool(db_path, tool_name, method_name) then
                    agent.add_tool_result_message(db_path, session_id, tool_call.id, tool_call.name,
                        "ERROR: unknown tool " .. tostring(tool_call.name), true)
                elseif tool_name == "clarify" and method_name == "ask" then
                    if clarify_call == nil then
                        clarify_call = tool_call
                        agent.add_tool_result_message(db_path, session_id, tool_call.id, tool_call.name,
                            "Waiting for the user's answer before continuing.", false)
                    else
                        agent.add_tool_result_message(db_path, session_id, tool_call.id, tool_call.name,
                            "ERROR: skipped -- only one clarifying question can be asked per turn", true)
                    end
                elseif agent.is_destructive(db_path, tool_name, method_name) then
                    if pending_call == nil then
                        pending_call = {tool_call = tool_call, tool_name = tool_name, method_name = method_name}
                    else
                        agent.add_tool_result_message(db_path, session_id, tool_call.id, tool_call.name,
                            "ERROR: skipped -- only one destructive action can be proposed per turn; resolve the pending one first, then ask for this one again", true)
                    end
                else
                    tool_result, tool_err = agent_tools.execute_tool(db_path, login, session_id, tool_name, method_name, tool_call.arguments)
                    summary = tostring(tool_result)
                    is_error = false
                    if tool_err != nil then
                        summary = "ERROR: " .. tostring(tool_err)
                        is_error = true
                    end
                    agent.add_tool_result_message(db_path, session_id, tool_call.id, tool_call.name, summary, is_error)
                end
            end

            if clarify_call != nil then
                -- No self-check here (there's no answer yet to critique)
                -- and no agent_pending_action row -- unlike a destructive
                -- call, there's nothing to later approve/deny; the user's
                -- own next chat message is the answer, and the ordinary
                -- /chat-message flow already continues this same turn
                -- loop from active_messages, no special resume path
                -- needed.
                question = nil
                if clarify_call.arguments != nil then
                    question = clarify_call.arguments.question
                end
                agent_tools.sync_session_document(db_path, login, session_id)
                return {status = "needs_clarification", message = question}
            end

            if pending_call != nil then
                pending_id = agent.create_pending_action(db_path, session_id, pending_call.tool_name, pending_call.method_name,
                    pending_call.tool_call.arguments, pending_call.tool_call.id)
                agent_tools.sync_session_document(db_path, login, session_id)
                return {status = "pending_approval", pending_id = pending_id, tool = pending_call.tool_name,
                    method = pending_call.method_name, args = pending_call.tool_call.arguments}
            end
        end
    end

    -- Found live: /api/chat-widget-send calls agent.run_turn and discards
    -- what it returns, so a turn-limit outcome that only lived in this
    -- function's own result table was completely invisible in the chat
    -- widget -- the loop's last tool result just sat there with nothing
    -- after it, no error, no partial answer, nothing. Every other exit
    -- path already writes a real, persisted assistant message; this one
    -- now does too, via run_turn_wrapup -- which also doubles as the
    -- explicit "continue?" question needed for a plain chat reply to
    -- resume the same investigation with a fresh budget (see this
    -- function's own header comment on resume-gets-a-fresh-budget).
    turn_limit_message = run_turn_wrapup(db_path, session_id, login, system_prompt, model, TURN_LIMIT_WRAPUP_PROMPT,
        "I wasn't able to finish answering this within the allotted number of steps (" .. tostring(max_turns) ..
        " tool-assisted turns). Whatever I found along the way is visible above in the tool call history -- " ..
        "reply and I'll pick up where I left off, or redirect me to a different approach.")
    agent_tools.sync_session_document(db_path, login, session_id)
    return {status = "turn_limit", message = turn_limit_message}
end

-- Executes an approved pending action, records its result, and resumes
-- the turn loop from there.
function agent.approve_pending(db_path, pending_id, login, system_prompt, model)
    agent_tools = require("agent_tools")
    pending = agent.get_pending_action(db_path, pending_id, login)
    if pending == nil then
        return nil, "no such pending action"
    end
    if pending.status != "pending" then
        return nil, "action already " .. tostring(pending.status)
    end

    args, _, _ = json.decode(pending.args_json)
    if args == nil then
        args = {}
    end

    tool_result, tool_err = agent_tools.execute_tool(db_path, login, pending.session_id, pending.tool, pending.method, args)
    summary = tostring(tool_result)
    is_error = false
    if tool_err != nil then
        summary = "ERROR: " .. tostring(tool_err)
        is_error = true
    end
    agent.add_tool_result_message(db_path, pending.session_id, pending.tool_call_id, pending.tool .. "." .. pending.method, summary, is_error)
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

    agent.add_tool_result_message(db_path, pending.session_id, pending.tool_call_id, pending.tool .. "." .. pending.method, "User denied execution of this action.", true)
    agent.resolve_pending_action(db_path, pending_id, "denied")

    return agent.run_turn(db_path, pending.session_id, login, system_prompt, model, nil)
end

return agent
