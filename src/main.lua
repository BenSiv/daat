if package.preload["config"] == nil then
    package.path = "src/?.lua;" .. package.path
end

config = require("config")

init = require("init")
do_init = init.do_init

schema = require("schema")
do_schema = schema.do_schema

entity = require("entity")
do_entity = entity.do_entity
do_extension = entity.do_extension

ledger = require("ledger")
do_ledger = ledger.do_ledger

view = require("view")
do_view = view.do_view

auth = require("auth")
do_user = auth.do_user
do_api_key = auth.do_api_key

document = require("document")
do_document = document.do_document

knowledge = require("knowledge")
do_knowledge = knowledge.do_knowledge
repair = require("repair")
do_repair = repair.do_repair
tag_upkeep = require("tag_upkeep")
do_tag = tag_upkeep.do_tag

-- Required explicitly here (not left to load transitively via cgi's
-- own require) since knowledge.lua can't require agent.lua back itself
-- (agent.lua already requires knowledge.lua; a real circular require,
-- not just an ordering nuisance) -- the one thing that needs both,
-- `daat knowledge distill`, is dispatched from here instead of
-- inside knowledge.do_knowledge.
agent = require("agent")
agent_tools = require("agent_tools")

cgi = require("cgi")

function main()
    -- Check if running in CGI environment
    gateway = os.getenv("GATEWAY_INTERFACE")
    method = os.getenv("REQUEST_METHOD")
    is_cgi = (gateway != nil and gateway != "") or (method != nil and method != "")

    if is_cgi then
        ok, err = pcall(cgi.handle_request)
        if not ok then
            io.write("Status: 500 Internal Server Error\r\n")
            io.write("Content-Type: text/plain\r\n\r\n")
            io.write("Internal Server Error: " .. tostring(err) .. "\n")
        end
        return
    end

    command_funcs = {
        ["init"] = do_init,
        ["schema"] = do_schema,
        ["entity"] = do_entity,
        ["ledger"] = do_ledger,
        ["extension"] = do_extension,
        ["view"] = do_view,
        ["user"] = do_user,
        ["api-key"] = do_api_key,
        ["document"] = do_document,
        ["knowledge"] = do_knowledge,
        ["repair"] = do_repair,
        ["tag"] = do_tag,
    }

    arg[-1] = "lua"
    command = arg[1]

    if command != nil then
        arg[0] = "daat " .. command
    else
        arg[0] = "daat"
    end

    if command == nil or command == "-h" or command == "--help" then
        print("Usage: daat <init|schema|entity|ledger|extension|view|user|api-key|document|knowledge|agent|repair|tag> ...")
        return
    end

    -- Every command on an existing store brings its tables to the
    -- current layout first (see store.lua's header); `init` does it
    -- itself once the store exists.
    if command != "init" and config.is_initialized(".") then
        require("store").migrate(config.db_path("."))
    end

    -- "agent" has no command_funcs entry of its own, so its
    -- subcommands are special-cased here,
    -- before the generic command_funcs lookup below, the same reason
    -- "knowledge distill" further down is dispatched outside of
    -- knowledge.do_knowledge instead of through it: see the
    -- require("agent") comment above main(). Meant to be invoked
    -- periodically (cron/systemd timer), the same way system_job's
    -- own "daat extension run-pending" already is.
    if command == "agent" and arg[2] == "run-pending-background" then
        if config.is_initialized(".") == false then
            print("Not initialized. Run 'daat init' first.")
            return
        end
        db_path = config.db_path(".")
        -- This can run before any web request after a deploy (it's on a
        -- timer), so it brings the tables it writes up to date itself
        -- rather than relying on cgi.handle_request having done it.
        agent.init_schema(db_path)
        result = agent.run_pending_background_tasks(db_path, agent.default_model())
        print(string.format("Ran %d, failed %d", result.ran, result.failed))
        return
    end

    -- Every retention rule, for the jobs timer: stored prompts past
    -- prompt_retention_days, passage embeddings unused for
    -- passage_cache_days. `agent prune-prompts` is the old name (kept for
    -- one release, while the startup script switches over).
    if (command == "store" and arg[2] == "prune") or (command == "agent" and arg[2] == "prune-prompts") then
        if config.is_initialized(".") == false then
            print("Not initialized. Run 'daat init' first.")
            return
        end
        db_path = config.db_path(".")
        agent.init_schema(db_path)
        passage = require("passage")
        passage.init_schema(db_path)
        conf = config.platform_config()
        cleared = agent.prune_prompts(db_path, conf.prompt_retention_days)
        print(string.format("Cleared %d stored prompts older than %s days", cleared, tostring(conf.prompt_retention_days)))
        deleted = passage.prune_cache(db_path, conf.passage_cache_days)
        print(string.format("Deleted %d passage embeddings unused for %s days", deleted, tostring(conf.passage_cache_days)))
        return
    end

    -- Read-only usage report: how big the agent's context gets and what
    -- fills it (src/context_report.lua, doc/context-management-plan.md).
    if command == "agent" and arg[2] == "context-report" then
        if config.is_initialized(".") == false then
            print("Not initialized. Run 'daat init' first.")
            return
        end
        since = nil
        if arg[3] == "--since" then
            since = arg[4]
            if since == nil or string.match(since, "^%d%d%d%d%-%d%d%-%d%d$") == nil then
                print("Usage: daat agent context-report [--since YYYY-MM-DD]")
                return
            end
        elseif arg[3] != nil then
            print("Usage: daat agent context-report [--since YYYY-MM-DD]")
            return
        end
        context_report = require("context_report")
        print(context_report.build(config.db_path("."), since))
        return
    end

    -- The detached-turn worker (agent.spawn_turn_worker starts it from
    -- the web request): runs one session's turn to its end.
    if command == "agent" and arg[2] == "continue" then
        if arg[3] == nil then
            print("Usage: daat agent continue <session_id>")
            return
        end
        if config.is_initialized(".") == false then
            print("Not initialized. Run 'daat init' first.")
            return
        end
        db_path = config.db_path(".")
        agent.init_schema(db_path)
        result, err = agent.continue_turn(db_path, arg[3], agent.default_model())
        if result == nil then
            print("Error: " .. tostring(err))
            return
        end
        print(string.format("Turn %s: %s", arg[3], tostring(result.status)))
        return
    end

    func = command_funcs[command]
    if func == nil then
        print("'" .. command .. "' is not a valid command")
        return
    end

    cmd_args = {}
    for i = 2, #arg do
        table.insert(cmd_args, arg[i])
    end
    cmd_args[0] = arg[0]

    if command == "init" then
        func(cmd_args)
        return
    end

    if config.is_initialized(".") == false then
        print("Not initialized. Run 'daat init' first.")
        return
    end

    db_path = config.db_path(".")

    -- Dispatched here, not inside knowledge.do_knowledge -- see the
    -- require("agent") comment above for why.
    if command == "knowledge" and cmd_args[1] == "distill" then
        session_id, result = agent_tools.run_knowledge_distillation(db_path, os.getenv("USER"), agent.default_model())
        if session_id == nil then
            print("Error: " .. tostring(result))
            return
        end
        print("Distillation session: " .. tostring(session_id))
        print("Status: " .. tostring(result.status))
        if result.status == "pending_approval" then
            print("Proposed: " .. tostring(result.tool) .. "." .. tostring(result.method) ..
                " (pending action #" .. tostring(result.pending_id) .. ") -- approve/deny from the chat UI")
        else
            print(tostring(result.message))
        end
        return
    end

    func(cmd_args, db_path)
end

main()
