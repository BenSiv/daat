-- Entity CRUD on top of the ledger: "all-or-nothing per submit"
-- validation -- nothing is written to the ledger or the projected table
-- unless every value passes.
--
-- Validates structurally (required/type/enum/reference-exists) here;
-- scriptable before-hooks (extension-authored validation rules, see
-- doc/extensibility.md) plug into the same contract, run after.

db = require("database")
database_adapter = require("database_adapter")
ledger = require("ledger")
schema = require("schema")
config = require("config")
extension = require("extension")
json = require("dkjson")
view = require("view")

entity = {}

-- has_error used before its own definition below -- pre-declared,
-- see ../../luam/doc/forward_references.md
has_error = nil

function is_number(v)
    return tonumber(v) != nil
end

function has_capability_item(list, item)
    if list == nil then
        return false
    end
    for _, v in ipairs(list) do
        if v == item then
            return true
        end
    end
    return false
end

-- ctx.query/create_entity/update_entity, capability-gated per manifest --
-- shared between before-hooks (synchronous, entity.validate) and
-- after-hooks (entity.run_pending_jobs). Lives here, not in
-- extension.lua, because it needs entity.create/entity.update -- see
-- extension.lua's header comment for why that module can't require this
-- one back.
function entity.build_ctx(db_path, manifest)
    capabilities = manifest.capabilities
    ctx = {}

    function ctx.query(target_type, filter)
        can_read = false
        if capabilities != nil then
            can_read = has_capability_item(capabilities.read, "entity")
        end
        if can_read == false then
            error("Extension '" .. tostring(manifest.name) .. "' does not have read.entity capability")
        end
        -- read.entity means registered entity types, not any table: a
        -- plain table_exists check let an extension read auth_user (password
        -- hashes), auth_api_key, document_embedding, ... (brex 456424482).
        if schema.is_registered(db_path, target_type) == false then
            error("ctx.query: '" .. tostring(target_type) .. "' is not a registered entity type")
        end
        if db.table_exists(db_path, target_type) == false then
            return {}
        end
        -- Filter keys must be real columns of the type's table -- its
        -- system columns or a field that isn't multi-valued/polymorphic
        -- (those live in side tables) -- since they're spliced into SQL
        -- as identifiers.
        columns = {}
        for _, field in ipairs(schema.fields(db_path, target_type)) do
            if schema.is_multi_field_type(field.type) == false and schema.is_polymorphic_field_type(field.type) == false then
                columns[field.name] = true
            end
        end
        where = {}
        if filter != nil then
            for k, v in pairs(filter) do
                if columns[k] != true and schema.is_reserved_field_name(k) == false then
                    error("ctx.query: '" .. tostring(k) .. "' is not a filterable field of " .. target_type)
                end
                if type(v) == "table" then
                    if #v == 0 then
                        return {}
                    end
                    quoted_items = {}
                    for _, item in ipairs(v) do
                        table.insert(quoted_items, db.quote(tostring(item)))
                    end
                    table.insert(where, db.quote_ident(k) .. " IN (" .. table.concat(quoted_items, ", ") .. ")")
                else
                    table.insert(where, db.quote_ident(k) .. " = " .. db.quote(tostring(v)))
                end
            end
        end
        q = "SELECT * FROM " .. target_type
        if #where > 0 then
            q = q .. " WHERE " .. table.concat(where, " AND ")
        end
        q = q .. ";"
        rows = db.query(db_path, q)
        if rows == nil then
            return {}
        end
        return entity.apply_computed_field_overrides(db_path, target_type, rows)
    end

    function ctx.create_entity(target_type, values)
        can_write = false
        if capabilities != nil then
            can_write = has_capability_item(capabilities.write, "entity")
        end
        if can_write == false then
            error("Extension '" .. tostring(manifest.name) .. "' does not have write.entity capability")
        end
        return entity.create(db_path, target_type, values, "extension:" .. manifest.name)
    end

    function ctx.update_entity(target_type, target_id, values)
        can_write = false
        if capabilities != nil then
            can_write = has_capability_item(capabilities.write, "entity")
        end
        if can_write == false then
            error("Extension '" .. tostring(manifest.name) .. "' does not have write.entity capability")
        end
        return entity.update(db_path, target_type, target_id, values, "extension:" .. manifest.name)
    end

    return ctx
end

function run_before_hooks(db_path, entity_type, new_values, old_values, is_update)
    ext_dir = config.extensions_dir()
    issues = {}

    event_name = "entity.before_create"
    if is_update then
        event_name = "entity.before_update"
    end

    for _, entry in ipairs(extension.matching(ext_dir, event_name, entity_type)) do
        if extension.is_approved(db_path, entry.manifest) then
            ctx = entity.build_ctx(db_path, entry.manifest)
            invoke_ok, result = extension.invoke(ext_dir, entry.name, entry.manifest, "on_before",
                new_values, old_values, ctx)
            if invoke_ok then
                if type(result) == "table" then
                    for _, issue in ipairs(result) do
                        table.insert(issues, issue)
                    end
                end
            else
                table.insert(issues, {field = nil, severity = "error",
                    message = "Extension '" .. entry.name .. "' error: " .. tostring(result)})
            end
        end
    end
    return issues
end

