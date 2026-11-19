if package.preload["config"] == nil then
    package.path = "src/?.lua;" .. package.path
end

const config = require("config")

const init = require("init")
const do_init = init.do_init

const schema = require("schema")
const do_schema = schema.do_schema

const entity = require("entity")
const do_entity = entity.do_entity
const do_extension = entity.do_extension

const ledger = require("ledger")
const do_ledger = ledger.do_ledger

const view = require("view")
const do_view = view.do_view

const auth = require("auth")
const do_user = auth.do_user
const do_api_key = auth.do_api_key

const document = require("document")
const do_document = document.do_document

const knowledge = require("knowledge")
const do_knowledge = knowledge.do_knowledge
const repair = require("repair")
const do_repair = repair.do_repair
const tag_cli = require("tag.cli")
const do_tag = tag_cli.do_tag

-- Required explicitly here since knowledge.lua does not require agent.lua
-- (`daat knowledge distill` bridges both).
const agent = require("agent")
const agent_tools = require("agent_tools")

const cgi = require("cgi")
const web = require("web")
const db = require("database")
const store = require("store")
const passage = require("document.passage")
const verify = require("verify")
const context_report = require("context_report")

function run_prune(db_path)
    agent.init_schema(db_path)
    passage.init_schema(db_path)
    conf = config.load()
    pruned = agent.prune_retention(db_path, conf)
    policy = pruned.policy
    mi_label = "(kept forever)"
    if policy.model_input_days == 0 then
        mi_label = "(not stored, 0 days)"
    elseif type(policy.model_input_days) == "number" then
        mi_label = string.format("older than %s days", tostring(policy.model_input_days))
    end
    tt_label = "(kept forever)"
    if type(policy.tool_trace_days) == "number" then
        tt_label = string.format("older than %s days", tostring(policy.tool_trace_days))
    end
    kn_label = "(kept forever)"
    if type(policy.knowledge_days) == "number" then
        kn_label = string.format("older than %s days after curation", tostring(policy.knowledge_days))
    end
    mt_label = "(kept forever)"
    if type(policy.metrics_days) == "number" then
        mt_label = string.format("older than %s days", tostring(policy.metrics_days))
    end
    print(string.format("Retention strategy: %s", tostring(pruned.strategy)))
    print(string.format("model_input: Cleared %d stored prompts %s", pruned.model_input, mi_label))
    print(string.format("tool_trace: Stubbed %d tool results %s", pruned.tool_trace, tt_label))
    print(string.format("knowledge: Removed %d raw knowledge rows %s", pruned.knowledge, kn_label))
    print(string.format("metrics: Removed %d metrics and control rows %s", pruned.metrics, mt_label))
    deleted = passage.prune_cache(db_path, conf.passage_cache_days)
    print(string.format("passage_cache: Deleted %d passage embeddings unused for %s days", deleted, tostring(conf.passage_cache_days)))
    return 0
end

function do_store(cmd_args, db_path)
    sub = cmd_args[1]
    if sub == "prune" then
        return run_prune(db_path)
    end
    if sub == "verify" then
        if not verify.do_verify(cmd_args, db_path) then
            return 1
        end
        return 0
    end
    print("Usage: daat store <prune|verify> [--json]")
    return 1
end

