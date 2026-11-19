-- Deployment diagnostics and approval status (`daat status` / `daat doctor`
-- and the Admin `/system-status` page).
--
-- Never reads or exposes secret values: environment credentials are
-- reported only as boolean `present = true/false` indicators.

const agent_provider = require("agent_provider")
const config = require("config")
const curate = require("knowledge.curate")
const db = require("database")
const extension = require("extension")
const external_tool = require("external_tool")
const json = require("dkjson")
const paths = require("paths")
const schema = require("schema")
const store_lib = require("store")
const view = require("view")

const status = {}

function choose(cond, when_true, when_false)
    if cond == true then
        return when_true
    end
    return when_false
end

function default_val(val, fallback)
    if val == nil or val == "" then
        return fallback
    end
    return val
end

function env_present(name)
    val = os.getenv(name)
    return val != nil and val != ""
end

function describe_db_target(target)
    if type(target) == "table" then
        return tostring(target.host) .. ":" .. tostring(target.port) .. "/" .. tostring(target.database)
    end
    return tostring(target)
end

function count_where(db_path, table_name, where_sql)
    ok_tbl, exists_tbl = pcall(db.table_exists, db_path, table_name)
    if ok_tbl != true or exists_tbl != true then
        return 0
    end
    sql = "SELECT COUNT(*) AS n FROM " .. table_name
    if where_sql != nil and where_sql != "" then
        sql = sql .. " WHERE " .. where_sql
    end
    sql = sql .. ";"
    ok_q, rows = pcall(db.query, db_path, sql)
    if ok_q != true or rows == nil or rows[1] == nil then
        return 0
    end
    n = tonumber(rows[1].n)
    if n == nil then
        return 0
    end
    return n
end

function format_capabilities_summary(caps)
    if type(caps) != "table" then
        return "none"
    end
    parts = {}
    if type(caps.read) == "table" and #caps.read > 0 then
        table.insert(parts, "read: " .. table.concat(caps.read, ", "))
    end
    if type(caps.write) == "table" and #caps.write > 0 then
        table.insert(parts, "write: " .. table.concat(caps.write, ", "))
    end
    if type(caps.net) == "string" and caps.net != "none" and caps.net != "" then
        table.insert(parts, "net: " .. caps.net)
    elseif type(caps.net) == "table" and #caps.net > 0 then
        table.insert(parts, "net: " .. table.concat(caps.net, ", "))
    end
    if type(caps.ui) == "table" and type(caps.ui.label) == "string" then
        table.insert(parts, "ui: " .. caps.ui.label)
    end
    if type(caps.tools) == "table" and #caps.tools > 0 then
        tool_names = {}
        for _, t in ipairs(caps.tools) do
            if type(t) == "table" and type(t.name) == "string" then
                table.insert(tool_names, t.name)
            end
        end
        if #tool_names > 0 then
            table.insert(parts, "tools: " .. table.concat(tool_names, ", "))
        end
    end
    if type(caps.manual_triggers) == "table" and #caps.manual_triggers > 0 then
        trig_names = {}
        for _, tr in ipairs(caps.manual_triggers) do
            if type(tr) == "table" and type(tr.name) == "string" then
                table.insert(trig_names, tr.name)
            end
        end
        if #trig_names > 0 then
            table.insert(parts, "triggers: " .. table.concat(trig_names, ", "))
        end
    end
    if #parts == 0 then
        return "none (sandboxed before-hook only)"
    end
    return table.concat(parts, "; ")
end

function collect_binaries(conf)
    needs_curl = (conf.agent_provider == "vertex" or conf.agent_provider == "claude" or conf.agent_provider == "ollama" or
        conf.search_provider == "google_cse" or conf.mail_provider == "smtp" or conf.mail_provider == "graph")
    needs_attachments = (conf.chat_attachments_enabled == true)

    items = {
        {
            name = "cmark-gfm",
            required = true,
            available = external_tool.available("cmark-gfm"),
            purpose = "Document Markdown rendering",
        },
        {
            name = "curl",
            required = needs_curl,
            available = external_tool.available("curl"),
            purpose = "HTTP client for LLM, web search, and mail providers",
        },
        {
            name = "gnuplot",
            required = false,
            available = external_tool.available("gnuplot"),
            purpose = "Optional SVG chart rendering for ```plot blocks",
        },
        {
            name = "pdftotext",
            required = needs_attachments,
            available = external_tool.available("pdftotext"),
            purpose = "PDF text extraction for chat attachments",
        },
        {
            name = "pandoc",
            required = needs_attachments,
            available = external_tool.available("pandoc"),
            purpose = "DOCX/document text extraction for chat attachments",
        },
    }
    return items
