-- Extension manifest loading, content-pinned approval registry, and after-hook job queue.
-- Does not require entity (avoids cycle; callers pass built ctx). See doc/extensibility.md.

const db = require("database")
const json = require("dkjson")
const paths = require("paths")
const lfs = require("lfs")
const sandbox = require("sandbox")
const config = require("config")
const store_lib = require("store")

const extension = {}

extension.SCHEMA = """
CREATE TABLE IF NOT EXISTS system_job (
    job_id INTEGER PRIMARY KEY %s,
    extension_name TEXT NOT NULL,
    event_name TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id INTEGER NOT NULL,
    new_values_json TEXT,
    old_values_json TEXT,
    status VARCHAR(32) NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at TEXT DEFAULT (%s),
    updated_at TEXT DEFAULT (%s)
);
"""

function extension_schema_sql(db_path)
    return string.format(extension.SCHEMA,
        db.autoincrement_keyword(db_path),
        db.now_expr(db_path), db.now_expr(db_path)
    )
end

-- Run DDL once per process/DB: MariaDB CREATE TABLE IF NOT EXISTS commits open transactions.
const extension_schema_ready = {}

function extension_schema_key(db_path)
    return db.cache_key(db_path)
end

function extension.init_schema(db_path)
    key = extension_schema_key(db_path)
    if extension_schema_ready[key] == true then
        return true
    end
    store_lib.ensure_system_tables(db_path)
    result = db.exec(db_path, extension_schema_sql(db_path))
    extension_schema_ready[key] = true
    return result
end

function extension.names(ext_dir)
    names = {}
    attr = lfs.attributes(ext_dir)
    if attr == nil or attr.mode != "directory" then
        return names
    end
    for dir_name in lfs.dir(ext_dir) do
        if dir_name != "." and dir_name != ".." then
            manifest_path = paths.joinpath(ext_dir, dir_name, "manifest.lua")
            main_path = paths.joinpath(ext_dir, dir_name, "main.lua")
            if paths.file_exists(manifest_path) and paths.file_exists(main_path) then
                table.insert(names, dir_name)
            end
        end
    end
    return names
end

-- Lazy require avoids cycle with agent_tools; prevents extension tool namespace collisions.
function extension.is_reserved_tool_name(name)
    return require("agent_tools").AGENT_TOOLS[name] != nil
end

const OWNED_NAME_PATTERNS = {
    schemas = "^[a-z_][a-z0-9_]*$",
    views = "^[a-z0-9_][a-z0-9_-]*$",
}