-- Structural validation against a registered schema. Returns a list of
-- {field, severity, message} issues -- empty if the row is clean.
function entity.validate(db_path, entity_type, values, old)
    is_update = (old != nil)
    issues = {}
    if schema.is_registered(db_path, entity_type) == false then
        table.insert(issues, {field = nil, severity = "error",
            message = "unknown entity type: " .. tostring(entity_type)})
        return issues
    end
    fields = schema.fields(db_path, entity_type)

    for _, field in ipairs(fields) do
        value = values[field.name]

        if field.type == "multi_select" or field.type == "multi_reference" then
            items = schema.normalize_multi_value(value)
            if #items == 0 then
                if tonumber(field.required) == 1 then
                    table.insert(issues, {field = field.name, severity = "error",
                        message = "required field is missing"})
                end
            elseif field.type == "multi_select" then
                allowed = json.decode(field.enum_values)
                if allowed == nil then
                    allowed = {}
                end
                for _, item in ipairs(items) do
                    ok = false
                    for _, v in ipairs(allowed) do
                        if tostring(v) == tostring(item) then
                            ok = true
                        end
                    end
                    if ok == false then
                        table.insert(issues, {field = field.name, severity = "error",
                            message = "contains a value not in the declared list: " .. tostring(item)})
                    end
                end
            else
                ref_type = entity_type
                if field.ref_entity_type != nil then
                    ref_type = field.ref_entity_type
                end
                for _, item in ipairs(items) do
                    found = entity.get(db_path, ref_type, tonumber(item))
                    if found == nil then
                        table.insert(issues, {field = field.name, severity = "error",
                            message = "references a nonexistent " .. ref_type .. " entity: " .. tostring(item)})
                    end
                end
            end
        elseif field.type == "polymorphic_reference" or field.type == "multi_polymorphic_reference" then
            items = schema.normalize_polymorphic_value(value)
            if #items == 0 then
                if tonumber(field.required) == 1 then
                    table.insert(issues, {field = field.name, severity = "error",
                        message = "required field is missing"})
                end
            else
                if field.type == "polymorphic_reference" and #items > 1 then
                    table.insert(issues, {field = field.name, severity = "error",
                        message = "only one source is allowed for this field"})
                end
                allowed_types = json.decode(field.allowed_entity_types)
                if allowed_types == nil then
                    allowed_types = {}
                end
                for _, item in ipairs(items) do
                    type_ok = false
                    for _, allowed_type in ipairs(allowed_types) do
                        if allowed_type == item.type then
                            type_ok = true
                        end
                    end
                    if type_ok == false then
                        table.insert(issues, {field = field.name, severity = "error",
                            message = "'" .. tostring(item.type) .. "' is not an allowed source type for this field"})
                    elseif entity.get(db_path, item.type, tonumber(item.id)) == nil then
                        table.insert(issues, {field = field.name, severity = "error",
                            message = "references a nonexistent " .. tostring(item.type) .. " entity: " .. tostring(item.id)})
                    end
                end
            end
        elseif (value == nil or value == "") then
            if tonumber(field.required) == 1 then
                table.insert(issues, {field = field.name, severity = "error",
                    message = "required field is missing"})
            end
        else
            if field.type == "number" and is_number(value) == false then
                table.insert(issues, {field = field.name, severity = "error",
                    message = "must be a number"})
            end

            if field.type == "select" then
                allowed = json.decode(field.enum_values)
                if allowed == nil then
                    allowed = {}
                end
                ok = false
                for _, v in ipairs(allowed) do
                    if tostring(v) == tostring(value) then
                        ok = true
                    end
                end
                if ok == false then
                    table.insert(issues, {field = field.name, severity = "error",
                        message = "must be one of the declared values"})
                end
            end

            if field.type == "reference" then
                ref_type = entity_type
                if field.ref_entity_type != nil then
                    ref_type = field.ref_entity_type
                end
                found = entity.get(db_path, ref_type, tonumber(value))
                if found == nil then
                    table.insert(issues, {field = field.name, severity = "error",
                        message = "references a nonexistent " .. ref_type .. " entity"})
                end
            end

            -- A genuinely executable field (label_template.sql and any
            -- future schema that reuses this type) -- reject anything
            -- but a single plain SELECT before it ever reaches the
            -- ledger. Re-checked again at render time (label.lua), not
            -- trusted from storage alone.
            if field.type == "sql_select" and view.is_select_only(value) == false then
                table.insert(issues, {field = field.name, severity = "error",
                    message = "must be a single, plain SELECT statement (no ';', no DDL/DML/pragma)"})
            end
        end
    end

    -- Run before-hooks if there are no severe structural errors
    if not has_error(issues) then
        hooks_issues = run_before_hooks(db_path, entity_type, values, old, is_update)
        for _, issue in ipairs(hooks_issues) do
            table.insert(issues, issue)
        end
    end

    return issues
end

function has_error(issues)
    for _, issue in ipairs(issues) do
        if issue.severity == "error" then
            return true
        end
    end
    return false
end