end

function collect_providers(conf, settings, root)
    agent_info = {
        provider = default_val(conf.agent_provider, "off"),
        model = nil,
        embedding_model = nil,
        credential_status = "n/a",
        ok = true,
    }
    if conf.agent_provider != nil then
        if root == nil or root == "." then
            config.reset_cache()
            agent_info.model = agent_provider.model()
            agent_info.embedding_model = agent_provider.embedding_model()
        else
            agent_info.model = conf.agent_model
            agent_info.embedding_model = conf.embedding_model
        end
        if conf.agent_provider == "claude" then
            has_key = env_present("ANTHROPIC_API_KEY")
            agent_info.credential_status = choose(has_key, "ANTHROPIC_API_KEY set", "ANTHROPIC_API_KEY missing")
            agent_info.ok = has_key
        elseif conf.agent_provider == "vertex" then
            if settings.vertex_project != nil then
                agent_info.credential_status = "ADC (project: " .. tostring(settings.vertex_project) .. ")"
            else
                agent_info.credential_status = "agent.vertex_project missing"
                agent_info.ok = false
            end
        elseif conf.agent_provider == "ollama" then
            url = default_val(settings.ollama_url, "http://127.0.0.1:11434/v1")
            if env_present("OLLAMA_API_KEY") or env_present("OPENAI_API_KEY") then
                agent_info.credential_status = url .. " (API key set)"
            else
                agent_info.credential_status = url .. " (no API key)"
            end
        elseif conf.agent_provider == "test" then
            agent_info.credential_status = "deterministic test stub"
        end
    end

    search_info = {
        provider = default_val(conf.search_provider, "off"),
        credential_status = "n/a",
        ok = true,
    }
    if conf.search_provider == "google_cse" then
        has_k = env_present("GOOGLE_SEARCH_API_KEY")
        has_cx = env_present("GOOGLE_SEARCH_ENGINE_ID")
        if has_k and has_cx then
            search_info.credential_status = "GOOGLE_SEARCH_API_KEY + GOOGLE_SEARCH_ENGINE_ID set"
        else
            search_info.credential_status = "GOOGLE_SEARCH_API_KEY or GOOGLE_SEARCH_ENGINE_ID missing"
            search_info.ok = false
        end
    elseif conf.search_provider == "test" then
        search_info.credential_status = "deterministic test stub"
    end

    mail_info = {
        provider = default_val(conf.mail_provider, "off"),
        password_reset_enabled = config.password_reset_enabled(root),
        credential_status = "n/a",
        ok = true,
    }
    if conf.mail_provider == "smtp" then
        if settings.smtp_user != nil and settings.smtp_user != "" then
            has_pw = env_present("DAAT_SMTP_PASSWORD")
            mail_info.credential_status = choose(has_pw, "DAAT_SMTP_PASSWORD set", "DAAT_SMTP_PASSWORD missing")
            mail_info.ok = has_pw
        else
            mail_info.credential_status = "unauthenticated SMTP"
        end
    elseif conf.mail_provider == "graph" then
        has_sec = env_present("DAAT_GRAPH_CLIENT_SECRET")
        mail_info.credential_status = choose(has_sec, "DAAT_GRAPH_CLIENT_SECRET set", "DAAT_GRAPH_CLIENT_SECRET missing")
        mail_info.ok = has_sec
    elseif conf.mail_provider == "test" then
        mail_info.credential_status = "deterministic test outbox"
    end

    return {
        agent = agent_info,
        search = search_info,
        mail = mail_info,
    }
end