function extension.validate_manifest(manifest)
    if type(manifest.name) != "string" or manifest.name == "" then
        return "manifest must have a non-empty string 'name'"
    end
    if not config.valid_resource_name(manifest.name) then
        return "manifest '" .. tostring(manifest.name) .. "' has an invalid extension name"
    end
    if type(manifest.events) != "table" then
        return "manifest '" .. tostring(manifest.name) .. "' must have an 'events' list"
    end
    if type(manifest.entity_types) != "table" then
        return "manifest '" .. tostring(manifest.name) .. "' must have an 'entity_types' list"
    end
    if manifest.capabilities != nil and type(manifest.capabilities) != "table" then
        return "manifest '" .. tostring(manifest.name) .. "': 'capabilities' must be a table"
    end
    if manifest.capabilities != nil and manifest.capabilities.ui != nil then
        ui = manifest.capabilities.ui
        if type(ui) != "table" then
            return "manifest '" .. tostring(manifest.name) .. "': capabilities.ui must be a table"
        end
        if type(ui.label) != "string" or ui.label == "" then
            return "manifest '" .. tostring(manifest.name) .. "': capabilities.ui must have a non-empty string 'label'"
        end
        if type(ui.icon) != "string" or ui.icon == "" then
            return "manifest '" .. tostring(manifest.name) .. "': capabilities.ui must have a non-empty string 'icon'"
        end
    end
    if manifest.capabilities != nil and manifest.capabilities.tools != nil then
        if extension.is_reserved_tool_name(manifest.name) then
            return "manifest '" .. tostring(manifest.name) .. "': extension name collides with a built-in tool group"
        end
        if type(manifest.capabilities.tools) != "table" then
            return "manifest '" .. tostring(manifest.name) .. "': capabilities.tools must be a list"
        end
        for _, tool in ipairs(manifest.capabilities.tools) do
            if type(tool) != "table" then
                return "manifest '" .. tostring(manifest.name) .. "': capabilities.tools entries must be tables"
            end
            if type(tool.name) != "string" or tool.name == "" then
                return "manifest '" .. tostring(manifest.name) .. "': capabilities.tools entry must have a non-empty string 'name'"
            end
            if type(tool.description) != "string" or tool.description == "" then
                return "manifest '" .. tostring(manifest.name) .. "': capabilities.tools entry '" .. tool.name .. "' must have a non-empty string 'description'"
            end
            if type(tool.parameters) != "table" then
                return "manifest '" .. tostring(manifest.name) .. "': capabilities.tools entry '" .. tool.name .. "' must have a 'parameters' table"
            end
        end
    end
    for _, kind in ipairs({"schemas", "views"}) do
        if manifest.capabilities != nil and manifest.capabilities[kind] != nil then
            owned = manifest.capabilities[kind]
            if type(owned) != "table" then
                return "manifest '" .. tostring(manifest.name) .. "': capabilities." .. kind .. " must be a list"
            end
            for _, owned_name in ipairs(owned) do
                if type(owned_name) != "string" or string.match(owned_name, OWNED_NAME_PATTERNS[kind]) == nil then
                    return "manifest '" .. tostring(manifest.name) .. "': capabilities." .. kind .. " entry '" .. tostring(owned_name) .. "' is not a valid name"
                end
            end
        end
    end
    if manifest.capabilities != nil and manifest.capabilities.manual_triggers != nil then
        if type(manifest.capabilities.manual_triggers) != "table" then
            return "manifest '" .. tostring(manifest.name) .. "': capabilities.manual_triggers must be a list"
        end
        for _, trigger in ipairs(manifest.capabilities.manual_triggers) do
            if type(trigger) != "table" then
                return "manifest '" .. tostring(manifest.name) .. "': capabilities.manual_triggers entries must be tables"
            end
            if type(trigger.name) != "string" or trigger.name == "" then
                return "manifest '" .. tostring(manifest.name) .. "': capabilities.manual_triggers entry must have a non-empty string 'name'"
            end
            if type(trigger.label) != "string" or trigger.label == "" then
                return "manifest '" .. tostring(manifest.name) .. "': capabilities.manual_triggers entry '" .. trigger.name .. "' must have a non-empty string 'label'"
            end
            if type(trigger.description) != "string" or trigger.description == "" then
                return "manifest '" .. tostring(manifest.name) .. "': capabilities.manual_triggers entry '" .. trigger.name .. "' must have a non-empty string 'description'"
            end
        end
    end
    return nil
end

function extension.load_manifest(ext_dir, name)
    if not config.valid_resource_name(name) then
        return nil, "invalid extension name: " .. tostring(name)
    end
    manifest_path = paths.joinpath(ext_dir, name, "manifest.lua")
    source = paths.read_file(manifest_path)
    if source == nil then
        return nil, "cannot open manifest: " .. manifest_path
    end
    ok, result = sandbox.run(source, manifest_path, sandbox.data_env())
    if ok == false or type(result) != "table" then
        return nil, "error loading manifest " .. manifest_path .. ": " .. tostring(result)
    end
    err = extension.validate_manifest(result)
    if err != nil then
        return nil, err
    end
    return result
end

function extension.load_main_source(ext_dir, name)
    if not config.valid_resource_name(name) then
        return nil, "invalid extension name: " .. tostring(name)
    end
    main_path = paths.joinpath(ext_dir, name, "main.lua")
    source = paths.read_file(main_path)
    if source == nil then
        return nil, "cannot open main.lua: " .. main_path
    end
    return source
end