function do_agent(cmd_args, db_path)
    sub = cmd_args[1]
    if sub == "run-pending-background" then
        agent.init_schema(db_path)
        result = agent.run_pending_background_tasks(db_path, agent.default_model())
        print(string.format("Ran %d, failed %d", result.ran, result.failed))
        return 0
    end
    if sub == "prune-prompts" then
        return run_prune(db_path)
    end
    if sub == "context-report" then
        since = nil
        if cmd_args[2] == "--since" then
            since = cmd_args[3]
            if since == nil or string.match(since, "^%d%d%d%d%-%d%d%-%d%d$") == nil then
                print("Usage: daat agent context-report [--since YYYY-MM-DD]")
                return 1
            end
        elseif cmd_args[2] != nil then
            print("Usage: daat agent context-report [--since YYYY-MM-DD]")
            return 1
        end
        print(context_report.build(db_path, since))
        return 0
    end
    if sub == "continue" then
        if cmd_args[2] == nil then
            print("Usage: daat agent continue <session_id>")
            return 1
        end
        agent.init_schema(db_path)
        result, err = agent.continue_turn(db_path, cmd_args[2], agent.default_model())
        if result == nil then
            print("Error: " .. tostring(err))
            return 1
        end
        print(string.format("Turn %s: %s", cmd_args[2], tostring(result.status)))
        return 0
    end
    print("Usage: daat agent <run-pending-background|prune-prompts|context-report|continue> ...")
    return 1
end

function do_knowledge_dispatch(cmd_args, db_path)
    if cmd_args[1] == "distill" then
        session_id, result = agent_tools.run_knowledge_distillation(db_path, os.getenv("USER"), agent.default_model())
        if session_id == nil then
            print("Error: " .. tostring(result))
            return 1
        end
        print("Distillation session: " .. tostring(session_id))
        print("Status: " .. tostring(result.status))
        if result.status == "pending_approval" then
            print("Proposed: " .. tostring(result.tool) .. "." .. tostring(result.method) ..
                " (pending action #" .. tostring(result.pending_id) .. ") -- approve/deny from the chat UI")
        else
            print(tostring(result.message))
        end
        return 0
    end
    do_knowledge(cmd_args, db_path)
    return 0
end

const COMMAND_FUNCS = {
    ["init"] = do_init,
    ["schema"] = do_schema,
    ["entity"] = do_entity,
    ["ledger"] = do_ledger,
    ["extension"] = do_extension,
    ["view"] = do_view,
    ["user"] = do_user,
    ["api-key"] = do_api_key,
    ["document"] = do_document,
    ["knowledge"] = do_knowledge_dispatch,
    ["repair"] = do_repair,
    ["tag"] = do_tag,
    ["store"] = do_store,
    ["agent"] = do_agent,
}

function run_main()
    if cgi.is_cgi() then
        ok, err = pcall(web.handle_request)
        if not ok then
            cgi.respond_error(err)
        end
        return 0
    end

    arg[-1] = "lua"
    command = arg[1]

    if command != nil then
        arg[0] = "daat " .. command
    else
        arg[0] = "daat"
    end

    if command == nil or command == "-h" or command == "--help" then
        print("Usage: daat <init|schema|entity|ledger|extension|view|user|api-key|document|knowledge|agent|repair|tag|store> ...")
        if command == nil then
            return 1
        end
        return 0
    end

    func = COMMAND_FUNCS[command]
    if func == nil then
        print("'" .. command .. "' is not a valid command")
        return 1
    end

    cmd_args = {}
    for i = 2, #arg do
        table.insert(cmd_args, arg[i])
    end
    cmd_args[0] = arg[0]

    if command == "init" then
        func(cmd_args)
        return 0
    end

    -- Usage errors that precede store checks (e.g. `daat agent continue`
    -- with no session_id before `daat init`).
    if command == "agent" and cmd_args[1] == "continue" and cmd_args[2] == nil then
        print("Usage: daat agent continue <session_id>")
        return 1
    end

    if config.is_initialized(".") == false then
        print("Not initialized. Run 'daat init' first.")
        return 1
    end

    db_path = config.db_path(".")
    store.migrate(db_path)

    code = func(cmd_args, db_path)
    if type(code) == "number" then
        return code
    end
    return 0
end

function main()
    db.sqlite_keep_open(true)
    ok_run, result_or_err = pcall(run_main)
    db.sqlite_close_all()
    if not ok_run then
        error(result_or_err, 0)
    end
    if type(result_or_err) == "number" and result_or_err != 0 then
        os.exit(result_or_err)
    end
end

main()