-- Creates an entity. Returns (entity_id, issues) on success, or
-- (nil, issues) if validation failed. Multivalue fields never become a
-- column in the main INSERT -- they're written to their own companion
-- junction table (schema.write_multi_field) once the row's own id
-- exists. A create's own field_changes (ledger.append_create, below)
-- needs no special handling for them: JSON already represents an array
-- fine as the "new" value.
function entity.create(db_path, entity_type, values, author, source)
    issues = entity.validate(db_path, entity_type, values)
    if has_error(issues) then
        return nil, issues
    end

    multi_fields = schema.multi_fields_by_name(db_path, entity_type)
    polymorphic_fields = schema.polymorphic_fields_by_name(db_path, entity_type)

    -- The ledger's own audit copy normalizes a multivalue field to a
    -- real array (matching entity.update's own field_changes shape)
    -- rather than whatever raw form the caller submitted (a CLI's
    -- comma-separated string, an already-real JSON array, ...) -- audit
    -- history should read the same way regardless of create vs. update.
    ledger_values = {}
    for name, value in pairs(values) do
        if multi_fields[name] != nil then
            ledger_values[name] = schema.normalize_multi_value(value)
        elseif polymorphic_fields[name] != nil then
            ledger_values[name] = schema.normalize_polymorphic_value(value)
        else
            ledger_values[name] = value
        end
    end
    entity_id = ledger.append_create(db_path, entity_type, ledger_values, author, source)

    columns = {"id"}
    literals = {tostring(entity_id)}
    for name, value in pairs(values) do
        if multi_fields[name] == nil and polymorphic_fields[name] == nil then
            table.insert(columns, db.quote_ident(name))
            table.insert(literals, db.literal(value))
        end
    end
    table.insert(columns, "created_by")
    table.insert(literals, db.literal(author))
    table.insert(columns, "last_event_id")
    table.insert(literals, tostring(entity_id))

    db.exec(db_path, string.format(
        "INSERT INTO %s (%s) VALUES (%s);",
        entity_type, table.concat(columns, ", "), table.concat(literals, ", ")
    ))

    for name, field in pairs(multi_fields) do
        if values[name] != nil then
            schema.write_multi_field(db_path, entity_type, entity_id, field, values[name])
        end
    end
    for name, field in pairs(polymorphic_fields) do
        if values[name] != nil then
            schema.write_polymorphic_field(db_path, entity_type, entity_id, field, values[name])
        end
    end

    extension.enqueue_after_hooks(db_path, config.extensions_dir(),
        "entity.after_create", entity_type, entity_id, values, nil)

    -- Lazy require, not a module-top-level one: entity.lua must never
    -- require document.lua (document.lua already requires entity.lua;
    -- the reverse would be circular). Safe here since entity.create
    -- only ever runs during real request/CLI handling, long after
    -- every module has already loaded once -- same reasoning as the
    -- archive/unarchive hooks below. Called from the one choke point
    -- every document creation passes through (generic CLI/API callers
    -- included, not just document.create_page's own direct call) so
    -- knowledge_pool_state.document_count can't drift out from under a
    -- caller that doesn't know to register it itself -- see
    -- document.on_entity_created and doc/heat-decay-redesign.md.
    document_pool_hook = require("document")
    document_pool_hook.on_entity_created(db_path, entity_type, entity_id)

    return entity_id, issues
end

-- Whether two multivalue sets are the same, order-independent (a
-- junction table's own SELECT has no guaranteed row order, and neither
-- does the caller's own submitted list necessarily) -- a real set
-- comparison, not a positional one.
function multi_values_equal(a, b)
    if #a != #b then
        return false
    end
    seen = {}
    for _, v in ipairs(a) do
        seen[tostring(v)] = true
    end
    for _, v in ipairs(b) do
        if seen[tostring(v)] == nil then
            return false
        end
    end
    return true
end

-- Same idea as multi_values_equal, for a polymorphic field's set of
-- {type=, id=} tables -- tostring(v) on a table gives an opaque
-- "table: 0x..." address, never equal across two distinct tables even
-- when their type/id contents match, so this compares the actual
-- type:id pair instead.
function polymorphic_values_equal(a, b)
    if #a != #b then
        return false
    end
    seen = {}
    for _, v in ipairs(a) do
        seen[tostring(v.type) .. ":" .. tostring(v.id)] = true
    end
    for _, v in ipairs(b) do
        if seen[tostring(v.type) .. ":" .. tostring(v.id)] == nil then
            return false
        end
    end
    return true
end

-- Updates an entity. Computes the old/new diff itself (from the current
-- projected row). `reason` is optional unless this type's schema set
-- require_reason_on_update -- checked here, not in ledger.lua, since
-- the ledger itself has no opinion on any particular type's own policy.
--
-- Multivalue fields are diffed as real old/new *sets* here, not just a
-- scalar inequality check, and resynced into their own companion
-- junction table (schema.write_multi_field) after the row's own UPDATE
-- -- without this, editing a multi_reference/multi_select field would
-- be completely invisible to ledger history, undermining this
-- platform's core "every change is ledgered" guarantee.
function entity.update(db_path, entity_type, entity_id, values, author, source, reason)
    current = entity.get(db_path, entity_type, entity_id)
    if current == nil then
        return nil, {{field = nil, severity = "error", message = "no such entity"}}
    end
    reason_flags = schema.reason_flags(db_path, entity_type)
    if reason_flags.require_on_update and (reason == nil or reason == "") then
        return nil, {{field = "reason", severity = "error", message = "a reason for this change is required"}}
    end

    merged = {}
    for k, v in pairs(current) do
        merged[k] = v
    end
    for k, v in pairs(values) do
        merged[k] = v
    end

    issues = entity.validate(db_path, entity_type, merged, current)
    if has_error(issues) then
        return nil, issues
    end

    multi_fields = schema.multi_fields_by_name(db_path, entity_type)
    polymorphic_fields = schema.polymorphic_fields_by_name(db_path, entity_type)

    field_changes = {}
    assignments = {}
    multi_changed = false
    for name, new_value in pairs(values) do
        if multi_fields[name] != nil then
            new_items = schema.normalize_multi_value(new_value)
            old_items = current[name]
            if old_items == nil then
                old_items = {}
            end
            if multi_values_equal(old_items, new_items) == false then
                field_changes[name] = {old = old_items, new = new_items}
                multi_changed = true
            end
        elseif polymorphic_fields[name] != nil then
            new_items = schema.normalize_polymorphic_value(new_value)
            old_items = current[name]
            if old_items == nil then
                old_items = {}
            end
            if polymorphic_values_equal(old_items, new_items) == false then
                field_changes[name] = {old = old_items, new = new_items}
                multi_changed = true
            end
        else
            old_value = current[name]
            if tostring(old_value) != tostring(new_value) then
                field_changes[name] = {old = old_value, new = new_value}
                table.insert(assignments, db.quote_ident(name) .. " = " .. db.literal(new_value))
            end
        end
    end

    if #assignments == 0 and multi_changed == false then
        return entity_id, issues
    end

    event_id = ledger.append_update(db_path, entity_type, entity_id, field_changes, author, source, reason)

    table.insert(assignments, "updated_by = " .. db.literal(author))
    table.insert(assignments, "last_event_id = " .. tostring(event_id))
    db.exec(db_path, string.format(
        "UPDATE %s SET %s WHERE id = %d;", entity_type, table.concat(assignments, ", "), entity_id
    ))

    for name, field in pairs(multi_fields) do
        if values[name] != nil and field_changes[name] != nil then
            schema.write_multi_field(db_path, entity_type, entity_id, field, values[name])
        end
    end
    for name, field in pairs(polymorphic_fields) do
        if values[name] != nil and field_changes[name] != nil then
            schema.write_polymorphic_field(db_path, entity_type, entity_id, field, values[name])
        end
    end

    extension.enqueue_after_hooks(db_path, config.extensions_dir(),
        "entity.after_update", entity_type, entity_id, merged, current)

    -- Lazy require, same reasoning as entity.create's own
    -- on_entity_created call above -- the one choke point every real
    -- document edit passes through, so a generic API/agent/CLI write
    -- keeps links and embeddings in step with content exactly like a
    -- /document-save does. Only reached on a real change: the
    -- no-op-update early return above skips it.
    document_update_hook = require("document")
    document_update_hook.on_entity_updated(db_path, entity_type, entity_id, field_changes)

    return entity_id, issues
end

-- Archives an entity -- never deletes it. The row stays in the
-- projected table (still reachable via entity.get, still queryable in
-- /sql) with archived_at set; entity.list/entity.count exclude it by
-- default (pass include_archived=true to see it). Full ledger history
-- (ledger.history) is untouched either way -- this only ever adds an
-- 'archive' event, on top of whatever create/update events already
-- exist for this entity. `reason` is optional unless this type's schema
-- set require_reason_on_archive -- archiving is the stronger candidate
-- for a schema to actually require one (rarer, more consequential than
-- a routine field edit).
function entity.archive(db_path, entity_type, entity_id, author, source, reason)
    current = entity.get(db_path, entity_type, entity_id)
    if current == nil then
        return nil, {{field = nil, severity = "error", message = "no such entity"}}
    end
    if current.archived_at != nil and current.archived_at != "" then
        return entity_id, {}
    end
    reason_flags = schema.reason_flags(db_path, entity_type)
    if reason_flags.require_on_archive and (reason == nil or reason == "") then
        return nil, {{field = "reason", severity = "error", message = "a reason for archiving is required"}}
    end

    event_id = ledger.append_archive(db_path, entity_type, entity_id, author, source, reason)

    db.exec(db_path, string.format(
        "UPDATE %s SET archived_at = %s, updated_by = %s, last_event_id = %d WHERE id = %d;",
        entity_type, db.now_expr(db_path), db.literal(author), event_id, entity_id
    ))

    extension.enqueue_after_hooks(db_path, config.extensions_dir(),
        "entity.after_archive", entity_type, entity_id, current, current)

    return entity_id, {}
end

-- Reverses entity.archive -- also never deletes anything, just another
-- additive ledger event (an 'update' clearing archived_at, the same
-- shape any other field-level edit takes).
function entity.unarchive(db_path, entity_type, entity_id, author, source)
    current = entity.get(db_path, entity_type, entity_id)
    if current == nil then
        return nil, {{field = nil, severity = "error", message = "no such entity"}}
    end
    if current.archived_at == nil or current.archived_at == "" then
        return entity_id, {}
    end

    field_changes = {archived_at = {old = current.archived_at, new = nil}}
    event_id = ledger.append_update(db_path, entity_type, entity_id, field_changes, author, source)

    db.exec(db_path, string.format(
        "UPDATE %s SET archived_at = NULL, updated_by = %s, last_event_id = %d WHERE id = %d;",
        entity_type, db.literal(author), event_id, entity_id
    ))

    return entity_id, {}
end

-- Runs validation on a batch of row values.
function entity.validate_batch(db_path, entity_type, rows_values)
    batch_issues = {}
    for i, values in ipairs(rows_values) do
        issues = entity.validate(db_path, entity_type, values)
        for _, issue in ipairs(issues) do
            table.insert(batch_issues, {
                row_index = i,
                field = issue.field,
                severity = issue.severity,
                message = issue.message
            })
        end
    end
    return batch_issues
end

-- The server-side connection id on MariaDB (nil on SQLite): luam
-- reconnects silently when a cached connection drops, which would end
-- an open transaction and let the rest of a batch autocommit.
function batch_connection_id(db_path)
    if db.is_mariadb(db_path) == false then
        return nil
    end
    rows = db.query(db_path, "SELECT CONNECTION_ID() AS id;")
    if rows == nil or rows[1] == nil then
        return nil
    end
    return tostring(rows[1].id)
end

-- Creates a batch of entities atomically. `source.notebook_entry_id`
-- (if given) is shared by every row in the batch -- one embedded
-- registration table submission is one notebook-entry context -- but
-- each row gets its own source_row_id (its position in the batch), so
-- the ledger can tell which specific row of a multi-row submission
-- produced which entity.
function entity.create_batch(db_path, entity_type, rows_values, author, source)
    batch_issues = entity.validate_batch(db_path, entity_type, rows_values)
    if has_error(batch_issues) then
        return nil, batch_issues
    end
    if source == nil then
        source = {}
    end

    -- One transaction for the whole batch: every row's projected row,
    -- ledger event, field changes and name-index rows commit together.
    -- Measured 2026-11-06 on 500 11-field rows: 77 s with each insert
    -- autocommitting, 1 s in one transaction. A failed row, a raised
    -- error or a dropped MariaDB connection rolls the whole batch back.
    --
    -- SQLite needs one kept-open connection for a transaction to span
    -- statements (by default each statement opens its own). Turned on
    -- here only if nothing else already has it on -- a cached connection
    -- means someone did -- and turned back off afterwards.
    created_ids = {}
    opened_sqlite = false
    already_keep_open = (database_adapter.is_sqlite_keep_open != nil and database_adapter.is_sqlite_keep_open() == true)
        or database_adapter.sqlite_connection_count() > 0
    if db.is_mariadb(db_path) == false and already_keep_open == false then
        database_adapter.sqlite_keep_open(true)
        opened_sqlite = true
    end
    -- DDL commits implicitly on MariaDB: settle the schema before BEGIN.
    extension.init_schema(db_path)
    connection_before = batch_connection_id(db_path)
    db.exec(db_path, "BEGIN;")
    ok, failure = pcall(function()
        for i, values in ipairs(rows_values) do
            row_source = {notebook_entry_id = source.notebook_entry_id, row_id = tostring(i)}
            id, issues = entity.create(db_path, entity_type, values, author, row_source)
            if id == nil then
                return issues
            end
            table.insert(created_ids, id)
            -- Checked per row, so a reconnect costs at most the one row
            -- written on the new connection (autocommitted, not rolled back).
            if batch_connection_id(db_path) != connection_before then
                error(string.format("the database connection dropped during the batch: rows before row %d were " ..
                    "rolled back, row %d (%s id %s) may have been saved -- check before retrying", i, i, entity_type, tostring(id)))
            end
        end
        return nil
    end)
    if ok and failure == nil then
        db.exec(db_path, "COMMIT;")
    else
        pcall(db.exec, db_path, "ROLLBACK;")
    end
    if opened_sqlite then
        database_adapter.sqlite_keep_open(false)
    end
    if ok == false then
        error(failure, 0)
    end
    if failure != nil then
        return nil, failure
    end
    return created_ids, batch_issues
end

-- Overrides a multi_reference/polymorphic_reference field's raw column
-- value with its real value, read from the companion multi_value/
-- entity_ref table instead -- every raw "SELECT * FROM <entity_type>"
-- reader needs this, not just entity.get. multi_reference fields never
-- have a column at all, so a raw row simply lacks the key (harmless);
-- polymorphic_reference fields are different when a field *converts* to
-- one from a plain column type (e.g. sample.source: text ->
-- polymorphic_reference) -- schema sync is additive-only and never
-- drops the old column, so a raw row still carries that column's old,
-- stale value under the same key. Skipping this override for any new
-- raw-row reader reproduces the exact crash class this guards against:
-- a polymorphic column's stale string value reaching code that expects
-- the real {type=,id=} table shape (e.g. `ipairs` on a plain string).
function entity.apply_computed_field_overrides(db_path, entity_type, rows)
    if rows == nil or #rows == 0 then
        return rows
    end
    multi_fields = schema.multi_fields_by_name(db_path, entity_type)
    polymorphic_fields = schema.polymorphic_fields_by_name(db_path, entity_type)
    has_multi = next(multi_fields) != nil
    has_poly = next(polymorphic_fields) != nil
    if not has_multi and not has_poly then
        return rows
    end
    if #rows == 1 then
        row = rows[1]
        for name, field in pairs(multi_fields) do
            row[name] = schema.read_multi_field(db_path, entity_type, row.id, field)
        end
        for name, field in pairs(polymorphic_fields) do
            row[name] = schema.read_polymorphic_field(db_path, entity_type, row.id, field)
        end
        return rows
    end

    id_list = {}
    rows_by_id = {}
    for _, row in ipairs(rows) do
        rid = tonumber(row.id)
        if rid != nil then
            if rows_by_id[rid] == nil then
                table.insert(id_list, tostring(rid))
                rows_by_id[rid] = {}
            end
            table.insert(rows_by_id[rid], row)
        end
        for name, _ in pairs(multi_fields) do
            row[name] = {}
        end
        for name, _ in pairs(polymorphic_fields) do
            row[name] = {}
        end
    end
    if #id_list == 0 then
        return rows
    end
    id_sql = table.concat(id_list, ", ")

    for name, field in pairs(multi_fields) do
        table_name = schema.multi_field_table_name(entity_type, field.name)
        if db.table_exists(db_path, table_name) then
            parent_col = entity_type .. "_id"
            value_col = "value"
            if field.type == "multi_reference" then
                value_col = field.name .. "_id"
            end
            m_rows = db.query(db_path, string.format(
                "SELECT %s AS pid, %s AS v FROM %s WHERE %s IN (%s);",
                parent_col, value_col, table_name, parent_col, id_sql
            ))
            if m_rows != nil then
                for _, mr in ipairs(m_rows) do
                    targets = rows_by_id[tonumber(mr.pid)]
                    if targets != nil then
                        for _, target_row in ipairs(targets) do
                            table.insert(target_row[name], mr.v)
                        end
                    end
                end
            end
        end
    end

    if has_poly and db.table_exists(db_path, "entity_ref") then
        p_rows = db.query(db_path, string.format(
            "SELECT from_id, field_name, to_type, to_id FROM entity_ref WHERE from_type = %s AND from_id IN (%s) ORDER BY id ASC;",
            db.quote(entity_type), id_sql
        ))
        if p_rows != nil then
            for _, pr in ipairs(p_rows) do
                fname = pr.field_name
                if polymorphic_fields[fname] != nil then
                    targets = rows_by_id[tonumber(pr.from_id)]
                    if targets != nil then
                        item = {type = pr.to_type, id = tonumber(pr.to_id)}
                        for _, target_row in ipairs(targets) do
                            table.insert(target_row[fname], item)
                        end
                    end
                end
            end
        end
    end

    return rows
end

-- Attaches every multivalue field's current set to the returned row --
-- one extra schema.fields lookup plus one query per multivalue field on
-- this entity type, on every single call, including the "does this
-- referenced row exist" checks entity.validate itself makes. Accepted
-- as-is for correctness (a caller reading a row should see its true
-- complete shape) rather than optimized away -- revisit only if this
-- entity type's real read volume makes it actually show up, the same
-- "no premature optimization" bar this codebase already applies
-- elsewhere (e.g. document.search's own O(n) scan).
function entity.get(db_path, entity_type, entity_id)
    if db.table_exists(db_path, entity_type) == false then
        return nil
    end
    rows = db.query(db_path, string.format(
        "SELECT * FROM %s WHERE id = %d;", entity_type, entity_id
    ))
    if rows == nil then
        return nil
    end
    entity.apply_computed_field_overrides(db_path, entity_type, rows)
    return rows[1]
end

-- `limit`/`offset` are both optional; omit either (or both) for the
-- full unpaginated result, kept for callers that already assume that
-- (e.g. views/extensions built before pagination existed).
--
-- Archived entities (archived_at IS NOT NULL) are excluded by default --
-- `/browse` and friends shouldn't fill up with retired rows -- pass
-- `include_archived=true` for the rare caller that wants them too (an
-- "include archived" toggle, an admin audit view, etc.). Archiving
-- never removes a row, so it's always still reachable via entity.get
-- or raw /sql regardless of this default.
function entity.list(db_path, entity_type, limit, offset, include_archived)
    if db.table_exists(db_path, entity_type) == false then
        return {}
    end
    query = "SELECT * FROM " .. entity_type
    if include_archived != true then
        query = query .. " WHERE archived_at IS NULL"
    end
    if limit != nil then
        query = query .. " LIMIT " .. tostring(tonumber(limit))
        if offset != nil then
            query = query .. " OFFSET " .. tostring(tonumber(offset))
        end
    end
    rows = db.query(db_path, query .. ";")
    if rows == nil then
        return {}
    end
    return entity.apply_computed_field_overrides(db_path, entity_type, rows)
end

function entity.count(db_path, entity_type, include_archived)
    if db.table_exists(db_path, entity_type) == false then
        return 0
    end
    query = "SELECT COUNT(*) AS n FROM " .. db.quote_ident(entity_type)
    if include_archived != true then
        query = query .. " WHERE archived_at IS NULL"
    end
    rows = db.query(db_path, query .. ";")
    if rows == nil or rows[1] == nil then
        return 0
    end
    return tonumber(rows[1].n)
end

-- Batched active row counts across a list of registered entity types for
-- `/data`. Every create, archive and unarchive of a registered entity
-- appends an `entity_event` row, so `MAX(event_id)` + the sorted type list
-- uniquely identifies when active counts can change:
--   1. Exact cache hit in `system_state` ('entity.active_counts_cache'):
--      0 table scans and 0 `information_schema` round-trips.
--   2. Incremental refresh when new ledger events arrived: recounts only
--      the distinct `entity_type`s with create/archive/unarchive events
--      after the cached `max_event_id` (leaving 70k-row unchanged tables
--      untouched).
--   3. Cold start or schema-set change: checks table existence once via
--      `db.get_tables` and batches `SELECT COUNT(*)` in `UNION ALL` chunks.
ACTIVE_COUNTS_STATE_KEY = "entity.active_counts_cache"
COUNT_UNION_CHUNK_SIZE = 25

function to_int_or_zero(v)
    n = tonumber(v)
    if n == nil then
        return 0
    end
    return n
end

function run_batched_active_counts(db_path, target_names, existing_set)
    computed = {}
    present = {}
    for _, name in ipairs(target_names) do
        computed[name] = 0
        if existing_set[name] == true then
            table.insert(present, name)
        end
    end
    idx = 1
    while idx <= #present do
        parts = {}
        chunk_end = math.min(#present, idx + COUNT_UNION_CHUNK_SIZE - 1)
        for i = idx, chunk_end do
            tname = present[i]
            table.insert(parts, string.format(
                "SELECT %s AS entity_name, COUNT(*) AS n FROM %s WHERE archived_at IS NULL",
                db.quote(tname), db.quote_ident(tname)
            ))
        end
        q = table.concat(parts, " UNION ALL ") .. ";"
        rows = db.query(db_path, q)
        if rows != nil then
            for _, r in ipairs(rows) do
                if r.entity_name != nil then
                    computed[r.entity_name] = to_int_or_zero(r.n)
                end
            end
        end
        idx = chunk_end + 1
    end
    return computed
end

function existing_tables_set(db_path)
    set = {}
    tables = db.get_tables(db_path)
    if tables != nil then
        for _, t in ipairs(tables) do
            set[t] = true
        end
    end
    return set
end

function entity.counts_by_type(db_path, entity_types)
    type_names = {}
    items = entity_types
    if items == nil then
        items = {}
    end
    for _, item in ipairs(items) do
        name = item
        if type(item) == "table" then
            name = item.name
        end
        if type(name) == "string" and name != "" and schema.valid_name_syntax(name) then
            table.insert(type_names, name)
        end
    end
    if #type_names == 0 then
        return {}
    end

    sorted_names = {}
    for i, name in ipairs(type_names) do
        sorted_names[i] = name
    end
    table.sort(sorted_names)
    types_sig = table.concat(sorted_names, ",")

    store_mod = require("store")
    max_ok, max_rows = pcall(db.query, db_path, "SELECT COALESCE(MAX(event_id), 0) AS max_id FROM entity_event;")
    cache_usable = (max_ok == true and max_rows != nil and max_rows[1] != nil)
    current_max_id = 0
    if cache_usable then
        current_max_id = to_int_or_zero(max_rows[1].max_id)
    end

    cached = nil
    if cache_usable then
        raw_ok, raw_json = pcall(store_mod.get_text, db_path, ACTIVE_COUNTS_STATE_KEY)
        if raw_ok == true and type(raw_json) == "string" and raw_json != "" then
            decoded = json.decode(raw_json)
            if type(decoded) == "table" and type(decoded.counts) == "table" then
                cached = decoded
            end
        end
    end

    if cached != nil and cached.types_sig == types_sig and tonumber(cached.max_event_id) != nil then
        cached_max = tonumber(cached.max_event_id)
        if cached_max == current_max_id then
            result = {}
            for _, name in ipairs(type_names) do
                result[name] = to_int_or_zero(cached.counts[name])
            end
            return result
        end
        if current_max_id > cached_max then
            dirty_ok, dirty_rows = pcall(db.query, db_path, string.format(
                "SELECT DISTINCT entity_type FROM entity_event WHERE event_id > %d AND event_type IN ('create', 'archive', 'unarchive');",
                cached_max
            ))
            if dirty_ok == true then
                requested_set = {}
                for _, name in ipairs(type_names) do
                    requested_set[name] = true
                end
                dirty_names = {}
                if dirty_rows != nil then
                    for _, dr in ipairs(dirty_rows) do
                        if dr.entity_type != nil and requested_set[dr.entity_type] == true then
                            table.insert(dirty_names, dr.entity_type)
                        end
                    end
                end
                counts = {}
                for _, name in ipairs(type_names) do
                    counts[name] = to_int_or_zero(cached.counts[name])
                end
                if #dirty_names > 0 then
                    recounted = run_batched_active_counts(db_path, dirty_names, existing_tables_set(db_path))
                    for k, v in pairs(recounted) do
                        counts[k] = v
                    end
                end
                pcall(store_mod.set_text, db_path, ACTIVE_COUNTS_STATE_KEY, json.encode({
                    max_event_id = current_max_id,
                    types_sig = types_sig,
                    counts = counts,
                }))
                return counts
            end
        end
    end

    counts = run_batched_active_counts(db_path, type_names, existing_tables_set(db_path))
    if cache_usable then
        pcall(store_mod.set_text, db_path, ACTIVE_COUNTS_STATE_KEY, json.encode({
            max_event_id = current_max_id,
            types_sig = types_sig,
            counts = counts,
        }))
    end
    return counts
end

-- Filtered siblings of entity.list/entity.count, for "every X that
-- references this Y" (e.g. a mixture's ingredients) -- field_name/value
-- are trusted the same way entity_type already is throughout this file
-- (schema-registered names from cgi.lua, not raw user input), quoted
-- for safety regardless.
function entity.list_by_field(db_path, entity_type, field_name, value, limit, offset, include_archived)
    if db.table_exists(db_path, entity_type) == false then
        return {}
    end
    query = "SELECT * FROM " .. entity_type .. " WHERE " .. db.quote_ident(field_name) .. " = " .. db.literal(value)
    if include_archived != true then
        query = query .. " AND archived_at IS NULL"
    end
    if limit != nil then
        query = query .. " LIMIT " .. tostring(tonumber(limit))
        if offset != nil then
            query = query .. " OFFSET " .. tostring(tonumber(offset))
        end
    end
    rows = db.query(db_path, query .. ";")
    if rows == nil then
        return {}
    end
    return entity.apply_computed_field_overrides(db_path, entity_type, rows)
end

function entity.count_by_field(db_path, entity_type, field_name, value, include_archived)
    if db.table_exists(db_path, entity_type) == false then
        return 0
    end
    query = "SELECT COUNT(*) AS n FROM " .. entity_type .. " WHERE " .. db.quote_ident(field_name) .. " = " .. db.literal(value)
    if include_archived != true then
        query = query .. " AND archived_at IS NULL"
    end
    rows = db.query(db_path, query .. ";")
    if rows == nil or rows[1] == nil then
        return 0
    end
    return tonumber(rows[1].n)
end

-- The schema-declared {display = true} field (if any) and every
-- {identifier = true} field for this type. Builtin "name" is always
-- checked first by search_across_types; display and identifier fields
-- give locally created rows and code-named records (lab_number,
-- asset_code) the same discoverability in /data's search box and the
-- document editor's @mention dropdown.
function search_fields_for_type(db_path, entity_type)
    display_field = nil
    identifier_fields = {}
    for _, field in ipairs(schema.fields(db_path, entity_type)) do
        if display_field == nil and tonumber(field.display) == 1 then
            display_field = field.name
        end
        if tonumber(field.identifier) == 1 then
            table.insert(identifier_fields, field.name)
        end
    end
    return display_field, identifier_fields
end

-- Picks the primary label and optional subtitle for a search hit:
-- builtin `name` first, then the schema's display field, falling back
-- to a matching (or first) identifier value on display-less schemas.
-- When the query matched an identifier rather than the primary label
-- (e.g. "EXP-027" on an experiment titled "Growth of S. demo..."),
-- the identifier becomes `label` -- so @mention inserts "[EXP-027](...)"
-- matching what the author typed -- and the primary label rides along
-- as `subtitle` so the dropdown still shows which record it is.
function search_row_label(row, display_field, identifier_fields, query_lower)
    primary_label = nil
    if row.name != nil and tostring(row.name) != "" then
        primary_label = tostring(row.name)
    elseif display_field != nil and row[display_field] != nil and tostring(row[display_field]) != "" then
        primary_label = tostring(row[display_field])
    end
    first_id_val = nil
    matched_id_val = nil
    for _, id_field in ipairs(identifier_fields) do
        raw_val = row[id_field]
        if raw_val != nil and tostring(raw_val) != "" then
            val_str = tostring(raw_val)
            if first_id_val == nil then
                first_id_val = val_str
            end
            if matched_id_val == nil and string.find(string.lower(val_str), query_lower, 1, true) != nil then
                matched_id_val = val_str
            end
        end
    end
    if primary_label == nil then
        if matched_id_val != nil then
            return matched_id_val, nil
        end
        return first_id_val, nil
    end
    primary_matches = string.find(string.lower(primary_label), query_lower, 1, true) != nil
    if primary_matches == false and matched_id_val != nil then
        subtitle = nil
        if matched_id_val != primary_label then
            subtitle = primary_label
        end
        return matched_id_val, subtitle
    end
    subtitle = nil
    if first_id_val != nil and first_id_val != primary_label then
        subtitle = first_id_val
    end
    return primary_label, subtitle
end

-- Cross-type "find this row" search for /data's search box and the
-- document editor's @mention dropdown: one bounded LIKE per type
-- against builtin `name`, the schema's display field (if any), and any
-- `identifier = true` fields. A type with none of those populated
-- matches nothing without needing a special-case skip list.
-- `per_type_limit` bounds each query; `total_limit` truncates the
-- combined result.
function entity.search_across_types(db_path, query_text, per_type_limit, total_limit)
    if query_text == nil or query_text == "" then
        return {}
    end
    query_str = tostring(query_text)
    query_lower = string.lower(query_str)
    like_value = db.quote("%" .. query_str .. "%")
    results = {}
    for _, entity_type_row in ipairs(schema.list(db_path)) do
        entity_type = entity_type_row.name
        if entity_type != "document" and db.table_exists(db_path, entity_type) == true then
            display_field, identifier_fields = search_fields_for_type(db_path, entity_type)
            select_cols = {"id", "name"}
            where_parts = {"name LIKE " .. like_value}
            seen_cols = {id = true, name = true}
            extra_cols = {}
            if display_field != nil then
                table.insert(extra_cols, display_field)
            end
            for _, id_field in ipairs(identifier_fields) do
                table.insert(extra_cols, id_field)
            end
            for _, col in ipairs(extra_cols) do
                if seen_cols[col] == nil then
                    seen_cols[col] = true
                    quoted_col = db.quote_ident(col)
                    table.insert(select_cols, quoted_col)
                    table.insert(where_parts, quoted_col .. " LIKE " .. like_value)
                end
            end
            rows = db.query(db_path, string.format(
                "SELECT %s FROM %s WHERE (%s) AND (archived_at IS NULL OR archived_at = '') LIMIT %d;",
                table.concat(select_cols, ", "), entity_type, table.concat(where_parts, " OR "), tonumber(per_type_limit)
            ))
            if rows != nil then
                for _, row in ipairs(rows) do
                    label, subtitle = search_row_label(row, display_field, identifier_fields, query_lower)
                    if label != nil and label != "" then
                        table.insert(results, {entity_type = entity_type, id = row.id, label = label, subtitle = subtitle})
                    end
                end
            end
        end
    end
    if #results > total_limit then
        truncated = {}
        for i = 1, total_limit do
            table.insert(truncated, results[i])
        end
        return truncated
    end
    return results
end

-- Drains the after-hook job queue: runs each pending job (oldest first,
-- up to `limit`), marking it done or failed. A job that errors stays
-- 'pending' (and gets retried on the next run) until it has failed
-- extension.MAX_JOB_ATTEMPTS times; one job's failure never affects any
-- other job. Intended to be invoked periodically by whatever the
-- deployer already uses for scheduled tasks (cron, etc.) -- platform is a
-- one-shot CGI/CLI process, so there's no long-lived place inside it to
-- run this on a timer itself.
function entity.run_pending_jobs(db_path, limit)
    ext_dir = config.extensions_dir()
    ran = 0
    failed = 0
    for _, job in ipairs(extension.pending_jobs(db_path, limit)) do
        manifest, err = extension.load_manifest(ext_dir, job.extension_name)
        if manifest == nil then
            extension.mark_job_failed(db_path, job, "manifest error: " .. tostring(err))
            failed = failed + 1
        elseif extension.is_approved(db_path, manifest) == false then
            extension.mark_job_failed(db_path, job,
                "extension not approved (or capabilities changed since approval)")
            failed = failed + 1
        else
            new_values = nil
            if job.new_values_json != nil then
                new_values = json.decode(job.new_values_json)
            end
            old_values = nil
            if job.old_values_json != nil then
                old_values = json.decode(job.old_values_json)
            end
            ctx = entity.build_ctx(db_path, manifest)
            invoke_ok, result = extension.invoke(ext_dir, job.extension_name, manifest, "on_after",
                new_values, old_values, ctx)
            if invoke_ok then
                extension.mark_job_done(db_path, job)
                ran = ran + 1
            else
                extension.mark_job_failed(db_path, job, tostring(result))
                failed = failed + 1
            end
        end
    end
    return {ran = ran, failed = failed}
end

-- A multivalue field's value is a plain Lua array -- tostring() on that
-- gives an unreadable "table: 0x..." pointer, so this renders it as a
-- real bracketed, comma-joined list instead. Scalars pass through.
-- A single polymorphic-reference item ({type=, id=}) as "type:id" --
-- matches the same CLI-facing convention entity create/update already
-- accept for these fields, so what a user sees here is exactly what
-- they could paste back in.
function format_cli_polymorphic_item(item)
    return tostring(item.type) .. ":" .. tostring(item.id)
end

function format_cli_value(v)
    if type(v) == "table" then
        parts = {}
        for _, item in ipairs(v) do
            if type(item) == "table" and item.type != nil then
                table.insert(parts, format_cli_polymorphic_item(item))
            else
                table.insert(parts, tostring(item))
            end
        end
        return "[" .. table.concat(parts, ", ") .. "]"
    end
    return tostring(v)
end

function print_issues(issues)
    for _, issue in ipairs(issues) do
        label = "(row)"
        if issue.field != nil then
            label = issue.field
        end
        print(string.format("  [%s] %s: %s", issue.severity, label, issue.message))
    end
end

function parse_kv_args(args, start)
    values = {}
    for i = start, #args do
        key, value = string.match(args[i], "^([%w_]+)=(.*)$")
        if key != nil then
            values[key] = value
        end
    end
    return values
end

-- Builds a {key_field_value: id} map from `rows` (each carrying
-- `key_field`, `id`, and `archived_at`), preferring an active row over
-- an archived one whenever the same key value labels more than one row
-- -- see external-ids/field-map's own comments in do_entity for why
-- this matters: without it, the first (or last, depending on the
-- backend's own row order) row found for a duplicated key wins
-- arbitrarily, which can silently point an importer's upsert at an
-- invisible archived duplicate while the real, visible row goes stale
-- forever.
function entity_id_map_prefer_active(rows, key_field)
    result = {}
    result_is_archived = {}
    for _, row in ipairs(rows) do
        key = tostring(row[key_field])
        is_archived = row.archived_at != nil and row.archived_at != ""
        if result[key] == nil or (result_is_archived[key] == true and is_archived == false) then
            result[key] = tonumber(row.id)
            result_is_archived[key] = is_archived
        end
    end
    return result
end

-- CLI entry point: `daat entity <create|list|show|validate-json|create-json> [args]`
function entity.do_entity(cmd_args, db_path)
    action = cmd_args[1]

    if action == "create" then
        entity_type = cmd_args[2]
        if entity_type == nil then
            print("Usage: daat entity create <type> field=value [field=value ...]")
            return
        end
        values = parse_kv_args(cmd_args, 3)
        id, issues = entity.create(db_path, entity_type, values, os.getenv("USER"))
        if id == nil then
            print("Registration failed:")
            print_issues(issues)
            return
        end
        print(string.format("Created %s #%d", entity_type, id))
        if #issues > 0 then
            print_issues(issues)
        end
        return
    end

    if action == "update" then
        entity_type = cmd_args[2]
        id = tonumber(cmd_args[3])
        if entity_type == nil or id == nil then
            print("Usage: daat entity update <type> <id> field=value [field=value ...]")
            return
        end
        values = parse_kv_args(cmd_args, 4)
        updated_id, issues = entity.update(db_path, entity_type, id, values, os.getenv("USER"))
        if updated_id == nil then
            print("Update failed:")
            print_issues(issues)
            return
        end
        print(string.format("Updated %s #%d", entity_type, updated_id))
        if #issues > 0 then
            print_issues(issues)
        end
        return
    end

    if action == "archive" then
        entity_type = cmd_args[2]
        id = tonumber(cmd_args[3])
        if entity_type == nil or id == nil then
            print("Usage: daat entity archive <type> <id>")
            return
        end
        archived_id, issues = entity.archive(db_path, entity_type, id, os.getenv("USER"))
        if archived_id == nil then
            print("Archive failed:")
            print_issues(issues)
            return
        end
        -- Lazy require, not a module-top-level one: entity.lua must
        -- never require document.lua (document.lua already requires
        -- entity.lua; the reverse would be circular). Safe here since
        -- this only runs during real CLI dispatch, long after every
        -- module has already loaded once.
        document_pool_hook = require("document")
        document_pool_hook.on_entity_archived(db_path, entity_type, archived_id)
        print(string.format("Archived %s #%d", entity_type, archived_id))
        return
    end

    if action == "unarchive" then
        entity_type = cmd_args[2]
        id = tonumber(cmd_args[3])
        if entity_type == nil or id == nil then
            print("Usage: daat entity unarchive <type> <id>")
            return
        end
        unarchived_id, issues = entity.unarchive(db_path, entity_type, id, os.getenv("USER"))
        if unarchived_id == nil then
            print("Unarchive failed:")
            print_issues(issues)
            return
        end
        document_pool_hook = require("document")
        document_pool_hook.on_entity_unarchived(db_path, entity_type, unarchived_id)
        print(string.format("Unarchived %s #%d", entity_type, unarchived_id))
        return
    end

    if action == "list" then
        entity_type = cmd_args[2]
        include_archived = false
        for i = 3, #cmd_args do
            if cmd_args[i] == "--include-archived" then
                include_archived = true
            end
        end
        if entity_type == nil then
            print("Usage: daat entity list <type> [--include-archived]")
            return
        end
        for _, row in ipairs(entity.list(db_path, entity_type, nil, nil, include_archived)) do
            print(string.format("#%s", tostring(row.id)))
        end
        return
    end

    if action == "show" then
        entity_type = cmd_args[2]
        id = tonumber(cmd_args[3])
        if entity_type == nil or id == nil then
            print("Usage: daat entity show <type> <id>")
            return
        end
        row = entity.get(db_path, entity_type, id)
        if row == nil then
            print("Not found")
            return
        end
        for k, v in pairs(row) do
            print(string.format("%-20s %s", k, format_cli_value(v)))
        end
        return
    end

    if action == "validate-json" then
        entity_type = cmd_args[2]
        if entity_type == nil then
            print("Usage: daat entity validate-json <type>")
            return
        end
        input = io.read("*all")
        rows_values, _, err = json.decode(input)
        if rows_values == nil then
            print(json.encode({error = "Invalid JSON input: " .. tostring(err)}))
            return
        end
        batch_issues = entity.validate_batch(db_path, entity_type, rows_values)
        print(json.encode(batch_issues))
        return
    end

    -- {external_id: id} for every row of `entity_type` that has one --
    -- a real, backend-agnostic (SQLite or MariaDB, via database.lua's
    -- own dispatch) read path an external importer can use to detect "does
    -- a row for this source record already exist" and upsert instead of
    -- blindly re-creating it every run. Every row regardless of
    -- archived_at -- an archived row's external_id is still "already
    -- imported," not fair game to recreate -- but when the same
    -- external_id somehow labels more than one row (a prior duplicate-
    -- creation bug, a race), an active row always wins over an archived
    -- one via entity_id_map_prefer_active below: an importer upserting
    -- by this map must land on the row a human can actually see, not
    -- silently keep re-updating an invisible archived duplicate while
    -- the real one goes stale forever -- confirmed live, exactly this
    -- shape of bug (see also field-map below, same fix, same reason).
    if action == "external-ids" then
        entity_type = cmd_args[2]
        if entity_type == nil then
            print("Usage: daat entity external-ids <type>")
            return
        end
        result = {}
        if db.table_exists(db_path, entity_type) then
            rows = db.query(db_path, string.format(
                "SELECT external_id, id, archived_at FROM %s WHERE external_id IS NOT NULL AND external_id != '';", entity_type
            ))
            if rows != nil then
                result = entity_id_map_prefer_active(rows, "external_id")
            end
        end
        print(json.encode(result))
        return
    end

    -- {field_value: id} for every row of `entity_type` with a non-null,
    -- non-empty value for `field_name` -- same backend-agnostic lookup
    -- as external-ids, for an importer keying off some other natural
    -- column instead of (or in addition to) external_id. Same active-
    -- over-archived preference as external-ids above, same reason.
    if action == "field-map" then
        entity_type = cmd_args[2]
        field_name = cmd_args[3]
        if entity_type == nil or field_name == nil then
            print("Usage: daat entity field-map <type> <field>")
            return
        end
        result = {}
        if db.table_exists(db_path, entity_type) then
            quoted_field = db.quote_ident(field_name)
            rows = db.query(db_path, string.format(
                "SELECT %s AS field_value, id, archived_at FROM %s WHERE %s IS NOT NULL AND %s != '';",
                quoted_field, entity_type, quoted_field, quoted_field
            ))
            if rows != nil then
                result = entity_id_map_prefer_active(rows, "field_value")
            end
        end
        print(json.encode(result))
        return
    end

    -- Lets an external importer find every existing row referencing a
    -- given parent (e.g. an entity_type with no stable per-row
    -- external_id of its own, like a Mixture ingredient line item) so
    -- it can archive-then-recreate them safely instead of accumulating
    -- duplicates on every re-sync. Thin CLI wrapper around the existing
    -- entity.list_by_field -- no new logic, just a new entry point for
    -- it.
    if action == "list-by-field" then
        entity_type = cmd_args[2]
        field_name = cmd_args[3]
        value = cmd_args[4]
        if entity_type == nil or field_name == nil or value == nil then
            print("Usage: daat entity list-by-field <type> <field> <value>")
            return
        end
        rows = entity.list_by_field(db_path, entity_type, field_name, value)
        ids = {}
        for _, row in ipairs(rows) do
            table.insert(ids, tonumber(row.id))
        end
        print(json.encode(ids))
        return
    end

    if action == "create-json" then
        entity_type = cmd_args[2]
        if entity_type == nil then
            print("Usage: daat entity create-json <type>")
            return
        end
        input = io.read("*all")
        rows_values, _, err = json.decode(input)
        if rows_values == nil then
            print(json.encode({error = "Invalid JSON input: " .. tostring(err)}))
            return
        end
        author = os.getenv("USER")
        created_ids, batch_issues = entity.create_batch(db_path, entity_type, rows_values, author)
        response = {
            issues = batch_issues
        }
        if created_ids != nil then
            response.created_ids = created_ids
            response.success = true
        else
            response.success = false
        end
        print(json.encode(response))
        return
    end

    if action == "update-json" then
        entity_type = cmd_args[2]
        id = tonumber(cmd_args[3])
        if entity_type == nil or id == nil then
            print("Usage: daat entity update-json <type> <id>")
            return
        end
        input = io.read("*all")
        values, _, err = json.decode(input)
        if values == nil then
            print(json.encode({error = "Invalid JSON input: " .. tostring(err)}))
            return
        end
        author = os.getenv("USER")
        updated_id, issues = entity.update(db_path, entity_type, id, values, author)
        response = {
            issues = issues
        }
        if updated_id != nil then
            response.updated_id = updated_id
            response.success = true
        else
            response.success = false
        end
        print(json.encode(response))
        return
    end

    print("Usage: daat entity <create|list|show|update|validate-json|create-json|update-json|external-ids|field-map|list-by-field> [args]")
end

-- CLI entry point: `daat extension <list|show|approve|revoke|run-pending> [args]`
-- Lives here rather than in extension.lua for the same reason build_ctx
-- does: run-pending needs entity.create/entity.update, and extension.lua
-- can't require this module back without a require cycle.
function entity.do_extension(cmd_args, db_path)
    action = cmd_args[1]
    ext_dir = config.extensions_dir()

    if action == "list" then
        for _, entry in ipairs(extension.all(ext_dir)) do
            if entry.manifest == nil then
                print(string.format("%-20s ERROR: %s", entry.name, entry.err))
            else
                status = "not approved"
                if extension.is_approved(db_path, entry.manifest) then
                    status = "approved"
                end
                print(string.format("%-20s %-14s events=%-30s entity_types=%s",
                    entry.name, status,
                    table.concat(entry.manifest.events, ","),
                    table.concat(entry.manifest.entity_types, ",")))
            end
        end
        return
    end

    if action == "show" then
        name = cmd_args[2]
        if name == nil then
            print("Usage: daat extension show <name>")
            return
        end
        manifest, err = extension.load_manifest(ext_dir, name)
        if manifest == nil then
            print("Error: " .. tostring(err))
            return
        end
        caps = manifest.capabilities
        if caps == nil then caps = {} end
        read_list = caps.read
        if read_list == nil then read_list = {} end
        write_list = caps.write
        if write_list == nil then write_list = {} end
        net = caps.net
        if net == nil then net = "none" end

        print("name:         " .. manifest.name)
        print("events:       " .. table.concat(manifest.events, ", "))
        print("entity_types: " .. table.concat(manifest.entity_types, ", "))
        print("capabilities: read=" .. table.concat(read_list, ",") ..
              " write=" .. table.concat(write_list, ",") .. " net=" .. net)
        if caps.ui != nil then
            print("route:        /ext/" .. manifest.name .. " (" .. caps.ui.icon .. " " .. caps.ui.label .. ")")
        end
        if caps.tools != nil then
            for _, tool in ipairs(caps.tools) do
                destructive = tool.destructive == true
                print("tool:         " .. manifest.name .. "." .. tool.name ..
                      " destructive=" .. tostring(destructive) .. " -- " .. tool.description)
            end
        end
        if extension.is_approved(db_path, manifest) then
            print("status:       approved")
        elseif extension.approved_capabilities(db_path, name) == nil then
            print("status:       not approved")
        else
            print("status:       NOT APPROVED -- capabilities changed since last approval, re-approval required")
        end
        return
    end

    if action == "approve" then
        name = cmd_args[2]
        if name == nil then
            print("Usage: daat extension approve <name>")
            return
        end
        manifest, err = extension.load_manifest(ext_dir, name)
        if manifest == nil then
            print("Error: " .. tostring(err))
            return
        end
        extension.approve(db_path, manifest, os.getenv("USER"))
        caps = manifest.capabilities
        if caps == nil then caps = {} end
        print("Approved '" .. name .. "' with capabilities: " .. json.encode(caps))
        return
    end

    if action == "revoke" then
        name = cmd_args[2]
        if name == nil then
            print("Usage: daat extension revoke <name>")
            return
        end
        extension.revoke(db_path, name)
        print("Revoked '" .. name .. "'")
        return
    end

    if action == "run-pending" then
        result = entity.run_pending_jobs(db_path)
        print(string.format("Ran %d, failed %d", result.ran, result.failed))
        return
    end

    print("Usage: daat extension <list|show|approve|revoke|run-pending> [args]")
end

return entity