function extension.all(ext_dir)
    result = {}
    for _, name in ipairs(extension.names(ext_dir)) do
        manifest, err = extension.load_manifest(ext_dir, name)
        table.insert(result, {name = name, manifest = manifest, err = err})
    end
    return result
end

-- Schema/view files declared by approved extensions; unapproved extensions own nothing.
function extension.owned_definitions(db_path, ext_dir, kind)
    result = {}
    for _, entry in ipairs(extension.all(ext_dir)) do
        if entry.manifest != nil and entry.manifest.capabilities != nil
           and entry.manifest.capabilities[kind] != nil
           and extension.is_approved(db_path, entry.manifest) then
            for _, owned_name in ipairs(entry.manifest.capabilities[kind]) do
                table.insert(result, {
                    name = owned_name,
                    extension = entry.manifest.name,
                    path = paths.joinpath(ext_dir, entry.name, kind, owned_name .. ".lua"),
                })
            end
        end
    end
    return result
end

-- Merges root definitions with approved extension definitions; duplicate names error.
function extension.definition_files(db_path, dir, ext_dir, kind, dir_required)
    files = {}
    owner_of = {}
    attr = lfs.attributes(dir)
    if attr != nil and attr.mode == "directory" then
        for file_name in lfs.dir(dir) do
            if string.match(file_name, "%.lua$") != nil then
                name = string.gsub(file_name, "%.lua$", "")
                table.insert(files, {name = name, path = paths.joinpath(dir, file_name)})
                owner_of[name] = kind .. "/" .. file_name
            end
        end
    elseif dir_required == true then
        return nil, kind .. " directory not found: " .. dir
    end
    for _, owned in ipairs(extension.owned_definitions(db_path, ext_dir, kind)) do
        if owner_of[owned.name] != nil then
            return nil, "'" .. owned.name .. "' is defined by both " .. owner_of[owned.name] ..
                " and extension '" .. owned.extension .. "'"
        end
        owner_of[owned.name] = "extension '" .. owned.extension .. "'"
        table.insert(files, owned)
    end
    return files
end

function extension.approved_with_ui(db_path, ext_dir)
    result = {}
    for _, entry in ipairs(extension.all(ext_dir)) do
        if entry.manifest != nil
           and entry.manifest.capabilities != nil
           and entry.manifest.capabilities.ui != nil
           and extension.is_approved(db_path, entry.manifest) then
            table.insert(result, {name = entry.name, manifest = entry.manifest})
        end
    end
    return result
end

function extension.approved_with_tools(db_path, ext_dir)
    result = {}
    for _, entry in ipairs(extension.all(ext_dir)) do
        if entry.manifest != nil
           and entry.manifest.capabilities != nil
           and entry.manifest.capabilities.tools != nil
           and #entry.manifest.capabilities.tools > 0
           and extension.is_approved(db_path, entry.manifest) then
            table.insert(result, {name = entry.name, manifest = entry.manifest})
        end
    end
    return result
end

function extension.approved_with_manual_triggers(db_path, ext_dir)
    result = {}
    for _, entry in ipairs(extension.all(ext_dir)) do
        if entry.manifest != nil
           and entry.manifest.capabilities != nil
           and entry.manifest.capabilities.manual_triggers != nil
           and #entry.manifest.capabilities.manual_triggers > 0
           and extension.is_approved(db_path, entry.manifest) then
            table.insert(result, {name = entry.name, manifest = entry.manifest})
        end
    end
    return result
end

function extension.matches_event(manifest, event_name)
    if manifest.events == nil then
        return false
    end
    for _, ev in ipairs(manifest.events) do
        if ev == event_name then
            return true
        end
    end
    return false
end

function extension.matches_entity_type(manifest, entity_type)
    if manifest.entity_types == nil then
        return false
    end
    for _, et in ipairs(manifest.entity_types) do
        if et == entity_type then
            return true
        end
    end
    return false
end

function extension.matching(ext_dir, event_name, entity_type)
    result = {}
    for _, entry in ipairs(extension.all(ext_dir)) do
        if entry.manifest != nil
           and extension.matches_event(entry.manifest, event_name)
           and extension.matches_entity_type(entry.manifest, entity_type) then
            table.insert(result, entry)
        end
    end
    return result
