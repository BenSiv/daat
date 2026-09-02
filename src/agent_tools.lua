-- The domain-tools half of the chat/agent subsystem (see agent.lua for
-- the generic runtime: sessions, messages, compaction, approval
-- gating, the turn loop itself, and the background task queue). This
-- file holds everything specific to what daat's own agent can actually
-- do: the AGENT_TOOLS registry, execute_tool's real tool
-- implementations, the default system prompt, the research sub-agent's
-- own tool list, session-transcript sync, and the knowledge
-- distillation pass. agent.lua requires this module lazily, from
-- inside function bodies only, never at its own top level -- this file
-- requires agent.lua normally, at the top, since by the time anything
-- here actually runs, agent.lua has always already finished loading
-- (see ../../luam/doc/forward_references.md's sibling note on lazy
-- requires for cross-file circularity).

agent = require("agent")
auth = require("auth")
config = require("config")
document = require("document")
entity = require("entity")
extension = require("extension")
json = require("dkjson")
knowledge = require("knowledge")
schema = require("schema")
search_provider = require("search_provider")
template = require("template")
view = require("view")

agent_tools = {}

agent_tools.AGENT_TOOLS = {
    document = {
        search = {
            destructive = false,
            description = "Search documents by keyword or topic; returns each matching document's id, title, and a real content excerpt so you can answer from what the document actually says, not just its title.",
            parameters = {
                type = "object",
                properties = {query = {type = "string", description = "search text"}},
                required = {"query"},
            },
        },
        create = {
            destructive = true,
            description = "Create a new document.",
            parameters = {
                type = "object",
                properties = {
                    title = {type = "string"},
                    parent_id = {type = "integer", description = "optional parent document id"},
                    content = {type = "string", description = "markdown content"},
                },
                required = {"title"},
            },
        },
        update = {
            destructive = true,
            description = "Update an existing document.",
            parameters = {
                type = "object",
                properties = {
                    entity_id = {type = "integer", description = "document id"},
                    title = {type = "string", description = "optional new title"},
                    parent_id = {type = "integer", description = "optional new parent id"},
                    content = {type = "string", description = "optional new content -- replaces the whole field, does not append"},
                },
                required = {"entity_id"},
            },
        },
        children = {
            destructive = false,
            description = "List the immediate sub-documents (folder contents) under a document, or every top-level document/folder if parent_id is omitted. Use this to browse the document tree by structure, as an alternative to document.search's content-based matching.",
            parameters = {
                type = "object",
                properties = {parent_id = {type = "integer", description = "optional: omit for top-level documents"}},
            },
        },
        breadcrumbs = {
            destructive = false,
            description = "Get a document's full path from the root (root first) -- use this to tell the user where a document sits in the folder structure.",
            parameters = {
                type = "object",
                properties = {document_id = {type = "integer"}},
                required = {"document_id"},
            },
        },
    },
    -- Generic entity access -- any registered schema, not a curated
    -- subset (schema.lua/entity.lua's own validation is the safety
    -- boundary, same as the HTTP/CLI layer already relies on). list_types
    -- and fields exist so the model can discover real entity types and
    -- their field names/types itself rather than the system prompt
    -- needing to hardcode every schema that might ever be registered.
    entity = {
        list_types = {
            destructive = false,
            description = "List every registered entity type (samples, tasks, experiments, whatever this deployment has).",
            parameters = EMPTY_OBJECT_SCHEMA,
        },
        fields = {
            destructive = false,
            description = "List an entity type's fields and their types, so you know what's valid before creating/updating one.",
            parameters = {
                type = "object",
                properties = {entity_type = {type = "string"}},
                required = {"entity_type"},
            },
        },
        relationships = {
            destructive = false,
            description = "List every reference relationship between registered entity types (which type's field points at which other type -- e.g. 'sample.experiment -> experiment'). Call this when a value you're looking for isn't a field on the entity type you expected -- it's often a field on a DIFFERENT type that references the one you started from (e.g. a 'variety' filter for experiments actually lives on the samples that reference each experiment, not on the experiment itself). No args -- always returns the full relationship graph, small enough to read in one call.",
            parameters = EMPTY_OBJECT_SCHEMA,
        },
        query = {
            destructive = false,
            description = "Run a read-only SQL SELECT against registered entity tables, for anything entity.list's own single-table exact-match filter can't express: joins across related types (call entity.relationships first to find the join path), counts, aggregates, grouping. Table and column names are this deployment's real registered entity type/field names -- call entity.list_types/entity.fields/entity.relationships first if unsure, don't guess. Must be a single plain SELECT statement (no semicolons, no INSERT/UPDATE/DELETE/DDL) referencing only registered entity tables -- anything else is refused. Results are row-capped (this deployment's own configured limit) -- add your own LIMIT or narrow the query if a result comes back truncated (the truncation note tells you the true total match count, so you know whether narrowing is even worth it). Prefer expressing grouping/matching/deduplication logic (e.g. 'which groups of rows share the exact same set of X') as SQL itself -- GROUP BY with GROUP_CONCAT to build a per-group signature, then compare signatures -- rather than fetching many rows and comparing them yourself; there is no code-execution tool, so 'processed afterward' means reasoned over in your own reply, which doesn't scale to large row counts the way one aggregate query does. If a question genuinely can't be answered without paging through everything (no aggregate expresses it), use background.start rather than looping entity.query with an increasing OFFSET in the foreground -- and if you do page manually anyway, always add an explicit ORDER BY on a unique column (e.g. id): without one, SQL row order across separate LIMIT/OFFSET calls isn't guaranteed, so later pages can silently repeat or skip rows.",
            parameters = {
                type = "object",
                properties = {sql = {type = "string", description = "a single SELECT statement"}},
                required = {"sql"},
            },
        },
        list = {
            destructive = false,
            description = "List rows of an entity type, optionally filtered to rows where one field equals a value.",
            parameters = {
                type = "object",
                properties = {
                    entity_type = {type = "string"},
                    filter_field = {type = "string", description = "optional field name"},
                    filter_value = {type = "string", description = "optional value, only used with filter_field"},
                    limit = {type = "integer", description = "optional, default 20"},
                    offset = {type = "integer", description = "optional, for paging past the first page"},
                },
                required = {"entity_type"},
            },
        },
        get = {
            destructive = false,
            description = "Fetch one entity row by id.",
            parameters = {
                type = "object",
                properties = {entity_type = {type = "string"}, entity_id = {type = "integer"}},
                required = {"entity_type", "entity_id"},
            },
        },
        -- Grounded, real feedback for a write BEFORE it's ever proposed --
        -- runs the exact same schema-driven check (required/type/reference/
        -- reason-on-update rules) entity.create/entity.update themselves
        -- run first, via the same underlying entity.validate function,
        -- but never writes anything. Exists because a destructive call
        -- only actually runs after a human approves it (agent.
        -- create_pending_action) -- without this, an invalid create/update
        -- wastes a whole human-approval round-trip just to fail, instead
        -- of the model catching it itself beforehand.
        validate = {
            destructive = false,
            description = "Check whether values are valid for an entity type, without writing anything -- runs the same validation entity.create/entity.update would apply (required fields, types, valid references, reason-required-on-update rules). Pass entity_type plus one property per field, same as entity.create; also pass entity_id to validate as an UPDATE against that row's current values instead of a fresh create. Use this before entity.create/entity.update on anything non-obvious, so an invalid write is caught here instead of failing only after a human approves it.",
            parameters = {
                type = "object",
                properties = {
                    entity_type = {type = "string"},
                    entity_id = {type = "integer", description = "optional: validate as an update against this existing row instead of a fresh create"},
                },
                required = {"entity_type"},
                additionalProperties = true,
            },
        },
        create = {
            destructive = true,
            description = "Create a new entity row. Pass entity_type plus one property per field the entity type actually has (call entity.fields first if unsure).",
            parameters = {
                type = "object",
                properties = {entity_type = {type = "string"}},
                required = {"entity_type"},
                additionalProperties = true,
            },
        },
        update = {
            destructive = true,
            description = "Update fields on an existing entity row. Pass entity_type/entity_id plus one property per field to change. Some entity types require a reason -- if the tool result says one is required, ask the user why before retrying.",
            parameters = {
                type = "object",
                properties = {
                    entity_type = {type = "string"},
                    entity_id = {type = "integer"},
                    reason = {type = "string", description = "optional: why this change is being made"},
                },
                required = {"entity_type", "entity_id"},
                additionalProperties = true,
            },
        },
        archive = {
            destructive = true,
            description = "Archive (soft-remove) an entity row. Some entity types require a reason.",
            parameters = {
                type = "object",
                properties = {
                    entity_type = {type = "string"},
                    entity_id = {type = "integer"},
                    reason = {type = "string", description = "optional: why this change is being made"},
                },
                required = {"entity_type", "entity_id"},
            },
        },
        unarchive = {
            destructive = true,
            description = "Restore a previously archived entity row.",
            parameters = {
                type = "object",
                properties = {entity_type = {type = "string"}, entity_id = {type = "integer"}},
                required = {"entity_type", "entity_id"},
            },
        },
    },
    -- Turns entity.query results straight into a ready-to-paste ```plot```
    -- fence, instead of leaving the model to transcribe a text table into
    -- x/y arrays by hand -- confirmed live (task: active-samples-over-time
    -- chart) that this transcription step is where plotting attempts
    -- actually fail (mismatched array lengths, botched date arithmetic),
    -- not the SQL or the fence syntax itself. The row-to-array marshaling
    -- happens here in Lua, not in the model's own reasoning; the model's
    -- only remaining job is to paste the returned fence text into its
    -- reply verbatim. Deliberately returns fence TEXT rather than
    -- rendering an SVG itself -- reuses document.render_plot_fences (the
    -- same hook a hand-written ```plot``` block already goes through)
    -- rather than adding a second rendering path, since tool_result
    -- messages are shown as escaped plain text, not run through
    -- render_markdown (html.CHAT_MARKDOWN_ROLES), so a tool result can't
    -- render its own SVG directly anyway.
    plot = {
        from_query = {
            destructive = false,
            description = "Run a read-only SQL query (same rules as entity.query: single SELECT, registered entity tables only) and turn two of its numeric columns directly into a ready-to-paste ```plot``` fence -- paste the returned text into your reply verbatim, right where the chart should appear. Use this instead of entity.query whenever the goal is a chart: it builds the x/y arrays itself from the real query rows, so there's no risk of miscounting or mistyping values by hand.",
            parameters = {
                type = "object",
                properties = {
                    sql = {type = "string", description = "a single SELECT statement returning at least the x_column and y_column columns"},
                    x_column = {type = "string", description = "name of the result column to plot on the x axis -- must be numeric"},
                    y_column = {type = "string", description = "name of the result column to plot on the y axis -- must be numeric"},
                    series_name = {type = "string", description = "optional legend label for this series (defaults to y_column)"},
                    type = {type = "string", description = "optional: \"line\" (default), \"scatter\", or \"bar\""},
                    title = {type = "string", description = "optional chart title"},
                    xlabel = {type = "string", description = "optional x-axis label"},
                    ylabel = {type = "string", description = "optional y-axis label"},
                },
                required = {"sql", "x_column", "y_column"},
            },
        },
    },
    -- Reusable Entry templates (src/template.lua) -- a separate,
    -- filesystem-based system from `document`, invisible to every other
    -- tool. Read-only, same no-capability-check precedent as
    -- document.search: lets the model discover a template exists and
    -- get its rendered content, then hand that straight to
    -- document.create's own content arg.
    template = {
        list = {
            destructive = false,
            description = "List reusable Entry templates (name, label, description) available to build a new document from.",
            parameters = EMPTY_OBJECT_SCHEMA,
        },
        get = {
            destructive = false,
            description = "Get one template's rendered content, ready to pass straight to document.create's own content arg, plus its suggested default document name.",
            parameters = {
                type = "object",
                properties = {name = {type = "string", description = "template name"}},
                required = {"name"},
            },
        },
    },
    -- Read-only introspection into the knowledge pool's own tiering/
    -- retrieval activity (see knowledge.lua), plus one destructive
    -- tool: `distill` writes a genuinely new, single-idea document
    -- extracted from a source -- a real write (a new
    -- document/entity_event row), so it needs the same human-approval
    -- gate every other destructive tool has.
    knowledge = {
        stats = {
            destructive = false,
            description = "Summarize the knowledge pool's tier distribution and retrieval activity.",
            parameters = EMPTY_OBJECT_SCHEMA,
        },
        list = {
            destructive = false,
            description = "List knowledge pool documents with their id, tier, content shape (developed/atomic/thin/simple), heat, and retrieval count.",
            parameters = {
                type = "object",
                properties = {tier = {type = "integer", description = "optional, filter to one tier 0-3"}},
            },
        },
        distill = {
            destructive = true,
            description = "Write a new, concise, single-idea document distilled from a source you've actually read (e.g. via entity.get). Not a raw copy -- extract the one core idea in your own words. Only do this for a source that's genuinely \"developed\" (long/multi-section) -- an already-\"atomic\"/\"thin\"/\"simple\" source has nothing worth extracting.",
            parameters = {
                type = "object",
                properties = {
                    title = {type = "string"},
                    content = {type = "string", description = "the distilled markdown text"},
                    source_document_id = {type = "integer", description = "optional: the existing document this was distilled from"},
                },
                required = {"title", "content"},
            },
        },
    },
    -- Admin-approved saved queries (src/view.lua) -- a safer alternative
    -- to entity.query for anything a curated report already covers,
    -- since a view only ever runs once a human has explicitly approved
    -- its exact SQL text (view.approve/view.is_approved), not whatever
    -- the model constructs on the fly.
    view = {
        list = {
            destructive = false,
            description = "List admin-approved saved views (name, title, description, and whether it takes a parameter) available to run. Only approved views can actually be run -- see view.run.",
            parameters = EMPTY_OBJECT_SCHEMA,
        },
        run = {
            destructive = false,
            description = "Run an approved saved view by name and return its rows. Pass param_value if view.list said this view takes a parameter. Refuses to run an unapproved view -- ask the user to approve it via /view first, or use entity.query instead if no approved view covers this.",
            parameters = {
                type = "object",
                properties = {
                    name = {type = "string", description = "view name, from view.list"},
                    param_value = {type = "string", description = "optional, only if the view declares a param"},
                },
                required = {"name"},
            },
        },
    },
    -- A general-purpose sub-agent primitive, not another named point-fix
    -- tool: delegates one focused sub-question to an isolated,
    -- read-only tool-calling loop (see run_research_loop) that can dig
    -- in from multiple angles -- checking entity.relationships for a
    -- join path, retrying entity.query a different way -- before
    -- concluding an answer, the same structural idea Claude Code's own
    -- Task/Explore sub-agents use to isolate exploratory noise from the
    -- main conversation. Exists because the main turn loop's own budget
    -- (MAX_TURNS) and context (everything the eventual self-check judges
    -- the final answer against) both get spent by trial-and-error
    -- digging otherwise -- this gives the model somewhere to do that
    -- digging without either cost.
    research = {
        investigate = {
            destructive = false,
            description = "Delegate a focused sub-question to an isolated research pass that can run its own series of read-only lookups (entity.fields/entity.relationships/entity.query/entity.list/entity.get, document.search, knowledge.list/stats) before answering. Use this instead of a single direct lookup when a question genuinely needs digging -- a count/aggregate, a relationship you haven't already confirmed, anything where a first attempt coming up empty shouldn't be trusted without a different angle tried. Bounded to a handful of turns -- if the question means checking many discrete items one by one ('across all N experiments/entities'), that's more than this budget covers; use background.start instead so coverage doesn't get silently generalized from a partial sample. Returns a synthesized, grounded finding, not raw rows -- the queries it runs along the way are not added to this conversation.",
            parameters = {
                type = "object",
                properties = {question = {type = "string", description = "the specific sub-question to research"}},
                required = {"question"},
            },
        },
    },
    -- A structural escape hatch for genuine ambiguity/missing information,
    -- so "ask instead of guessing" is a real, code-recognized outcome
    -- (agent.run_turn's own clarify_call handling below) rather than the
    -- model just writing a question as ordinary final text -- which reads
    -- to the turn loop (and self-check) exactly like any other answer,
    -- with nothing distinguishing "I'm done" from "I'm stuck and asking."
    -- Ends the turn immediately, before self-check runs (there's no
    -- answer yet to critique) -- the user's own next message is the
    -- reply, handled by the normal /chat-message flow, no separate
    -- approve/deny step the way a destructive pending action needs.
    clarify = {
        ask = {
            destructive = false,
            description = "Ask the user one clarifying question instead of guessing or giving up, when the request genuinely has more than one reasonable interpretation that would lead to a different answer or action, or is missing information you can't reasonably infer yourself or find with a tool. Try looking it up first -- don't ask for something a tool call could answer. Ends this turn; the user's next message is the answer.",
            parameters = {
                type = "object",
                properties = {question = {type = "string", description = "the specific question to ask the user"}},
                required = {"question"},
            },
        },
    },
    -- Hands a question off to a separate, later process (the CLI's
    -- "daat agent run-pending-background", meant to run on a timer --
    -- see agent_background_task above) instead of digging in inline, for
    -- something that would need more turns than research.investigate's
    -- own bounded budget affords within one HTTP request. Not a
    -- replacement for research.investigate -- reach for this only when
    -- that isn't enough, since a background task's finding doesn't reach
    -- the user until they check back or ask again.
    background = {
        start = {
            destructive = false,
            description = "Hand a question off to a background task that keeps digging after this turn ends, for something that would need more turns than research.investigate's own budget -- use research.investigate first; only use this if that isn't enough. Returns a task id immediately; the finding is appended to this same conversation once it's ready (check with background.status, or just ask again later).",
            parameters = {
                type = "object",
                properties = {question = {type = "string", description = "the specific question to research in the background"}},
                required = {"question"},
            },
        },
        status = {
            destructive = false,
            description = "Check on a background task started with background.start: still pending, or its finding if done.",
            parameters = {
                type = "object",
                properties = {task_id = {type = "integer", description = "the id returned by background.start"}},
                required = {"task_id"},
            },
        },
    },
    -- destructive=true here isn't about a write -- it's a real data
    -- exit (the query text, and anything from this conversation the
    -- model folds into it, leaves this system). Marking it destructive
    -- gets per-call human approval for free from the same pending-
    -- action flow every write tool already goes through -- see
    -- search_google_cse.lua's own header for why this is a
    -- plain custom tool, not one of a provider's native
    -- server-executed search tools.
    internet_search = {
        search = {
            destructive = true,
            description = "Search the public internet for current information. Returns up to 5 results, each with a title, source URL, and a short snippet. Always cite the source URL when using information from a result in your reply -- never state a web-sourced fact without attributing it to the specific URL it came from.",
            parameters = {
                type = "object",
                properties = {query = {type = "string", description = "search text"}},
                required = {"query"},
            },
        },
    },
}

-- The extension-tools plugin surface (doc/plugin-system-research.md,
-- brex 278013129): an approved extension's capabilities.tools entries
-- are dispatched under tool_name = the extension's own manifest.name
-- (validated collision-free against AGENT_TOOLS' own top-level keys at
-- manifest-validate time, see extension.lua's RESERVED_TOOL_NAMES), so
-- they slot into the exact same tool_name.method_name lookup built-ins
-- use, with no remapping table at all. Returns the matching manifest
-- and tool spec, or nil if tool_name isn't an approved extension's own
-- name or it declares no matching method.
function agent_tools.find_extension_tool(db_path, tool_name, method_name)
    for _, entry in ipairs(extension.approved_with_tools(db_path, config.extensions_dir())) do
        if entry.name == tool_name then
            for _, tool in ipairs(entry.manifest.capabilities.tools) do
                if tool.name == method_name then
                    return entry.manifest, tool
                end
            end
            return nil
        end
    end
    return nil
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

-- Grounds the agent's own answers in real document content --
-- document.search already fetches full content for scoring, so the
-- tool result surfaces an excerpt of it too, not just "#id title"
-- lines, letting the model actually read a document before answering
-- rather than only learning which ones might be relevant. Bounded per
-- result (not the full document verbatim) so a search that matches
-- several long documents doesn't balloon every turn's prompt/token
-- cost -- trimmed to the last whole word rather than cutting mid-word.
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

-- Error text for an entity_type argument that isn't registered, with a
-- suggested correction when schema.suggest_type finds one close enough
-- (e.g. the plural "samples" -> "sample") -- shared by every entity.*
-- tool handler below so a bad type name costs the model one tool call
-- with an actionable message, not a second round trip to entity.list_types
-- to guess its way to the real name.
-- Tables that are real, hand-rolled (never schema.register()'d) but
-- still get a real-columns answer from entity.fields instead of falling
-- through to unknown_entity_type_message -- the same treatment
-- document.lua's KNOWLEDGE_POOL_SQL_COLUMNS already gets for document's
-- own extra columns, extended here to the knowledge-pool's event-log
-- tables and agent_session. Checked before
-- schema.is_registered below, since none of these are registered entity
-- types at all. agent_message/agent_pending_action/agent_background_task
-- are deliberately absent -- see agent_session's own SQL note above.
HAND_ROLLED_ENTITY_FIELDS = {
    agent_session = function() return agent.session_sql_columns_text() end,
    document_embedding = function() return document.embedding_sql_columns_text() end,
    knowledge_retrieval = function() return knowledge.hand_rolled_sql_columns_text("knowledge_retrieval") end,
    knowledge_retrieval_document = function() return knowledge.hand_rolled_sql_columns_text("knowledge_retrieval_document") end,
    knowledge_review = function() return knowledge.hand_rolled_sql_columns_text("knowledge_review") end,
    knowledge_context = function() return knowledge.hand_rolled_sql_columns_text("knowledge_context") end,
    knowledge_chat_eval = function() return knowledge.hand_rolled_sql_columns_text("knowledge_chat_eval") end,
}

function unknown_entity_type_message(db_path, entity_type)
    message = "unknown entity type: " .. tostring(entity_type)
    suggestion = schema.suggest_type(db_path, entity_type)
    if suggestion != nil then
        message = message .. " -- did you mean '" .. suggestion .. "'?"
    else
        message = message .. " -- call entity.list_types for the full list"
    end
    return message
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

-- Whether the agent is allowed to write to entity_type, *on behalf of
-- `login`* -- the agent's authority is exactly the delegating user's
-- own capability, never more and never less (see doc/architecture.md's
-- "Chat" section, "Attribution and authorization are both the
-- chatting user's own", for why this checks the real chatting user's
-- `user.cap` -- the same row/column require_write_capability, cgi.lua,
-- already checks for a direct form submission -- rather than a fixed
-- api_key row). Fails closed: no such user row (or no "a" on it) means
-- no admin-gated writes, not a silent default.
--
-- `login` is always a real, session-authenticated user.login here --
-- every chat entry point (agent.run_turn/approve_pending/deny_pending)
-- is reached only from cgi.lua routes gated by require_csrf(cookies),
-- never an API key, so there's no "api:label" case to handle.
function agent_tools.check_write_capability(db_path, entity_type, login)
    if schema.admin_write_only(db_path, entity_type) == false then
        return true
    end
    user = auth.get_user(db_path, login)
    cap = ""
    if user != nil then
        cap = user.cap
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
function agent_tools.execute_tool(db_path, author, session_id, tool_name, method_name, args)
    source = {notebook_entry_id = "agent-session:" .. tostring(session_id)}

    if tool_name == "document" and method_name == "search" then
        results = knowledge.search_and_log(db_path, args.query, 5, true, session_id, author)
        if #results == 0 then
            return "No matching documents found."
        end
        -- Structural, not just a prompt reminder: multiple documents
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
                    " documents titled '" .. r.title .. "' -- distinguish by date/external_id/content above, never by asking the user for the id]"
            end
            table.insert(lines, header .. "\n" .. excerpt(r.content, config.platform_config().agent_search_excerpt_length))
        end
        return table.concat(lines, "\n\n")
    end

    if tool_name == "document" and method_name == "create" then
        if agent_tools.check_write_capability(db_path, "document", author) == false then
            return nil, "Forbidden: this requires your own Admin capability -- ask an admin to grant it to your account."
        end
        parent_id = tonumber(args.parent_id)
        created_id, issues = document.create_page(db_path, author, args.title, parent_id, args.content, source)
        if created_id == nil then
            return nil, issues_summary(issues)
        end
        return "Created document #" .. tostring(created_id) .. " (" .. tostring(args.title) .. ")"
    end

    if tool_name == "document" and method_name == "update" then
        if agent_tools.check_write_capability(db_path, "document", author) == false then
            return nil, "Forbidden: this requires your own Admin capability -- ask an admin to grant it to your account."
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
        return "Updated document #" .. tostring(updated_id)
    end

    if tool_name == "document" and method_name == "children" then
        rows = document.children(db_path, tonumber(args.parent_id))
        if #rows == 0 then
            return "No sub-documents."
        end
        lines = {}
        for _, r in ipairs(rows) do
            table.insert(lines, "#" .. tostring(r.id) .. " " .. r.title)
        end
        return table.concat(lines, "\n")
    end

    if tool_name == "document" and method_name == "breadcrumbs" then
        if args.document_id == nil then
            return nil, "breadcrumbs requires document_id"
        end
        crumbs = document.breadcrumbs(db_path, tonumber(args.document_id))
        if #crumbs == 0 then
            return nil, "no such document (or it has no resolvable path)"
        end
        parts = {}
        for _, c in ipairs(crumbs) do
            table.insert(parts, c.title)
        end
        return table.concat(parts, " / ")
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
        if HAND_ROLLED_ENTITY_FIELDS[args.entity_type] != nil then
            return "'" .. args.entity_type .. "' is a real table, hand-rolled rather than schema.register()'d -- it has no editable schema, but these are its actual SQL columns:\n" .. HAND_ROLLED_ENTITY_FIELDS[args.entity_type]()
        end
        if schema.is_registered(db_path, args.entity_type) == false then
            return nil, unknown_entity_type_message(db_path, args.entity_type)
        end
        fields = schema.fields(db_path, args.entity_type)
        if #fields == 0 then
            return "'" .. tostring(args.entity_type) .. "' is a registered entity type with no custom fields (only the system-managed id/created/updated columns)."
        end
        lines = {}
        for _, f in ipairs(fields) do
            required = ""
            if tonumber(f.required) == 1 then
                required = ", required"
            end
            table.insert(lines, string.format("%s (%s%s)", f.name, f.type, required))
        end
        -- `document` also carries knowledge-pool columns intentionally kept
        -- out of schema.fields (see document.lua's KNOWLEDGE_POOL_SQL_COLUMNS
        -- comment) -- surface them here too, so a query touching
        -- heat/tier/retrieval/source has real column names to ground in
        -- instead of inventing a table.
        if args.entity_type == "document" then
            table.insert(lines, "")
            table.insert(lines, "Additional columns on the real `document` table, queryable in SQL but not part of the editable schema above (the knowledge-pool mechanism's own tier/heat/retrieval/source tracking):")
            table.insert(lines, document.knowledge_pool_sql_columns_text())
        end
        return table.concat(lines, "\n")
    end

    if tool_name == "entity" and method_name == "relationships" then
        edges = schema.relationships(db_path)
        if #edges == 0 then
            return "No reference relationships registered between any entity types."
        end
        lines = {}
        for _, edge in ipairs(edges) do
            table.insert(lines, string.format("%s.%s -> %s (%s)", edge.from_type, edge.field_name, edge.to_type, edge.field_type))
        end
        table.sort(lines)
        return table.concat(lines, "\n")
    end

    if tool_name == "entity" and method_name == "query" then
        if args.sql == nil then
            return nil, "query requires sql"
        end
        column_names, rows, err, truncated, total_count = view.run_agent_query(db_path, args.sql)
        if column_names == nil then
            return nil, tostring(err)
        end
        if #rows == 0 then
            return "Query returned no rows."
        end
        lines = {}
        table.insert(lines, table.concat(column_names, " | "))
        for _, row in ipairs(rows) do
            values = {}
            for _, col in ipairs(column_names) do
                table.insert(values, tostring(row[col]))
            end
            table.insert(lines, table.concat(values, " | "))
        end
        result = table.concat(lines, "\n")
        if truncated == true then
            if total_count != nil then
                result = result .. "\n\n(showing " .. tostring(#rows) .. " of " .. tostring(total_count) .. " total matching rows -- add your own LIMIT or narrow the query for a complete result)"
            else
                result = result .. "\n\n(truncated at " .. tostring(#rows) .. " rows -- add your own LIMIT or narrow the query for a complete result)"
            end
        end
        return result
    end

    if tool_name == "plot" and method_name == "from_query" then
        if args.sql == nil or args.x_column == nil or args.y_column == nil then
            return nil, "from_query requires sql, x_column, and y_column"
        end
        column_names, rows, err, truncated, total_count = view.run_agent_query(db_path, args.sql)
        if column_names == nil then
            return nil, tostring(err)
        end
        if #rows == 0 then
            return nil, "query returned no rows -- nothing to plot"
        end

        has_x, has_y = false, false
        for _, col in ipairs(column_names) do
            if col == args.x_column then
                has_x = true
            end
            if col == args.y_column then
                has_y = true
            end
        end
        if has_x == false or has_y == false then
            return nil, "query result has no column named \"" .. tostring(args.x_column) .. "\" and/or \"" .. tostring(args.y_column) ..
                "\" -- actual columns: " .. table.concat(column_names, ", ")
        end

        x_values, y_values = {}, {}
        for i, row in ipairs(rows) do
            x_num = tonumber(row[args.x_column])
            y_num = tonumber(row[args.y_column])
            if x_num == nil or y_num == nil then
                return nil, "row " .. tostring(i) .. "'s \"" .. tostring(args.x_column) .. "\"/\"" .. tostring(args.y_column) ..
                    "\" value isn't numeric (got " .. tostring(row[args.x_column]) .. "/" .. tostring(row[args.y_column]) ..
                    ") -- both columns must be numeric to plot"
            end
            table.insert(x_values, x_num)
            table.insert(y_values, y_num)
        end

        series_name = args.series_name
        if series_name == nil then
            series_name = args.y_column
        end
        spec = {series = {{name = series_name, x = x_values, y = y_values}}}
        if args.type != nil then
            spec.type = args.type
        end
        if args.title != nil then
            spec.title = args.title
        end
        if args.xlabel != nil then
            spec.xlabel = args.xlabel
        end
        if args.ylabel != nil then
            spec.ylabel = args.ylabel
        end

        -- Same validation the fence renderer itself runs at reply-render
        -- time (document.render_plot_fences) -- catching a malformed
        -- spec here gives the model a clear, actionable tool error
        -- instead of a reply that only shows a broken chart once sent.
        cfg, cfg_err = document.plot_spec_to_gnuplot_cfg(spec)
        if cfg == nil then
            return nil, "built an invalid plot spec: " .. tostring(cfg_err)
        end

        fence = "```plot\n" .. json.encode(spec) .. "\n```"
        if truncated == true then
            if total_count != nil then
                fence = fence .. "\n\n(chart shows " .. tostring(#rows) .. " of " .. tostring(total_count) .. " total matching rows -- add your own LIMIT or narrow the query for a complete chart)"
            else
                fence = fence .. "\n\n(query truncated at " .. tostring(#rows) .. " rows -- add your own LIMIT or narrow the query for a complete chart)"
            end
        end
        return fence
    end

    if tool_name == "entity" and method_name == "list" then
        if args.entity_type == nil then
            return nil, "list requires entity_type"
        end
        if schema.is_registered(db_path, args.entity_type) == false then
            return nil, unknown_entity_type_message(db_path, args.entity_type)
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
        if schema.is_registered(db_path, args.entity_type) == false then
            return nil, unknown_entity_type_message(db_path, args.entity_type)
        end
        row = entity.get(db_path, args.entity_type, target_id)
        if row == nil then
            return nil, "no such " .. tostring(args.entity_type) .. " #" .. tostring(target_id)
        end
        return row_summary(row)
    end

    if tool_name == "entity" and method_name == "validate" then
        if args.entity_type == nil then
            return nil, "validate requires entity_type"
        end
        values = {}
        for k, v in pairs(args) do
            if k != "entity_type" and k != "entity_id" then
                values[k] = v
            end
        end
        target_id = tonumber(args.entity_id)
        issues = nil
        if target_id != nil then
            current = entity.get(db_path, args.entity_type, target_id)
            if current == nil then
                return nil, "no such " .. tostring(args.entity_type) .. " #" .. tostring(target_id)
            end
            merged = {}
            for k, v in pairs(current) do
                merged[k] = v
            end
            for k, v in pairs(values) do
                merged[k] = v
            end
            issues = entity.validate(db_path, args.entity_type, merged, current)
        else
            issues = entity.validate(db_path, args.entity_type, values)
        end

        blocking = false
        lines = {}
        for _, issue in ipairs(issues) do
            field = issue.field
            if field == nil then
                field = "(general)"
            end
            table.insert(lines, string.format("[%s] %s: %s", tostring(issue.severity), field, tostring(issue.message)))
            if issue.severity == "error" then
                blocking = true
            end
        end
        if #lines == 0 then
            return "Valid -- entity.create/entity.update would succeed as given."
        end
        result = table.concat(lines, "\n")
        if blocking == false then
            result = result .. "\n\n(no blocking errors -- entity.create/entity.update would still succeed)"
        end
        return result
    end

    if tool_name == "entity" and method_name == "create" then
        if args.entity_type == nil then
            return nil, "create requires entity_type"
        end
        if agent_tools.check_write_capability(db_path, args.entity_type, author) == false then
            return nil, "Forbidden: " .. tostring(args.entity_type) .. " requires your own Admin capability -- ask an admin to grant it to your account."
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
        if agent_tools.check_write_capability(db_path, args.entity_type, author) == false then
            return nil, "Forbidden: " .. tostring(args.entity_type) .. " requires your own Admin capability -- ask an admin to grant it to your account."
        end
        -- `reason` is metadata about the change, not a field being
        -- changed on the entity itself -- pulled out the same way
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
        if agent_tools.check_write_capability(db_path, args.entity_type, author) == false then
            return nil, "Forbidden: " .. tostring(args.entity_type) .. " requires your own Admin capability -- ask an admin to grant it to your account."
        end
        archived_id, issues = entity.archive(db_path, args.entity_type, target_id, author, source, args.reason)
        if archived_id == nil then
            return nil, issues_summary(issues)
        end
        document.on_entity_archived(db_path, args.entity_type, archived_id)
        return "Archived " .. tostring(args.entity_type) .. " #" .. tostring(archived_id)
    end

    if tool_name == "entity" and method_name == "unarchive" then
        target_id = tonumber(args.entity_id)
        if args.entity_type == nil or target_id == nil then
            return nil, "unarchive requires entity_type and entity_id"
        end
        if agent_tools.check_write_capability(db_path, args.entity_type, author) == false then
            return nil, "Forbidden: " .. tostring(args.entity_type) .. " requires your own Admin capability -- ask an admin to grant it to your account."
        end
        unarchived_id, issues = entity.unarchive(db_path, args.entity_type, target_id, author, source)
        if unarchived_id == nil then
            return nil, issues_summary(issues)
        end
        document.on_entity_unarchived(db_path, args.entity_type, unarchived_id)
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
        return "Suggested document name: " .. tostring(default_path) .. "\n\n" .. rendered
    end

    if tool_name == "knowledge" and method_name == "stats" then
        stats = knowledge.stats(db_path)
        return string.format(
            "tier0=%d tier1=%d tier2=%d tier3=%d notes=%d retrievals=%d reviewed=%d sessions=%d",
            stats.tier_counts[0], stats.tier_counts[1], stats.tier_counts[2], stats.tier_counts[3],
            stats.note_count, stats.retrieval_count, stats.reviewed_note_count, stats.session_count
        )
    end

    -- Read-only listing -- surfaces the pool's real document ids/tiers/
    -- content shape to the model. Content shape is what the
    -- distillation pass reads to decide what's actually worth
    -- distilling from -- only "developed" (long/multi-section) content
    -- has something worth extracting; an already-"atomic"/"thin"/
    -- "simple" document doesn't. Optional args.tier filters, same as
    -- the CLI.
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
                tostring(row.id), tostring(row.tier), document.content_shape(body), tostring(row.title),
                row.effective_heat, tostring(row.retrieval_count)
            ))
        end
        return table.concat(lines, "\n")
    end

    -- Destructive: writes a new, concise, single-idea document
    -- distilled from a source the agent has read -- the real
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

    if tool_name == "view" and method_name == "list" then
        entries = view.all(config.views_dir())
        if #entries == 0 then
            return "No views defined."
        end
        lines = {}
        for _, e in ipairs(entries) do
            if e.def != nil then
                approved_note = "not approved"
                if view.is_approved(db_path, e.def) == true then
                    approved_note = "approved, runnable"
                end
                param_note = ""
                if e.def.param != nil then
                    param_note = " (takes param: " .. e.def.param.name .. ")"
                end
                table.insert(lines, e.name .. " -- " .. tostring(e.def.title) .. param_note .. " [" .. approved_note .. "]")
            end
        end
        return table.concat(lines, "\n")
    end

    if tool_name == "view" and method_name == "run" then
        if args.name == nil then
            return nil, "run requires name"
        end
        view_def, view_err = view.load(config.views_dir(), args.name)
        if view_def == nil then
            return nil, "no such view: " .. tostring(args.name) .. " (" .. tostring(view_err) .. ")"
        end
        if view.is_approved(db_path, view_def) == false then
            return nil, "view '" .. args.name .. "' is not approved -- ask the user to approve it via /view first"
        end
        rows, run_err = view.run(db_path, view_def, args.param_value)
        if rows == nil then
            return nil, run_err
        end
        if #rows == 0 then
            return "No rows."
        end
        cap = config.platform_config().agent_query_row_cap
        lines = {}
        for i = 1, math.min(cap, #rows) do
            parts = {}
            for k, v in pairs(rows[i]) do
                table.insert(parts, tostring(k) .. "=" .. tostring(v))
            end
            table.insert(lines, table.concat(parts, ", "))
        end
        result = table.concat(lines, "\n")
        if #rows > cap then
            result = result .. "\n\n(truncated at " .. tostring(cap) .. " of " .. tostring(#rows) .. " rows -- add your own LIMIT or narrow the query for a complete result)"
        end
        return result
    end

    -- agent.default_model() here, not a model threaded through this
    -- whole call chain -- every real call site (cgi.lua's chat routes,
    -- main.lua's knowledge distillation) already resolves `model` the
    -- exact same way before ever calling agent.run_turn, so this is the
    -- same model the outer turn is already using in every real case,
    -- without widening agent.execute_tool's own signature for it.
    if tool_name == "research" and method_name == "investigate" then
        if args.question == nil then
            return nil, "investigate requires question"
        end
        finding, err = agent.run_research_loop(db_path, author, session_id, agent.default_model(), args.question)
        if finding == nil then
            return nil, tostring(err)
        end
        return finding
    end

    if tool_name == "background" and method_name == "start" then
        if args.question == nil then
            return nil, "start requires question"
        end
        task_id = agent.enqueue_background_task(db_path, session_id, args.question)
        return "Started background task #" .. tostring(task_id) ..
            " -- its finding will be added to this conversation once it's ready; check with background.status(" ..
            tostring(task_id) .. ") or just ask again later."
    end

    -- Ownership checked against the CURRENT session (not the task's own
    -- login) -- same "not found" wording either way a mismatch could
    -- happen (unknown id, or a real id belonging to someone else's
    -- session), so a guessed/incremented task_id can't be used to read
    -- another user's background task.
    if tool_name == "background" and method_name == "status" then
        target_id = tonumber(args.task_id)
        if target_id == nil then
            return nil, "status requires task_id"
        end
        task = agent.get_background_task(db_path, target_id)
        if task == nil or task.session_id != session_id then
            return nil, "no such background task #" .. tostring(target_id)
        end
        if task.status == "done" then
            return "Task #" .. tostring(target_id) .. " (done): " .. tostring(task.result)
        elseif task.status == "failed" then
            return "Task #" .. tostring(target_id) .. " (failed after " .. tostring(task.attempts) .. " attempts): " .. tostring(task.last_error)
        end
        return "Task #" .. tostring(target_id) .. " is still " .. tostring(task.status) .. "."
    end

    if tool_name == "internet_search" and method_name == "search" then
        if args.query == nil or args.query == "" then
            return nil, "search requires query"
        end
        response, err = search_provider.search(args.query)
        if response == nil then
            return nil, err
        end
        return search_provider.format_results(response)
    end

    ext_manifest, ext_tool = agent_tools.find_extension_tool(db_path, tool_name, method_name)
    if ext_manifest != nil then
        hooks, hooks_err = extension.load_hooks(config.extensions_dir(), tool_name, ext_manifest)
        if hooks == nil then
            if hooks_err != nil then
                return nil, hooks_err
            end
            return nil, "extension '" .. tool_name .. "' does not implement tool '" .. method_name .. "'"
        end
        handler = nil
        if type(hooks.tools) == "table" then
            handler = hooks.tools[method_name]
        end
        if type(handler) != "function" then
            return nil, "extension '" .. tool_name .. "' does not implement tool '" .. method_name .. "'"
        end
        ctx = entity.build_ctx(db_path, ext_manifest)
        call_ok, result, call_err = pcall(handler, ctx, args)
        if call_ok == false then
            return nil, tostring(result)
        end
        return result, call_err
    end

    return nil, "unknown tool: " .. tostring(tool_name) .. "." .. tostring(method_name)
end

-- The default system prompt: domain/behavior guidance only -- the
-- tools themselves are no longer enumerated here in hand-written text.
-- The model gets the real tool list as native function declarations
-- (agent.tool_declarations(), passed to agent_provider.converse's own
-- `tools` argument) with structured JSON-Schema parameters and
-- per-tool descriptions (AGENT_TOOLS' own `description` field) --
-- Gemini/Vertex decides on its own when to call one and returns a real
-- structured toolCall block, no tag protocol for the model to get
-- right or for this code to parse.
--
-- Appends theme.lua's own system_prompt_extra, if a deployment set
-- one -- deployment-specific instructions (domain vocabulary, house
-- style, use-case reminders) without editing daat's own
-- source. Every real call site (run_turn's own
-- fallback, approve_pending, deny_pending) already reaches this
-- function exactly when no caller-supplied system_prompt was given,
-- so this is the one place that needs to change for every one of them
-- to pick it up -- see doc/architecture.md's "Chat" section.
function agent_tools.default_system_prompt()
    config = require("config")
    theme = config.load_theme(config.find_root())
    extra = ""
    if theme.system_prompt_extra != nil then
        extra = "\n\n" .. theme.system_prompt_extra
    end
    return """
You are an assistant embedded in a data platform. Answer directly when you can, or call one of your available tools to look up or change data.

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

When creating or updating an entity, fill in optional fields you can
reasonably infer from the request instead of leaving them blank (e.g. a
concise subject/title summarizing what was asked, a sensible due date if one
is clearly implied) -- the same judgment call a person filling out the same
form by hand would make. If a field is genuinely ambiguous, use clarify.ask
rather than guessing.

When asked to write a Markdown table with specific rows and/or columns,
actually include every named row as a real data row, not just a header --
a table needs a header row, a separator row (|---|---|), and one data row
per item named in the request. Before finishing, check your own output has
all three parts and every item asked for; a header-only table is an
incomplete answer, not a done one.

If your first attempt at something (a search, a lookup) doesn't find what
you need, try again a different way (different search terms, a broader or
narrower query, a different tool) before giving up or using clarify.ask.
You have room for several tool calls in a single turn -- use them when the
question genuinely calls for it, rather than answering from a single
attempt that came up empty or ambiguous.

Multiple entities (or documents) can genuinely share the same title (e.g.
several Benchling-synced documents all named after the same experiment
number) -- when that happens, never ask the user for a raw internal id to
disambiguate; they don't think in ids and shouldn't have to. Instead use
what document.search or entity.get already gives you -- content excerpt,
creation date, an external_id if the row has one -- to either tell the
candidates apart yourself, or describe them to the user in those terms
("there are two documents titled X, one from March about Y and one from June
about Z -- which do you mean?").

More generally: a raw database id (an entity's numeric id, a foreign-key
value like "experiment = 91") is a tool-calling detail, not something the
user asked about or wants read back to them. Use ids freely between tool
calls to filter and join, but when you write the actual reply, refer to
every entity by its human-facing name/label instead -- drop the id line
entirely rather than adding it "for completeness."

When a reply summarizes several records (e.g. every sample in an
experiment), don't restate the full field list once per record just
because you looked at it that way -- that repeats the same handful of
shared values over and over and buries the one thing the user actually
came for. Say what's shared once, call out only the fields that actually
differ per record (as a compact table or list), and lead or close with a
real bottom line: the takeaway a person would want if they only read one
sentence, not a re-statement of the data you just listed.

Keep any narration you write before a tool call short -- a sentence on what
you're about to check and why, not a paragraph walking through your own
reasoning. The narration is a visible part of the transcript now; its job
is to orient the user in a few words, not to think out loud at length. Save
the real depth for the final synthesis, where it's actually being read.

If you don't already know an entity type's fields, call entity.fields first
rather than guessing field names.

When asked to write a SQL query rather than run one (e.g. "write me a query
for X", "what SQL would show Y"), still call entity.query yourself first to
confirm it actually runs against the real schema before giving the query
back as your final answer -- don't hand back untested SQL just because the
user asked for the text rather than the result. If it errors, read the
error text before deciding what to do: most errors mean your SQL is wrong,
so fix it and re-check. But "refusing to run: 'X' is a real table, but
intentionally excluded from entity.query" means the opposite -- the query
itself is fine, this specific tool just can't reach that table (a system
table below the registered-entity boundary, checked via the admin console
instead). Present that query as your final answer anyway, and say plainly
you couldn't self-verify it through entity.query -- don't "fix" it into a
different query just to dodge that one tool's own limit.

When you use internet_search results in a reply, always cite your sources:
include the specific URL next to any fact, claim, or quote drawn from a
result. Never present information from a web search as if it were your own
knowledge, and never drop the URL just because you already stated it earlier
in the same reply -- restate it wherever it's needed to trace a claim back to
its source.

Tools are only for reaching data you don't already have -- looking things
up, changing them. They are not a gate on what you're allowed to do with
data once you have it. Summarizing, categorizing, comparing, ranking, or
otherwise synthesizing information you've already retrieved is your own
reasoning at work, not a separate capability that needs its own tool. If a
tool call gets you the raw material for something like "categorize these"
or "what's the common theme here", do that analysis yourself in your
reply -- never tell the user you can't, or hand back the raw data
unprocessed, just because no tool is literally named for it.

There is no code-execution tool -- you cannot run Python, JS, or anything
else to process data after fetching it. "Do the analysis yourself" above
means reasoning over what a tool call already returned, which works for a
handful of rows but not for precisely matching, deduplicating, or grouping
hundreds/thousands of them by hand across many turns. For that class of
question, push the logic into the SQL itself (entity.query supports GROUP
BY, GROUP_CONCAT-style signatures, and other aggregates -- see its own
description) instead of planning to fetch everything page by page and
compute the answer afterward.

To plot numeric data (a document you write, or a chat reply), use a fenced
code block whose language is "plot" containing a single JSON object -- do
not write gnuplot script or any other plotting syntax yourself. Shape:
{"type": "line", "title": "...", "xlabel": "...", "ylabel": "...",
"series": [{"name": "...", "x": [1,2,3], "y": [4,5,6]}]}. "type" is "line",
"scatter", or "bar" (default "line" if omitted); "series" is required and
needs at least one entry, each with an "x" and "y" array of the same
length holding only numbers -- no strings, no dates, no nulls. "name" on a
series is optional (used as its legend label); "title"/"xlabel"/"ylabel"
are optional. Only plot real numeric data you actually have or were given
-- never fabricate data points to fill out a chart.

When the data to plot comes from a SQL query (entity.query), use
plot.from_query instead of building the fence by hand: give it the query
plus which result columns are x and y, and it returns the exact fence text
above ready to paste into your reply. Do not retype/copy numbers from an
entity.query text-table result into a plot fence yourself -- transcribing
many rows by hand is exactly the kind of thing that produces mismatched or
wrong values; let plot.from_query build the arrays from the real rows
instead. Reach for a hand-written fence only when you already have a small
number of values directly (e.g. numbers stated in the conversation, not
pulled from a query result).
""" .. extra
end

ROLE_LABELS = {user = "User", assistant = "Assistant", tool_result = "Tool result", self_check = "Self-check"}

-- A human-readable transcript of a session's full message history --
-- full session persistence, not just the individual prompt/reasoning
-- audit rows knowledge_context already keeps per turn (see
-- doc/architecture.md's "Knowledge pool" section, "Whole chat sessions
-- are themselves documents"). Reuses agent.all_messages' own
-- display_content cleanup (strips the [Current user:...]/[Current
-- page:...] annotations, renders a tool call as "-> tool.method(...)")
-- rather than a second rendering path.
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
-- in sync with its current transcript -- find-or-create, then update
-- in place every time a turn concludes, so it always reflects the
-- conversation so far, not a one-time snapshot. Filed under the
-- Knowledge Pool folder like any other system-derived document (see
-- doc/architecture.md's "Knowledge pool" section) so a
-- heavily-revisited conversation participates in the same
-- tiered/searchable/distillation pipeline as everything else, with no
-- separate mechanism needed on top.
function agent_tools.sync_session_document(db_path, login, session_id)
    session = agent.get_session(db_path, session_id, login)
    title = "Untitled chat"
    if session != nil and session.title != nil and session.title != "" then
        title = session.title
    end
    messages = agent.all_messages(db_path, session_id)
    transcript = build_session_transcript(messages)
    knowledge.sync_session_document(db_path, login, session_id, "Chat: " .. title, transcript)
end

-- research.investigate's own tool list: every non-destructive AGENT_TOOLS
-- entry except research itself -- excluded so a research sub-agent can't
-- recursively delegate to another one and spend turns/cost with no
-- bound the outer MAX_TURNS-style budget accounts for -- and except
-- clarify, since "ask the user a question" is a whole-turn decision that
-- belongs to the outer loop, not something a bounded sub-investigation
-- should be able to trigger on its own; a sub-investigation that can't
-- find something just reports that in its own finding instead -- and
-- except background, for the same reason: a bounded sub-investigation
-- shouldn't be able to spawn an unbounded one of its own. Destructive
-- tools are never declared here at all (rather than declared-then-refused)
-- so the model isn't even told they exist from inside a pass that's meant
-- to be read-only investigation, not a place a write could plausibly
-- come from.
function agent_tools.research_tool_declarations(db_path)
    declarations = {}
    for tool_name, methods in pairs(agent_tools.AGENT_TOOLS) do
        if tool_name != "research" and tool_name != "clarify" and tool_name != "background" then
            for method_name, spec in pairs(methods) do
                if spec.destructive == false then
                    table.insert(declarations, {
                        name = tool_name .. "." .. method_name,
                        description = spec.description,
                        parameters = spec.parameters,
                    })
                end
            end
        end
    end
    for _, entry in ipairs(extension.approved_with_tools(db_path, config.extensions_dir())) do
        for _, tool in ipairs(entry.manifest.capabilities.tools) do
            if tool.destructive != true then
                table.insert(declarations, {
                    name = entry.name .. "." .. tool.name,
                    description = tool.description,
                    parameters = tool.parameters,
                })
            end
        end
    end
    return declarations
end

-- The agent-driven distillation pass -- unlike knowledge.
-- review_retrieval (rule-based, runs automatically after every real
-- search), this is a genuine model call: actually read a candidate
-- document's full content (via entity.get, not just knowledge.list's
-- own summary) and write a new, concise, single-idea document distilled
-- from it (see doc/architecture.md's "Knowledge pool" section for the
-- older materialize/review pass this replaced). Not automatic on every
-- search -- a real, ongoing LLM cost for something that isn't
-- time-critical -- triggered explicitly via the CLI (`daat
-- knowledge distill`); knowledge.maybe_distill (see architecture.md's
-- "Reactive distillation" bullet) is the separate, automatic trigger
-- tied to real retrieval.
--
-- Deliberately just a normal chat session/turn, not a separate
-- pipeline: knowledge.distill is a destructive tool, so a call to it
-- here pauses for approval exactly like any user-initiated chat does
-- (agent.run_turn's own pending_approval path) -- a human still has to
-- approve every distillation from the resulting session in the normal
-- chat UI, same as any other destructive tool call.
KNOWLEDGE_DISTILL_SYSTEM_PROMPT = """
You are reviewing this deployment's knowledge pool: documents tiered by processing maturity, not just how often they've been looked up (tier 0 raw intake, tier 1 curated draft, tier 2 developed reference, tier 3 atomic record). A document only advances once it's actually been worked on and its content earns the shape a tier requires -- retrieval count and heat (from knowledge.list) just decide whether it's due for a fresh look, not which tier it lands in.

Use knowledge.list to see current pool documents: id, tier, content shape (developed / atomic / thin / simple), effective heat, retrieval count. For a document flagged "developed" (long, multi-section, covers more than one real idea), read its full content with entity.get (entity_type=document) and write ONE genuinely atomic, single-idea document distilled from it with knowledge.distill -- concise, self-contained, in your own words, not a verbatim copy of the source. Do not distill from a document that's already "atomic", "thin", or "simple" -- there's nothing worth extracting that isn't already there as-is.

Distilling nothing this pass is a completely acceptable outcome -- do not distill from a document you're unsure about; say why you're leaving it alone instead. When you're done, summarize what you reviewed and what you did (or didn't) distill.
"""

function agent_tools.run_knowledge_distillation(db_path, login, model)
    session_id, err = agent.create_session(db_path, login, "Knowledge Pool Distillation")
    if session_id == nil then
        return nil, err
    end
    result = agent.run_turn(db_path, session_id, login, KNOWLEDGE_DISTILL_SYSTEM_PROMPT, model,
        "Review the current knowledge pool and distill any documents that are genuinely ready.")
    return session_id, result
end

return agent_tools
