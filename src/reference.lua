-- References (doc/tag-ontology.md, "Evidence between tags"): an
-- implicit link from a document to an entity -- the entity's name in
-- running text. Recognised on save into document_mention, derived
-- from content alone exactly like document_link is from [[links]], so
-- dropping it and running `daat repair references` loses nothing.
--
-- A name is an entity's builtin `name` (set by importers), else its
-- schema's display field -- the same label /data's search uses -- plus
-- any field its schema marks `identifier = true` (lab_number, a catalog
-- number). Matching ignores case, spacing and separators ("Exp 185" is
-- Exp185). A deployment adds aliases for how its people write names
-- (platform.lua's reference_aliases).
--
-- entity_name_index is the lookup index (name key -> entity), kept by the
-- entity hooks so a save never loads every name; documents and the tag
-- types themselves are never in it. It holds every name, for two readers
-- with different needs:
--  * entity.find (reference.resolve) asks about one name the user wrote,
--    so any name is fair: "YPD", "Sarah Cohen", "EXP-017". One indexed
--    lookup, found or not.
--  * Document references (reference.find) scan running text, so only a
--    name marked `distinctive` counts (reference.name_key), and only when
--    it names exactly one entity: products called "A", a medium called
--    "error" or "Water" would otherwise match nearly every document
--    (measured 2026-10-04 on ~6,400 celleste-lims documents: 4,588 for
--    "A" alone). Every match at every position is kept, so a sample
--    named "Exp227 Sample96" also yields its experiment Exp227.
-- Keeping the distinctive filter on the reader rather than at write time
-- is what lets one index serve both: before #38 it only held distinctive
-- names, and entity.find needed a second, SQL-side lookup (a REPLACE/LOWER
-- scan of every table on every miss) for the rest.
--
-- entity_name_prefix holds the first REFERENCE_PREFIX_LENGTH characters
-- of every distinctive key -- 207 of them for 54,504 celleste-lims names
-- -- so a save only looks up runs that could start a name: ~490 keys for
-- a 30 KB document instead of ~11,300. Measured 2026-10-04 on 300 prod
-- documents (~30 KB each) against all 54,504 names: 41 ms per save,
-- 565 ms for the largest, down from 410 ms / 3.4 s without the prefixes.

const db = require("database")
const entity = require("entity")
const schema = require("schema")
const config = require("config")

const reference = {}

const REFERENCE_NAME_SCHEMA = """
CREATE TABLE IF NOT EXISTS entity_name_index (
    name_key VARCHAR(255) NOT NULL,
    entity_type VARCHAR(64) NOT NULL,
    entity_id INTEGER NOT NULL,
    distinctive INTEGER NOT NULL DEFAULT 1
);
"""

const DOCUMENT_REFERENCE_SCHEMA = """
CREATE TABLE IF NOT EXISTS document_mention (
    document_id INTEGER NOT NULL,
    entity_type VARCHAR(64) NOT NULL,
    entity_id INTEGER NOT NULL
);
"""

const REFERENCE_PREFIX_SCHEMA = """
CREATE TABLE IF NOT EXISTS entity_name_prefix (
    prefix VARCHAR(8) NOT NULL PRIMARY KEY
);
"""

const REFERENCE_PREFIX_LENGTH = 4

const REFERENCE_INDEXES = {
    {table = "entity_name_index", name = "idx_reference_name_key", columns = "name_key"},
    {table = "entity_name_index", name = "idx_reference_name_entity", columns = "entity_type, entity_id"},
    {table = "document_mention", name = "idx_document_reference_document", columns = "document_id"},
    {table = "document_mention", name = "idx_document_reference_entity", columns = "entity_type, entity_id"},
}

-- Never targets: documents are linked, not referenced, and the tag
-- types are about documents, not things documents name.
const REFERENCE_SKIPPED_TYPES = {document = true, document_tag = true, tag = true, tag_relation = true, tag_evidence = true}

-- reference.resolve lists every match, up to this many.
const REFERENCE_RESOLVE_LIMIT = 50

-- Rows per multi-row INSERT when rebuilding the index, as document.lua's
-- LINK_MIGRATION_BATCH: one statement per name was ~150k round trips on
-- celleste-lims, at 1-2 ms each over the Cloud SQL Auth Proxy.
const REFERENCE_INSERT_BATCH = 200

-- Words longer than this many tokens aren't names worth a lookup.
const REFERENCE_MAX_NAME_TOKENS = 8

function reference_has_column(db_path, table_name, column_name)
    for _, column in ipairs(db.get_columns(db_path, table_name)) do
        if column == column_name then
            return true
        end
    end
    return false
end

function reference.init_schema(db_path)
    db.exec(db_path, REFERENCE_NAME_SCHEMA)
    db.exec(db_path, DOCUMENT_REFERENCE_SCHEMA)
    db.exec(db_path, REFERENCE_PREFIX_SCHEMA)
    -- An index built before #38 holds only distinctive names, so 1 is
    -- right for every row already there. The names it lacks ("YPD") are
    -- added by `daat repair references --names-only`.
    if reference_has_column(db_path, "entity_name_index", "distinctive") == false then
        ok, err = pcall(db.exec, db_path, "ALTER TABLE entity_name_index ADD COLUMN distinctive INTEGER NOT NULL DEFAULT 1;")
        -- Concurrent first requests race to add it; only an error if it's still missing.
        if ok == false and reference_has_column(db_path, "entity_name_index", "distinctive") == false then
            error(err)
        end
    end
    for _, index in ipairs(REFERENCE_INDEXES) do
        if db.index_exists(db_path, index.table, index.name) == false then
            ok, err = pcall(db.exec, db_path, string.format("CREATE INDEX %s ON %s (%s);", index.name, index.table, index.columns))
            -- Concurrent first requests race to add it; only an error if it's still missing.
            if ok == false and db.index_exists(db_path, index.table, index.name) == false then
                error(err)
            end
        end
    end
end

-- Lowercase tokens: a letter or digit, then letters, digits and . _ / + % -
-- (so "C.COT.IN-1.2" is one token), trailing punctuation dropped.
function reference.tokens(text)
    out = {}
    for token in string.gmatch(string.lower(text), "[%w][%w%._/%+%%%-]*") do
        token, _ = string.gsub(token, "[%._/%+%%%-]+$", "")
        table.insert(out, token)
    end
    return out
end

function reference_squash(tokens, first, last)
    key, _ = string.gsub(table.concat(tokens, "", first, last), "[^%w]", "")
    return key
end

-- A name's lookup key, or nil when it isn't distinctive enough to be a
-- reference target: 4+ characters, a letter, and a digit or punctuation
-- inside a word. The key ignores case, spacing and separators.
function reference.name_key(name)
    if name == nil then
        return nil
    end
    compact, _ = string.gsub(tostring(name), "%s", "")
    if string.len(compact) < 4 or string.find(compact, "%a") == nil then
        return nil
    end
    if string.find(compact, "%d") == nil and string.find(compact, "%w[%.%-/,%+]%w") == nil then
        return nil
    end
    tokens = reference.tokens(name)
    if #tokens == 0 or #tokens > REFERENCE_MAX_NAME_TOKENS then
        return nil
    end
    key = reference_squash(tokens, 1, #tokens)
    if string.len(key) < 4 or string.len(key) > 255 then
        return nil
    end
    return key
end

-- Any name's lookup key, distinctive or not ("YPD" is "ypd"), or nil when
-- nothing's left of it or it's too long to index. Same tokens and squash
-- as reference.name_key, so a distinctive name has one key, not two.
function reference.lookup_key(name)
    if name == nil then
        return nil
    end
    tokens = reference.tokens(tostring(name))
    if #tokens == 0 then
        return nil
    end
    key = reference_squash(tokens, 1, #tokens)
    if key == "" or string.len(key) > 255 then
        return nil
    end
    return key
end

-- The key a name is looked up by, after the deployment's aliases ("Experiment
-- 027" is written for EXP-027), the same rewrite reference.candidate_keys
-- gives document text.
function reference_aliased(text)
    text = string.lower(tostring(text))
    aliases = config.platform_config().reference_aliases
    if aliases != nil then
        for _, alias in ipairs(aliases) do
            text, _ = string.gsub(text, alias[1], alias[2])
        end
    end
    return text
end

-- Every candidate key in a text, each once: the squashed form of each
-- run of up to REFERENCE_MAX_NAME_TOKENS tokens that could be a
-- distinctive name -- a digit in it, or punctuation between two
-- characters of one of its tokens ("C.SE.IND"). `aliases` ({{pattern,
-- replacement}, ...}, Lua patterns over the lowercased text) run first.
-- Each token is squashed and checked once and each run's key grown from
-- the last; with `prefixes` (a set of key prefixes), a run whose first
-- REFERENCE_PREFIX_LENGTH characters start no name ends there, with
-- every longer run from the same token. Pure.
function reference.candidate_keys(text, aliases, prefixes)
    text = string.lower(text)
    if aliases != nil then
        for _, alias in ipairs(aliases) do
            text, _ = string.gsub(text, alias[1], alias[2])
        end
    end
    tokens = reference.tokens(text)
    squashed, marked = {}, {}
    for i, token in ipairs(tokens) do
        squashed[i], _ = string.gsub(token, "[^%w]", "")
        marked[i] = string.find(token, "%d") != nil or string.find(token, "%w[%._/%+%%%-]%w") != nil
    end
    keys, seen = {}, {}
    for i = 1, #tokens do
        key = ""
        distinctive = false
        last = i + REFERENCE_MAX_NAME_TOKENS - 1
        if last > #tokens then
            last = #tokens
        end
        checked = prefixes == nil
        for j = i, last do
            key = key .. squashed[j]
            if string.len(key) > 255 then
                break
            end
            if checked == false and string.len(key) >= REFERENCE_PREFIX_LENGTH then
                if prefixes[string.sub(key, 1, REFERENCE_PREFIX_LENGTH)] == nil then
                    break
                end
                checked = true
            end
            if marked[j] then
                distinctive = true
            end
            if distinctive and string.len(key) >= 4 and seen[key] == nil then
                seen[key] = true
                table.insert(keys, key)
            end
        end
    end
    return keys
end

function reference_filled(value)
    return value != nil and tostring(value) != ""
end

-- The entity's label: its builtin name, else its first filled display
-- field, else nil. `fields` is its type's schema.fields, read once by the
-- caller rather than once per row.
function reference_label(fields, row)
    if reference_filled(row.name) then
        return tostring(row.name)
    end
    for _, field in ipairs(fields) do
        if tonumber(field.display) == 1 and reference_filled(row[field.name]) then
            return tostring(row[field.name])
        end
    end
    return nil
end

-- Every name an entity goes by: {{field =, value =}, ...}, its label first,
-- then each identifier field. A display field that isn't the label (the row
-- has a builtin name) isn't a name; one meant as an alternate name is
-- marked identifier as well.
function reference_names(fields, row)
    names = {}
    labelled = false
    if reference_filled(row.name) then
        table.insert(names, {field = "name", value = tostring(row.name)})
        labelled = true
    end
    for _, field in ipairs(fields) do
        value = row[field.name]
        if reference_filled(value) then
            is_label = labelled == false and tonumber(field.display) == 1
            if is_label then
                labelled = true
            end
            if is_label or tonumber(field.identifier) == 1 then
                table.insert(names, {field = field.name, value = tostring(value)})
            end
        end
    end
    return names
end

-- One entity's index rows, {{key =, distinctive =}, ...}, each key once. Two
-- names can share a key ("EXP-017" and "Exp 017"), and a repeated row would
-- look like two entities to reference.find, which skips a key naming more
-- than one. A key is distinctive when any name giving it is.
function reference_index_rows(fields, row)
    out = {}
    by_key = {}
    for _, name in ipairs(reference_names(fields, row)) do
        key = reference.lookup_key(name.value)
        if key != nil then
            distinctive = reference.name_key(name.value) != nil
            if by_key[key] == nil then
                by_key[key] = {key = key, distinctive = distinctive}
                table.insert(out, by_key[key])
            elseif distinctive then
                by_key[key].distinctive = true
            end
        end
    end
    return out
end

-- One "(...)" VALUES tuple for entity_name_index.
function reference_index_values(key, entity_type, entity_id, distinctive)
    flag = 0
    if distinctive then
        flag = 1
    end
    return string.format("(%s, %s, %d, %d)", db.quote(key), db.quote(entity_type), tonumber(entity_id), flag)
end

function reference_insert_index(db_path, values)
    if #values > 0 then
        db.exec(db_path, "INSERT INTO entity_name_index (name_key, entity_type, entity_id, distinctive) VALUES "
            .. table.concat(values, ", ") .. ";")
    end
end

-- A prefix is only ever added: one no name uses any more costs a few
-- wasted lookups until the next `daat repair references`, never a miss.
function reference_add_prefix(db_path, key)
    prefix = string.sub(key, 1, REFERENCE_PREFIX_LENGTH)
    rows = db.query(db_path, string.format("SELECT prefix FROM entity_name_prefix WHERE prefix = %s;", db.quote(prefix)))
    if rows == nil or #rows == 0 then
        -- Two saves adding the same new prefix at once: the loser's insert fails, harmlessly.
        pcall(db.exec, db_path, string.format("INSERT INTO entity_name_prefix (prefix) VALUES (%s);", db.quote(prefix)))
    end
end

-- Whether a type's entities are in the index at all, for entity.find to
-- say so instead of claiming it checked them.
function reference.is_indexed_type(entity_type)
    return REFERENCE_SKIPPED_TYPES[entity_type] == nil
end

-- Keeps entity_name_index in step with one entity (create, update,
-- archive, unarchive all land here): its rows are replaced, one per
-- name, or dropped when it's archived or gone.
function reference.index_entity(db_path, entity_type, entity_id)
    if REFERENCE_SKIPPED_TYPES[entity_type] != nil then
        return
    end
    db.exec(db_path, string.format("DELETE FROM entity_name_index WHERE entity_type = %s AND entity_id = %d;",
        db.quote(entity_type), tonumber(entity_id)))
    row = entity.get(db_path, entity_type, entity_id)
    if row == nil or (row.archived_at != nil and row.archived_at != "") then
        return
    end
    values = {}
    for _, name in ipairs(reference_index_rows(schema.fields(db_path, entity_type), row)) do
        table.insert(values, reference_index_values(name.key, entity_type, entity_id, name.distinctive))
        if name.distinctive then
            reference_add_prefix(db_path, name.key)
        end
    end
    reference_insert_index(db_path, values)
end

-- The columns rebuild_names reads from a type's table: id, the builtin
-- name, and its display and identifier fields. `SELECT *` pulled every
-- row's large text columns too (expression_profile's sample_values on
-- celleste-lims) over the Auth Proxy, only to read two or three of them.
function reference_name_columns(db_path, entity_type, fields)
    present = {}
    for _, column in ipairs(db.get_columns(db_path, entity_type)) do
        present[column] = true
    end
    columns = {"id"}
    if present["name"] != nil then
        table.insert(columns, "name")
    end
    for _, field in ipairs(fields) do
        if (tonumber(field.display) == 1 or tonumber(field.identifier) == 1)
                and field.name != "name" and present[field.name] != nil then
            table.insert(columns, field.name)
        end
    end
    quoted = {}
    for _, column in ipairs(columns) do
        table.insert(quoted, db.quote_ident(column))
    end
    return table.concat(quoted, ", ")
end

-- `daat repair references` (first half, and all of --names-only): every
-- entity's names re-indexed. Per type: its fields read once, only the
-- naming columns selected, the rows inserted REFERENCE_INSERT_BATCH at a
-- time. Returns how many index rows it wrote.
function reference.rebuild_names(db_path)
    -- Its own tables, idempotently: `daat repair references` from the CLI
    -- after a deploy can run before any web request has added `distinctive`.
    reference.init_schema(db_path)
    db.exec(db_path, "DELETE FROM entity_name_index;")
    db.exec(db_path, "DELETE FROM entity_name_prefix;")
    prefixes = {}
    indexed = 0
    for _, type_row in ipairs(schema.list(db_path)) do
        entity_type = type_row.name
        if REFERENCE_SKIPPED_TYPES[entity_type] == nil and db.table_exists(db_path, entity_type) == true then
            fields = schema.fields(db_path, entity_type)
            rows = db.query(db_path, string.format(
                "SELECT %s FROM %s WHERE archived_at IS NULL OR archived_at = '';",
                reference_name_columns(db_path, entity_type, fields), db.quote_ident(entity_type)))
            values = {}
            if rows != nil then
                for _, row in ipairs(rows) do
                    for _, name in ipairs(reference_index_rows(fields, row)) do
                        table.insert(values, reference_index_values(name.key, entity_type, row.id, name.distinctive))
                        if name.distinctive then
                            prefixes[string.sub(name.key, 1, REFERENCE_PREFIX_LENGTH)] = true
                        end
                        if #values == REFERENCE_INSERT_BATCH then
                            reference_insert_index(db_path, values)
                            indexed = indexed + #values
                            values = {}
                        end
                    end
                end
            end
            reference_insert_index(db_path, values)
            indexed = indexed + #values
        end
    end
    -- IGNORE: two prefixes distinct in Lua can be one value to MariaDB's
    -- case- and accent-insensitive collation; a plain INSERT aborted the
    -- whole repair on prod after the index was rebuilt (2026-11-08,
    -- 'm6a1'), before any document was re-read.
    for prefix, _ in pairs(prefixes) do
        db.exec(db_path, string.format("%s entity_name_prefix (prefix) VALUES (%s);",
            db.insert_ignore(db_path), db.quote(prefix)))
    end
    return indexed
end

-- The entities a text references: {{entity_type =, entity_id =}, ...},
-- each once. A key naming more than one entity is ambiguous and skipped.
function reference.find(db_path, text)
    found = {}
    if text == nil or text == "" then
        return found
    end
    prefix_rows = db.query(db_path, "SELECT prefix FROM entity_name_prefix;")
    if prefix_rows == nil or #prefix_rows == 0 then
        return found
    end
    prefixes = {}
    for _, row in ipairs(prefix_rows) do
        prefixes[row.prefix] = true
    end
    keys = reference.candidate_keys(text, config.platform_config().reference_aliases, prefixes)
    targets = {}
    for start = 1, #keys, 500 do
        quoted = {}
        last = start + 499
        if last > #keys then
            last = #keys
        end
        for i = start, last do
            table.insert(quoted, db.quote(keys[i]))
        end
        rows = db.query(db_path, string.format(
            "SELECT name_key, entity_type, entity_id FROM entity_name_index WHERE name_key IN (%s) AND distinctive = 1;",
            table.concat(quoted, ", ")))
        if rows != nil then
            for _, row in ipairs(rows) do
                if targets[row.name_key] == nil then
                    targets[row.name_key] = {}
                end
                table.insert(targets[row.name_key], {entity_type = row.entity_type, entity_id = tonumber(row.entity_id)})
            end
        end
    end
    seen = {}
    for _, hits in pairs(targets) do
        if #hits == 1 then
            key = hits[1].entity_type .. ":" .. tostring(hits[1].entity_id)
            if seen[key] == nil then
                seen[key] = true
                table.insert(found, hits[1])
            end
        end
    end
    return found
end

-- Which active entities a name refers to, for entity.find (#38): every
-- match as {entity_type =, entity_id =, label =, field =, value =}, sorted,
-- optionally of one type. `label` is nil for an entity with no builtin name
-- or filled display field. Exact on the whole name, ignoring case, spacing
-- and separators, with the deployment's aliases applied -- the same tokens,
-- squash and aliases as document references, so the two can't disagree on
-- what a name is. One indexed lookup, found or not. No ranking and no
-- partial match: those belong to document.search and /data's search box.
-- Unlike reference.find, a name more than one entity shares isn't dropped,
-- and a name that isn't distinctive counts, since here the caller is told
-- about every match.
function reference.resolve(db_path, text, entity_type)
    if text == nil then
        return {}
    end
    keys = {}
    wanted = {}
    for _, written in ipairs({tostring(text), reference_aliased(text)}) do
        key = reference.lookup_key(written)
        if key != nil and wanted[key] == nil then
            wanted[key] = true
            table.insert(keys, db.quote(key))
        end
    end
    if #keys == 0 then
        return {}
    end
    type_filter = ""
    if entity_type != nil then
        type_filter = " AND entity_type = " .. db.quote(entity_type)
    end
    indexed = db.query(db_path, string.format(
        "SELECT DISTINCT entity_type, entity_id FROM entity_name_index WHERE name_key IN (%s)%s LIMIT %d;",
        table.concat(keys, ", "), type_filter, REFERENCE_RESOLVE_LIMIT))
    hits = {}
    if indexed == nil then
        return hits
    end
    for _, hit in ipairs(indexed) do
        row = entity.get(db_path, hit.entity_type, tonumber(hit.entity_id))
        -- The index is kept by hooks each caller runs after archiving, so
        -- it can lag; a name must not resolve to an archived entity.
        if row != nil and (row.archived_at == nil or row.archived_at == "") then
            fields = schema.fields(db_path, hit.entity_type)
            -- Which of its names matched, re-read from the row: a stale
            -- index row (a field no longer an identifier) matches none.
            for _, name in ipairs(reference_names(fields, row)) do
                name_key = reference.lookup_key(name.value)
                if name_key != nil and wanted[name_key] != nil then
                    table.insert(hits, {
                        entity_type = hit.entity_type,
                        entity_id = tonumber(row.id),
                        label = reference_label(fields, row),
                        field = name.field,
                        value = name.value,
                    })
                    break
                end
            end
        end
    end
    table.sort(hits, function(a, b)
        if a.entity_type == b.entity_type then
            return a.entity_id < b.entity_id
        end
        return a.entity_type < b.entity_type
    end)
    return hits
end

-- On save, next to document.sync_links: the document's references,
-- recomputed from its title and content.
function reference.sync_document(db_path, document_id, title, content)
    text = ""
    if title != nil then
        text = tostring(title)
    end
    if content != nil then
        text = text .. "\n" .. tostring(content)
    end
    found = reference.find(db_path, text)
    db.exec(db_path, string.format("DELETE FROM document_mention WHERE document_id = %d;", tonumber(document_id)))
    for _, hit in ipairs(found) do
        db.exec(db_path, string.format("INSERT INTO document_mention (document_id, entity_type, entity_id) VALUES (%d, %s, %d);",
            tonumber(document_id), db.quote(hit.entity_type), hit.entity_id))
    end
    return #found
end

-- `daat repair references` (second half): every active document re-read.
function reference.resync_all_documents(db_path)
    rows = db.query(db_path, "SELECT id, title, content FROM document WHERE archived_at IS NULL OR archived_at = '';")
    count = 0
    if rows == nil then
        return count
    end
    for _, row in ipairs(rows) do
        reference.sync_document(db_path, tonumber(row.id), row.title, row.content)
        count = count + 1
    end
    return count
end

-- Exposed so verify.lua can compare entity_name_index against the exact
-- expected per-entity index rows without duplicating reference_names.
reference.expected_index_rows = reference_index_rows

return reference