end

function string_set(list)
    set = {}
    if list == nil then
        return set
    end
    for _, v in ipairs(list) do
        set[v] = true
    end
    return set
end

function string_sets_equal(a, b)
    set_a = string_set(a)
    set_b = string_set(b)
    for k, _ in pairs(set_a) do
        if set_b[k] == nil then
            return false
        end
    end
    for k, _ in pairs(set_b) do
        if set_a[k] == nil then
            return false
        end
    end
    return true
end

function ui_equal(a, b)
    if a == nil then a = {} end
    if b == nil then b = {} end
    return a.label == b.label and a.icon == b.icon
end

-- Order-independent table equality (dkjson key order is non-canonical across round-trips).
function deep_equal(a, b)
    if type(a) != type(b) then
        return false
    end
    if type(a) != "table" then
        return a == b
    end
    for k, v in pairs(a) do
        if deep_equal(v, b[k]) == false then
            return false
        end
    end
    for k, _ in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

function tool_spec_equal(a, b)
    return a.name == b.name and a.description == b.description
        and a.destructive == b.destructive
        and deep_equal(a.parameters, b.parameters)
end

function tools_equal(a, b)
    if a == nil then a = {} end
    if b == nil then b = {} end
    if #a != #b then
        return false
    end
    for i, tool in ipairs(a) do
        if tool_spec_equal(tool, b[i]) == false then
            return false
        end
    end
    return true
end

function manual_trigger_spec_equal(a, b)
    return a.name == b.name and a.label == b.label and a.description == b.description
end

function manual_triggers_equal(a, b)
    if a == nil then a = {} end
    if b == nil then b = {} end
    if #a != #b then
        return false
    end
    for i, trigger in ipairs(a) do
        if manual_trigger_spec_equal(trigger, b[i]) == false then
            return false
        end
    end
    return true
end

function extension.capabilities_equal(a, b)
    if a == nil then a = {} end
    if b == nil then b = {} end
    if string_sets_equal(a.read, b.read) == false then
        return false
    end
    if string_sets_equal(a.write, b.write) == false then
        return false
    end
    a_net = a.net
    if a_net == nil then a_net = "none" end
    b_net = b.net
    if b_net == nil then b_net = "none" end
    if a_net != b_net then
        return false
    end
    if ui_equal(a.ui, b.ui) == false then
        return false
    end
    if tools_equal(a.tools, b.tools) == false then
        return false
    end
    if string_sets_equal(a.schemas, b.schemas) == false then
        return false
    end
    if string_sets_equal(a.views, b.views) == false then
        return false
    end
    return manual_triggers_equal(a.manual_triggers, b.manual_triggers)
end

function extension.approved_capabilities(db_path, name)
    extension.init_schema(db_path)
    approved = store_lib.approved_content(db_path, "extension", name)
    if approved == nil then
        return nil
    end
    return json.decode(approved)
end

function extension.is_approved(db_path, manifest)
    approved = extension.approved_capabilities(db_path, manifest.name)
    if approved == nil then
        return false
    end
    return extension.capabilities_equal(approved, manifest.capabilities)
end

function extension.approve(db_path, manifest, approved_by)
    extension.init_schema(db_path)
    caps = manifest.capabilities
    if caps == nil then caps = {} end
    caps_json = json.encode(caps)
    store_lib.approve(db_path, "extension", manifest.name, caps_json, approved_by)
end

function extension.revoke(db_path, name)
    extension.init_schema(db_path)
    store_lib.revoke(db_path, "extension", name)
end

-- Runs main.lua in a capability-scoped sandbox; extensions must return a hooks table
-- (Luam top-level functions are implicit-local, never globals).
function extension.load_hooks(ext_dir, name, manifest)
    main_src, err = extension.load_main_source(ext_dir, name)
    if main_src == nil then
        return nil, err
    end
    env = sandbox.extension_env(manifest.capabilities)
    main_path = paths.joinpath(ext_dir, name, "main.lua")
    load_ok, hooks = sandbox.run(main_src, main_path, env)
    if load_ok == false then
        return nil, "error running extension main.lua: " .. tostring(hooks)
    end
    if type(hooks) != "table" then
        return nil, nil
    end
    return hooks, nil