function collect_schemas_status(db_path, root)
    disk_files = schema.definition_files(db_path, root)
    registered = schema.list(db_path)
    reg_set = {}
    for _, r in ipairs(registered) do
        reg_set[r.name] = true
    end
    unregistered = {}
    invalid = {}
    for _, entry in ipairs(disk_files) do
        def, err = schema.load_file(entry.path)
        if def == nil then
            table.insert(invalid, {path = entry.path, error = tostring(err)})
        elseif reg_set[def.name] == nil then
            table.insert(unregistered, def.name)
        end
    end
    cur_sig = schema.content_signature(db_path, root)
    stored_sig = schema.stored_sync_signature(db_path)
    in_sync = (#unregistered == 0 and #invalid == 0 and (#disk_files == 0 or cur_sig == stored_sig))
    return {
        registered_count = #registered,
        disk_count = #disk_files,
        in_sync = in_sync,
        unregistered = unregistered,
        invalid = invalid,
    }
end

function collect_views_status(db_path, root)
    files = view.definition_files(db_path, root)
    items = {}
    for _, entry in ipairs(files) do
        def, err = view.load_file(entry.path)
        if def == nil then
            table.insert(items, {
                name = entry.name,
                title = "(invalid view file)",
                entity_type = "",
                sql = "",
                status = "invalid",
                error = tostring(err),
                path = entry.path,
            })
        else
            eff_sql = view.effective_sql(db_path, def)
            prev_sql = view.approved_sql(db_path, def.name)
            st = "unapproved"
            if view.is_approved(db_path, def) then
                st = "approved"
            elseif prev_sql != nil then
                st = "drifted"
            end
            sql_text = eff_sql
            if sql_text == nil then
                sql_text = default_val(def.sql, "")
            end
            table.insert(items, {
                name = def.name,
                title = default_val(def.title, def.name),
                entity_type = default_val(def.entity_type, ""),
                sql = sql_text,
                status = st,
                path = entry.path,
            })
        end
    end
    return items
end

function collect_extensions_status(db_path, root)
    ext_dir = config.extensions_dir(root)
    names = extension.names(ext_dir)
    items = {}
    for _, name in ipairs(names) do
        manifest, err = extension.load_manifest(ext_dir, name)
        if manifest == nil then
            table.insert(items, {
                name = name,
                events = {},
                entity_types = {},
                capabilities_summary = "(invalid manifest)",
                status = "invalid",
                error = tostring(err),
            })
        else
            prev_caps = extension.approved_capabilities(db_path, manifest.name)
            st = "unapproved"
            if extension.is_approved(db_path, manifest) then
                st = "approved"
            elseif prev_caps != nil then
                st = "drifted"
            end
            ev_list = {}
            if type(manifest.events) == "table" then
                ev_list = manifest.events
            end
            et_list = {}
            if type(manifest.entity_types) == "table" then
                et_list = manifest.entity_types
            end
            table.insert(items, {
                name = manifest.name,
                events = ev_list,
                entity_types = et_list,
                capabilities_summary = format_capabilities_summary(manifest.capabilities),
                status = st,
            })
        end
    end
    return items
end

function status.collect(db_path, root)
    if root == nil then
        root = config.find_root()
    end
    cfg_report = config.validate(root)
    conf = cfg_report.resolved
    initialized = config.is_initialized(root)
    if db_path == nil and initialized then
        db_path = config.db_path(root)
    end

    db_connected = false
    db_error = nil
    schema_version = nil
    if initialized and db_path != nil then
        ok_ping, ping_rows = pcall(db.query, db_path, "SELECT 1 AS ok;")
        if ok_ping == true and ping_rows != nil then
            db_connected = true
            ver_val = store_lib.get_number(db_path, "store.schema_version")
            schema_version = ver_val
        else
            db_error = tostring(ping_rows)
        end
    end

    db_cred_status = "n/a (SQLite file)"
    if conf.db_backend == "mariadb" then
        db_cred_status = choose(env_present("DAAT_MARIADB_PASSWORD"), "DAAT_MARIADB_PASSWORD set", "DAAT_MARIADB_PASSWORD missing")
    end

    binaries = collect_binaries(conf)
    providers = collect_providers(conf, cfg_report.settings, root)

    schemas_info = nil
    views_info = {}
    extensions_info = {}
    queues_info = nil
    if initialized and db_connected then
        schemas_info = collect_schemas_status(db_path, root)
        views_info = collect_views_status(db_path, root)
        extensions_info = collect_extensions_status(db_path, root)

        due_convs = 0
        ok_cur, conv_list = pcall(curate.due_conversations, db_path)
        if ok_cur == true and type(conv_list) == "table" then
            due_convs = #conv_list
        end
        queues_info = {
            embeddings_due = count_where(db_path, "document_embedding_due", nil),
            retrievals_unreviewed = count_where(db_path, "knowledge_retrieval", "reviewed_at IS NULL OR reviewed_at = ''"),
            extension_jobs_pending = count_where(db_path, "extension_job", "status IN ('pending', 'running')"),
            agent_background_pending = count_where(db_path, "agent_background_task", "status IN ('pending', 'running')"),
            conversations_due_curation = due_convs,
        }
    end

    issues = {}
    warnings = {}
    for _, e in ipairs(cfg_report.errors) do
        table.insert(issues, e)
    end
    for _, w in ipairs(cfg_report.warnings) do
        table.insert(warnings, w)
    end
    if initialized and not db_connected then
        table.insert(issues, "Database connection failed: " .. tostring(db_error))
    end
    for _, b in ipairs(binaries) do
        if b.required and not b.available then
            table.insert(issues, "Missing required runtime binary '" .. b.name .. "' (" .. b.purpose .. ")")
        end
    end
    if not providers.agent.ok then
        table.insert(warnings, "Agent provider credential incomplete: " .. providers.agent.credential_status)
    end
    if not providers.search.ok then
        table.insert(warnings, "Search provider credential incomplete: " .. providers.search.credential_status)
    end
    if not providers.mail.ok then
        table.insert(warnings, "Mail provider credential incomplete: " .. providers.mail.credential_status)
    end
    if schemas_info != nil then
        for _, inv in ipairs(schemas_info.invalid) do
            table.insert(issues, "Invalid schema file " .. inv.path .. ": " .. inv.error)
        end
        if not schemas_info.in_sync and #schemas_info.invalid == 0 then
            table.insert(warnings, "Schemas on disk have unapplied changes (run 'daat schema sync' or sync from /system-status)")
        end
    end
    for _, vw in ipairs(views_info) do
        if vw.status == "invalid" then
            table.insert(issues, "Invalid view '" .. vw.name .. "': " .. tostring(vw.error))
        elseif vw.status != "approved" then
            table.insert(warnings, string.format("View '%s' is %s (approve via 'daat view approve %s' or /system-status)", vw.name, vw.status, vw.name))
        end
    end
    for _, ex in ipairs(extensions_info) do
        if ex.status == "invalid" then
            table.insert(issues, "Invalid extension '" .. ex.name .. "': " .. tostring(ex.error))
        elseif ex.status != "approved" then
            table.insert(warnings, string.format("Extension '%s' is %s (approve via 'daat extension approve %s' or /system-status)", ex.name, ex.status, ex.name))
        end
    end

    return {
        ok = (#issues == 0),
        root = root,
        store = {
            initialized = initialized,
            backend = conf.db_backend,
            target = describe_db_target(config.db_path(root)),
            connected = db_connected,
            schema_version = schema_version,
            credential_status = db_cred_status,
        },
        config = {
            ok = cfg_report.ok,
            config_exists = cfg_report.config_exists,
            theme_exists = cfg_report.theme_exists,
            errors = cfg_report.errors,
            warnings = cfg_report.warnings,
        },
        providers = providers,
        binaries = binaries,
        schemas = schemas_info,
        views = views_info,
        extensions = extensions_info,
        queues = queues_info,
        issues = issues,
        warnings = warnings,
    }
end

function has_flag(cmd_args, flag)
    for _, a in ipairs(cmd_args) do
        if a == flag then
            return true
        end
    end
    return false
end

function status.do_status(cmd_args, root)
    if root == nil then
        root = "."
    end
    if has_flag(cmd_args, "-h") or has_flag(cmd_args, "--help") then
        print("Usage: daat status [--json]   (alias: daat doctor)")
        print("Inspects store initialization, database connectivity, config.lua/theme.lua")
        print("validity, provider credentials, runtime binaries, schema/view/extension")
        print("approval drift, and pending background queues.")
        return 0
    end

    rep = status.collect(nil, root)
    if has_flag(cmd_args, "--json") then
        print(json.encode(rep))
        if rep.ok then
            return 0
        end
        return 1
    end

    print("=== Store & Database ===")
    if rep.store.initialized then
        conn_tag = choose(rep.store.connected, "connected", "DISCONNECTED")
        print(string.format("  Status:     initialized (%s)", conn_tag))
        print(string.format("  Backend:    %s (%s)", rep.store.backend, rep.store.target))
        print(string.format("  Auth env:   %s", rep.store.credential_status))
        if rep.store.schema_version != nil then
            print(string.format("  Migration:  v%s", tostring(rep.store.schema_version)))
        end
    else
        print("  Status:     not initialized (run 'daat init' to create the store)")
        print(string.format("  Backend:    %s (%s)", rep.store.backend, rep.store.target))
    end

    print("\n=== Configuration ===")
    print(string.format("  config.lua: %s", choose(rep.config.config_exists, "present", "absent (defaults)")))
    print(string.format("  theme.lua:  %s", choose(rep.config.theme_exists, "present", "absent (defaults)")))

    print("\n=== Providers ===")
    ag = rep.providers.agent
    print(string.format("  Agent:      %s (model: %s, embedding: %s, auth: %s)",
        ag.provider, default_val(ag.model, "-"), default_val(ag.embedding_model, "-"), ag.credential_status))
    print(string.format("  Search:     %s (auth: %s)", rep.providers.search.provider, rep.providers.search.credential_status))
    ml = rep.providers.mail
    reset_str = choose(ml.password_reset_enabled, "enabled", "disabled")
    print(string.format("  Mail:       %s (password reset: %s, auth: %s)", ml.provider, reset_str, ml.credential_status))

    print("\n=== Runtime Binaries ===")
    for _, b in ipairs(rep.binaries) do
        state = "not installed (optional)"
        if b.available then
            state = "found"
        elseif b.required then
            state = "MISSING (required)"
        end
        print(string.format("  %-12s %-26s %s", b.name, state, b.purpose))
    end

    if rep.schemas != nil then
        print("\n=== Schemas, Views & Extensions ===")
        sync_label = choose(rep.schemas.in_sync, "in sync", "OUT OF SYNC (run 'daat schema sync')")
        print(string.format("  Schemas:    %d registered, %d file(s) on disk (%s)",
            rep.schemas.registered_count, rep.schemas.disk_count, sync_label))
        print(string.format("  Views:      %d on disk", #rep.views))
        for _, vw in ipairs(rep.views) do
            print(string.format("    - %-24s [%s]", vw.name, vw.status))
        end
        print(string.format("  Extensions: %d on disk", #rep.extensions))
        for _, ex in ipairs(rep.extensions) do
            print(string.format("    - %-24s [%s] (%s)", ex.name, ex.status, ex.capabilities_summary))
        end
    end

    if rep.queues != nil then
        print("\n=== Pending Queues ===")
        print(string.format("  Embeddings due:             %d", rep.queues.embeddings_due))
        print(string.format("  Unreviewed retrievals:      %d", rep.queues.retrievals_unreviewed))
        print(string.format("  Extension jobs:             %d", rep.queues.extension_jobs_pending))
        print(string.format("  Background agent tasks:     %d", rep.queues.agent_background_pending))
        print(string.format("  Conversations due curation: %d", rep.queues.conversations_due_curation))
    end

    if #rep.warnings > 0 or #rep.issues > 0 then
        print("\n=== Diagnostics ===")
        for _, w in ipairs(rep.warnings) do
            print("  WARNING: " .. w)
        end
        for _, iss in ipairs(rep.issues) do
            print("  ERROR:   " .. iss)
        end
    end

    print("")
    if rep.ok then
        print(string.format("Overall: HEALTHY (%d warning(s))", #rep.warnings))
        return 0
    end
    print(string.format("Overall: ISSUES FOUND (%d error(s), %d warning(s))", #rep.issues, #rep.warnings))
    return 1
end

return status
