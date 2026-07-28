-- Entity CRUD on top of the ledger: this is where "all-or-nothing per
-- submit" validation happens (doc/project_plan.md M1, and the earlier
-- validation-rules design) -- nothing is written to the ledger or the
-- projected table unless every value passes.
--
-- v0 validates structurally (required/type/enum/reference-exists) only.
-- Scriptable before-hooks (extension-authored validation rules) are M1;
-- this is the contract they'll plug into, not a separate mechanism.

db = require("db")
ledger = require("ledger")
schema = require("schema")
config = require("config")
extension = require("extension")
json = require("dkjson")
view = require("view")

entity = {}

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
function build_ctx(db_path, manifest)
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
        if db.table_exists(db_path, target_type) == false then
            return {}
        end
        where = {}
        for k, v in pairs(filter) do
            table.insert(where, k .. " = " .. db.quote(tostring(v)))
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
            ctx = build_ctx(db_path, entry.manifest)
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

            -- task #73: genuinely executable field (label_template.sql
            -- and any future schema that reuses this type) -- reject
            -- anything but a single plain SELECT before it ever reaches
            -- the ledger. Re-checked again at render time (label.lua),
            -- not trusted from storage alone.
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
-- (nil, issues) if validation failed. Multivalue fields (task #84)
-- never become a column in the main INSERT -- they're written to their
-- own companion junction table (schema.write_multi_field) once the
-- row's own id exists. A create's own field_changes (ledger.
-- append_create, below) needs no special handling for them: JSON
-- already represents an array fine as the "new" value.
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
-- projected row). `reason` (task #93) is optional unless this type's
-- schema set require_reason_on_update -- checked here, not in
-- ledger.lua, since the ledger itself has no opinion on any particular
-- type's own policy.
--
-- Multivalue fields (task #84) are diffed as real old/new *sets* here,
-- not just a scalar inequality check, and resynced into their own
-- companion junction table (schema.write_multi_field) after the row's
-- own UPDATE -- without this, editing a multi_reference/multi_select
-- field would be completely invisible to ledger history, undermining
-- this platform's core "every change is ledgered" guarantee.
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

    return entity_id, issues
end

-- Archives an entity -- never deletes it. The row stays in the
-- projected table (still reachable via entity.get, still queryable in
-- /sql) with archived_at set; entity.list/entity.count exclude it by
-- default (pass include_archived=true to see it). Full ledger history
-- (ledger.history) is untouched either way -- this only ever adds an
-- 'archive' event, on top of whatever create/update events already
-- exist for this entity. `reason` (task #93) is optional unless this
-- type's schema set require_reason_on_archive -- archiving is the
-- stronger candidate for a schema to actually require one (rarer,
-- more consequential than a routine field edit).
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

    created_ids = {}
    for i, values in ipairs(rows_values) do
        row_source = {notebook_entry_id = source.notebook_entry_id, row_id = tostring(i)}
        id, issues = entity.create(db_path, entity_type, values, author, row_source)
        if id != nil then
            table.insert(created_ids, id)
        else
            return nil, issues
        end
    end
    return created_ids, batch_issues
end

-- Overrides a multi_reference/polymorphic_reference field's raw column
-- value with its real value, read from the companion multi_value/
-- entity_source table instead -- every raw "SELECT * FROM <entity_type>"
-- reader needs this, not just entity.get. multi_reference fields never
-- have a column at all, so a raw row simply lacks the key (harmless);
-- polymorphic_reference fields are different when a field *converts* to
-- one from a plain column type (e.g. sample.source: text ->
-- polymorphic_reference) -- schema sync is additive-only and never
-- drops the old column, so a raw row still carries that column's old,
-- stale value under the same key. Confirmed live: /browse crashed
-- rendering sample.source ("bad argument #1 to 'ipairs' (table
-- expected, got string)") because entity.list's rows were never run
-- through this override the way entity.get's already were -- only
-- entity.get had it, so /detail worked and /browse didn't.
function entity.apply_computed_field_overrides(db_path, entity_type, rows)
    multi_fields = schema.multi_fields_by_name(db_path, entity_type)
    polymorphic_fields = schema.polymorphic_fields_by_name(db_path, entity_type)
    for _, row in ipairs(rows) do
        for name, field in pairs(multi_fields) do
            row[name] = schema.read_multi_field(db_path, entity_type, row.id, field)
        end
        for name, field in pairs(polymorphic_fields) do
            row[name] = schema.read_polymorphic_field(db_path, entity_type, row.id, field)
        end
    end
    return rows
end

-- Attaches every multivalue field's current set to the returned row
-- (task #84) -- one extra schema.fields lookup plus one query per
-- multivalue field on this entity type, on every single call, including
-- the "does this referenced row exist" checks entity.validate itself
-- makes. Accepted as-is for correctness (a caller reading a row should
-- see its true complete shape) rather than optimized away -- revisit
-- only if this entity type's real read volume makes it actually show
-- up, the same "no premature optimization" bar this codebase already
-- applies elsewhere (e.g. document.search's own O(n) scan).
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
    query = "SELECT COUNT(*) AS n FROM " .. entity_type
    if include_archived != true then
        query = query .. " WHERE archived_at IS NULL"
    end
    rows = db.query(db_path, query .. ";")
    if rows == nil or rows[1] == nil then
        return 0
    end
    return tonumber(rows[1].n)
end

-- task #112: filtered siblings of entity.list/entity.count, for
-- "every X that references this Y" (e.g. a mixture's ingredients) --
-- field_name/value are trusted the same way entity_type already is
-- throughout this file (schema-registered names from cgi.lua, not raw
-- user input), quoted for safety regardless.
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

-- The schema-declared {display = true} field for this type, if any --
-- same second-priority source html.lua's own_row_label/
-- entity_display_label use (the builtin "name" column is always the
-- first source, checked directly by search_across_types below since
-- it needs both, not either/or). Reimplemented here rather than
-- shared: html.lua requires entity.lua, so the reverse require would
-- cycle. nil means this schema declared no display field.
function display_field_name(db_path, entity_type)
    for _, field in ipairs(schema.fields(db_path, entity_type)) do
        if tonumber(field.display) == 1 then
            return field.name
        end
    end
    return nil
end

-- Cross-type "find this row" search for /data's own search box (task:
-- /documents already has a fuzzy title search, /data had nothing --
-- Ben's own explicit ask). A single client-side index across every
-- entity type doesn't scale the way /documents' page-title index does
-- (many types, some already in the hundreds of rows each), so this is
-- a server-side query instead: one bounded, indexable LIKE per type,
-- against the builtin "name" column (populated for e.g. Benchling-
-- imported rows, empty otherwise -- every table has it, but not every
-- row uses it) OR'd with the schema's own display field if one is
-- declared. A type with neither ever populated simply matches nothing,
-- rather than needing an explicit skip step -- same effect, no special
-- case. per_type_limit bounds each individual query; total_limit
-- truncates the combined, concatenated result -- both needed since a
-- broad query could otherwise return per_type_limit rows from every
-- registered type at once.
function entity.search_across_types(db_path, query_text, per_type_limit, total_limit)
    if query_text == nil or query_text == "" then
        return {}
    end
    like_value = db.quote("%" .. tostring(query_text) .. "%")
    results = {}
    for _, entity_type_row in ipairs(schema.list(db_path)) do
        entity_type = entity_type_row.name
        if entity_type != "document" and db.table_exists(db_path, entity_type) == true then
            display_field = display_field_name(db_path, entity_type)
            label_expr = "name"
            where_expr = "name LIKE " .. like_value
            if display_field != nil then
                quoted_field = db.quote_ident(display_field)
                label_expr = "COALESCE(NULLIF(name, ''), " .. quoted_field .. ")"
                where_expr = "(name LIKE " .. like_value .. " OR " .. quoted_field .. " LIKE " .. like_value .. ")"
            end
            rows = db.query(db_path, string.format(
                "SELECT id, %s AS label FROM %s WHERE %s AND (archived_at IS NULL) LIMIT %d;",
                label_expr, entity_type, where_expr, tonumber(per_type_limit)
            ))
            if rows != nil then
                for _, row in ipairs(rows) do
                    if row.label != nil and tostring(row.label) != "" then
                        table.insert(results, {entity_type = entity_type, id = row.id, label = tostring(row.label)})
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
            ctx = build_ctx(db_path, manifest)
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

-- A multivalue field's value (task #84) is a plain Lua array -- tostring()
-- on that gives an unreadable "table: 0x..." pointer, so this renders it
-- as a real bracketed, comma-joined list instead. Scalars pass through.
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

-- CLI entry point: `platform entity <create|list|show|validate-json|create-json> [args]`
function entity.do_entity(cmd_args, db_path)
    action = cmd_args[1]

    if action == "create" then
        entity_type = cmd_args[2]
        if entity_type == nil then
            print("Usage: platform entity create <type> field=value [field=value ...]")
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
            print("Usage: platform entity update <type> <id> field=value [field=value ...]")
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
            print("Usage: platform entity archive <type> <id>")
            return
        end
        archived_id, issues = entity.archive(db_path, entity_type, id, os.getenv("USER"))
        if archived_id == nil then
            print("Archive failed:")
            print_issues(issues)
            return
        end
        print(string.format("Archived %s #%d", entity_type, archived_id))
        return
    end

    if action == "unarchive" then
        entity_type = cmd_args[2]
        id = tonumber(cmd_args[3])
        if entity_type == nil or id == nil then
            print("Usage: platform entity unarchive <type> <id>")
            return
        end
        unarchived_id, issues = entity.unarchive(db_path, entity_type, id, os.getenv("USER"))
        if unarchived_id == nil then
            print("Unarchive failed:")
            print_issues(issues)
            return
        end
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
            print("Usage: platform entity list <type> [--include-archived]")
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
            print("Usage: platform entity show <type> <id>")
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
            print("Usage: platform entity validate-json <type>")
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
    -- a real, backend-agnostic (SQLite or MariaDB, via db.lua's own
    -- dispatch) read path an external importer can use to detect "does
    -- a row for this source record already exist" and upsert instead of
    -- blindly re-creating it every run. Added because a prior version
    -- of that dedup logic (import_data_rest.py's own
    -- load_existing_external_ids) read a hardcoded, stale SQLite file
    -- path left over from before the fossci->platform-wip rename --
    -- that path never existed once this deployment moved to MariaDB,
    -- silently breaking dedup and causing every entity type to be
    -- re-created wholesale on every sync run (confirmed live: ~4x
    -- duplication of every table over 4 days before this was found).
    -- Every row regardless of archived_at -- an archived row's
    -- external_id is still "already imported," not fair game to
    -- recreate.
    if action == "external-ids" then
        entity_type = cmd_args[2]
        if entity_type == nil then
            print("Usage: platform entity external-ids <type>")
            return
        end
        result = {}
        if db.table_exists(db_path, entity_type) then
            rows = db.query(db_path, string.format(
                "SELECT external_id, id FROM %s WHERE external_id IS NOT NULL AND external_id != '';", entity_type
            ))
            if rows != nil then
                for _, row in ipairs(rows) do
                    result[row.external_id] = tonumber(row.id)
                end
            end
        end
        print(json.encode(result))
        return
    end

    -- {field_value: id} for every row of `entity_type` with a non-null,
    -- non-empty value for `field_name` -- same backend-agnostic lookup
    -- as external-ids, for an importer keying off some other natural
    -- column instead of (or in addition to) external_id -- e.g.
    -- convert_entries_to_pages.py's own experiment.number -> id lookup,
    -- which had the exact same hardcoded-SQLite-file bug external-ids
    -- was added to fix, just never updated to use it.
    if action == "field-map" then
        entity_type = cmd_args[2]
        field_name = cmd_args[3]
        if entity_type == nil or field_name == nil then
            print("Usage: platform entity field-map <type> <field>")
            return
        end
        result = {}
        if db.table_exists(db_path, entity_type) then
            quoted_field = db.quote_ident(field_name)
            rows = db.query(db_path, string.format(
                "SELECT %s AS field_value, id FROM %s WHERE %s IS NOT NULL AND %s != '';",
                quoted_field, entity_type, quoted_field, quoted_field
            ))
            if rows != nil then
                for _, row in ipairs(rows) do
                    result[tostring(row.field_value)] = tonumber(row.id)
                end
            end
        end
        print(json.encode(result))
        return
    end

    -- task #113: lets an external importer find every existing row
    -- referencing a given parent (e.g. an entity_type with no stable
    -- per-row external_id of its own, like a Mixture ingredient line
    -- item) so it can archive-then-recreate them safely instead of
    -- accumulating duplicates on every re-sync. Thin CLI wrapper
    -- around the existing entity.list_by_field (task #112) -- no new
    -- logic, just a new entry point for it.
    if action == "list-by-field" then
        entity_type = cmd_args[2]
        field_name = cmd_args[3]
        value = cmd_args[4]
        if entity_type == nil or field_name == nil or value == nil then
            print("Usage: platform entity list-by-field <type> <field> <value>")
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
            print("Usage: platform entity create-json <type>")
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
            print("Usage: platform entity update-json <type> <id>")
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

    print("Usage: platform entity <create|list|show|update|validate-json|create-json|update-json|external-ids|field-map|list-by-field> [args]")
end

-- CLI entry point: `platform extension <list|show|approve|revoke|run-pending> [args]`
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
            print("Usage: platform extension show <name>")
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
            print("Usage: platform extension approve <name>")
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
            print("Usage: platform extension revoke <name>")
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

    print("Usage: platform extension <list|show|approve|revoke|run-pending> [args]")
end

return entity