end

function extension.call_bounded(fn, ...)
    if sandbox.pcall_bounded != nil then
        return sandbox.pcall_bounded(nil, fn, ...)
    end
    return pcall(fn, ...)
end

function extension.invoke(ext_dir, name, manifest, hook_name, new_values, old_values, ctx)
    hooks, err = extension.load_hooks(ext_dir, name, manifest)
    if hooks == nil then
        if err != nil then
            return false, err
        end
        return true, nil
    end
    hook_fn = hooks[hook_name]
    if type(hook_fn) != "function" then
        return true, nil
    end
    return extension.call_bounded(hook_fn, new_values, old_values, ctx)
end

function extension.enqueue_after_hooks(db_path, ext_dir, event_name, entity_type, entity_id, new_values, old_values)
    extension.init_schema(db_path)
    for _, entry in ipairs(extension.matching(ext_dir, event_name, entity_type)) do
        if extension.is_approved(db_path, entry.manifest) then
            new_json = nil
            if new_values != nil then
                new_json = json.encode(new_values)
            end
            old_json = nil
            if old_values != nil then
                old_json = json.encode(old_values)
            end
            db.exec(db_path, string.format(
                "INSERT INTO system_job (extension_name, event_name, entity_type, entity_id, new_values_json, old_values_json) VALUES (%s, %s, %s, %d, %s, %s);",
                db.quote(entry.name), db.quote(event_name), db.quote(entity_type), entity_id,
                db.literal(new_json), db.literal(old_json)
            ))
        end
    end
end

const JOB_STALE_CLAIM_SECONDS = 900

function new_job_claim_token()
    crypto_lib = require("crypto")
    tok = crypto_lib.random_hex(8)
    if tok == nil then
        return tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
    end
    return tok
end

function extension.pending_jobs(db_path, limit)
    extension.init_schema(db_path)
    if limit == nil then limit = 50 end
    stale_expr = store_lib.ago_expr(db_path, JOB_STALE_CLAIM_SECONDS)
    rows = db.query(db_path, string.format(
        "SELECT * FROM system_job WHERE (status = 'pending' OR (status LIKE 'running:%%' AND updated_at IS NOT NULL AND updated_at < %s)) AND attempts < %d ORDER BY job_id ASC LIMIT %d;",
        stale_expr, config.load().extension_max_job_attempts, limit
    ))
    if rows == nil then
        return {}
    end
    return rows
end

function extension.claim_job(db_path, job_id)
    extension.init_schema(db_path)
    claim_status = "running:" .. new_job_claim_token()
    stale_expr = store_lib.ago_expr(db_path, JOB_STALE_CLAIM_SECONDS)
    _, _, changed = db.exec(db_path, string.format(
        "UPDATE system_job SET status = %s, updated_at = %s WHERE job_id = %d AND (status = 'pending' OR (status LIKE 'running:%%' AND updated_at IS NOT NULL AND updated_at < %s));",
        db.quote(claim_status), db.now_expr(db_path), tonumber(job_id), stale_expr
    ))
    return changed != nil and changed > 0
end

function extension.mark_job_done(db_path, job)
    db.exec(db_path, string.format(
        "UPDATE system_job SET status = 'done', updated_at = %s WHERE job_id = %d;",
        db.now_expr(db_path), tonumber(job.job_id)
    ))
end

function extension.mark_job_failed(db_path, job, message)
    attempts = tonumber(job.attempts) + 1
    status = "pending"
    if attempts >= config.load().extension_max_job_attempts then
        status = "failed"
    end
    db.exec(db_path, string.format(
        "UPDATE system_job SET status = %s, attempts = %d, last_error = %s, updated_at = %s WHERE job_id = %d;",
        db.quote(status), attempts, db.quote(message), db.now_expr(db_path), tonumber(job.job_id)
    ))
end

return extension
