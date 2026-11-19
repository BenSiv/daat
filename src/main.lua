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
const curate_lib = require("knowledge.curate")
const serve_lib = require("serve")
const status_lib = require("status")
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

function do_run_pending(cmd_args, db_path)
    curate_limit = 3
    do_prune = false
    idx = 1
    while idx <= #cmd_args do
        a = cmd_args[idx]
        if a == "-h" or a == "--help" then
            print("Usage: daat run-pending [--curate-limit N] [--prune]")
            print("Drains all background queues in order: extension after-hooks, pending")
            print("document embeddings, deferred retrieval reviews, due chat curations, and")
            print("pending background agent tasks (plus retention pruning with --prune).")
            return 0
        elseif a == "--curate-limit" then
            n = tonumber(cmd_args[idx + 1])
            if n == nil or n < 0 then
                print("Usage: daat run-pending [--curate-limit N] [--prune]")
                return 1
            end
            curate_limit = math.floor(n)
            idx = idx + 2
        elseif a == "--prune" then
            do_prune = true
            idx = idx + 1
        else
            print("Usage: daat run-pending [--curate-limit N] [--prune]")
            return 1
        end
    end

    ext_res = entity.run_pending_jobs(db_path)
    print(string.format("extensions: ran %d, failed %d", ext_res.ran, ext_res.failed))

    emb_res = document.embed_pending(db_path)
    print(string.format("embeddings: embedded %d, unchanged %d, failed %d, dropped %d, waiting %d",
        emb_res.embedded, emb_res.unchanged, emb_res.failed, emb_res.dropped, emb_res.waiting))
    for _, line in ipairs(emb_res.upkeep) do
        print("  tag upkeep: " .. line)
    end

    rev_lines = knowledge.run_pending_reviews(db_path, nil)
    print(string.format("reviews: %d item(s)", #rev_lines))
    for _, line in ipairs(rev_lines) do
        print("  " .. line)
    end

    cur_lines = curate_lib.run_pending(db_path, curate_limit, "system")
    print(string.format("curation: %d item(s)", #cur_lines))
    for _, line in ipairs(cur_lines) do
        print("  " .. line)
    end

    agent.init_schema(db_path)
    bg_res = agent.run_pending_background_tasks(db_path, agent.default_model())
    print(string.format("agent_background: ran %d, failed %d", bg_res.ran, bg_res.failed))

    if do_prune then
        run_prune(db_path)
    end
    return 0
end

const COMMAND_HELP = {
    ["init"] = "Usage: daat init [--with-examples]\nInitialize a new Daat store in the current directory.",
    ["config"] = "Usage: daat config <show|check> [--json]\nInspect effective settings or validate config.lua and theme.lua.",
    ["status"] = "Usage: daat status [--json]   (alias: daat doctor)\nCheck store, database, configuration, provider auth, binaries, approvals, and queues.",
    ["doctor"] = "Usage: daat doctor [--json]   (alias: daat status)\nCheck store, database, configuration, provider auth, binaries, approvals, and queues.",
    ["serve"] = "Usage: daat serve [--port 8000] [--host 127.0.0.1] [--once]\nStart a local HTTP-to-CGI development server for the current store.",
    ["user"] = "Usage: daat user <add|list|passwd|capabilities|email|archive|unarchive> ...\nManage user accounts, passwords, email addresses, and capabilities (i/s/a).",
    ["api-key"] = "Usage: daat api-key <create|list|capabilities|archive|unarchive> ...\nManage HTTP API keys for external integrations (/api/v1/*).",
    ["schema"] = "Usage: daat schema <add|sync|list|show> ...\nRegister or sync declarative entity schemas and dropdowns from disk.",
    ["entity"] = "Usage: daat entity <create|create-json|update|archive|unarchive|get|list> ...\nCreate, update, archive, or inspect typed entity records.",
    ["ledger"] = "Usage: daat ledger <history|verify> ...\nInspect append-only entity event history.",
    ["view"] = "Usage: daat view <list|show|approve|revoke|run> ...\nInspect, approve, revoke, or run read-only saved SQL views.",
    ["extension"] = "Usage: daat extension <list|show|approve|revoke|run-pending> ...\nInspect, approve, revoke, or run sandboxed extensions.",
    ["document"] = "Usage: daat document <create-json|embed-pending|embedding-text> ...\nBulk-import documents, process queued embeddings, or inspect embedded text.",
    ["knowledge"] = "Usage: daat knowledge <stats|list|show|review-pending|curate-pending|synthesize-due|distill-due|distill|promote|link-score> ...\nInspect and advance the self-maintaining Knowledge Pool.",
    ["tag"] = "Usage: daat tag <list|show|build|define|broader|merge|split|relabel> ...\nBuild, inspect, and maintain the tag ontology.",
    ["agent"] = "Usage: daat agent <run-pending-background|prune-prompts|context-report|continue> ...\nRun background agent tasks, inspect context metrics, or resume detached turns.",
    ["run-pending"] = "Usage: daat run-pending [--curate-limit N] [--prune]\nDrain all background queues (extensions, embeddings, reviews, curation, agent tasks) in one command.",
    ["repair"] = "Usage: daat repair <links|embeddings|embeddings-packed|aspects|pool-count|knowledge|references|duplicates|tags|curate|synthesize|distill> ...\nBackfill or rebuild derived indexes, embeddings, links, aspects, and tags.",
    ["store"] = "Usage: daat store <prune|verify> [--json]\nApply data-retention pruning rules or verify full ledger/pool invariants.",
}

function print_top_help()
    print("Usage: daat <command> [args...]")
    print("")
    print("Setup & Local Development:")
    print("  init          Initialize a store (--with-examples for starter files)")
    print("  config        Validate or inspect config.lua and theme.lua (<check|show>)")
    print("  status        Run deployment health & approval diagnostics (alias: doctor)")
    print("  serve         Start a local HTTP-to-CGI browser server (--port 8000)")
    print("")
    print("Accounts & Access:")
    print("  user          Manage user logins, passwords, and capabilities")
    print("  api-key       Manage external-integration API keys")
    print("")
    print("Schemas, Data & Extensibility:")
    print("  schema        Register, sync, and inspect entity schemas")
    print("  entity        Create, update, archive, and list entity records")
    print("  ledger        Inspect append-only audit event history")
    print("  view          Inspect, approve, revoke, and run saved SQL views")
    print("  extension     Inspect, approve, revoke, and run sandboxed extensions")
    print("")
    print("Knowledge Pool & Maintenance:")
    print("  document      Import documents and run pending embeddings")
    print("  knowledge     Inspect tiers/heat and run curation/synthesis/distillation")
    print("  tag           Build and maintain the tag ontology")
    print("  agent         Manage background agent tasks and context reports")
    print("  run-pending   Drain all background queues in one cron/worker command")
    print("  repair        Rebuild or backfill derived indexes and embeddings")
    print("  store         Prune expired operational logs or verify store invariants")
    print("")
    print("Run 'daat <command> --help' for details on any command.")
end

const COMMAND_FUNCS = {
    ["init"] = do_init,
    ["config"] = config.do_config,
    ["status"] = status_lib.do_status,
    ["doctor"] = status_lib.do_status,
    ["serve"] = serve_lib.do_serve,
    ["run-pending"] = do_run_pending,
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
        print_top_help()
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

    -- Every `daat <command> --help` works without requiring an initialized store.
    if cmd_args[1] == "-h" or cmd_args[1] == "--help" then
        if command == "init" or command == "config" or command == "status" or command == "doctor" or command == "serve" then
            return func(cmd_args, ".")
        end
        if COMMAND_HELP[command] != nil then
            print(COMMAND_HELP[command])
            return 0
        end
    end

    if command == "init" then
        return func(cmd_args)
    end

    if command == "config" or command == "status" or command == "doctor" or command == "serve" then
        return func(cmd_args, ".")
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
