-- References (doc/tag-ontology.md, "Evidence between tags"): an
-- implicit link from a document to an entity -- the entity's name in
-- running text. Recognised on save into document_reference, derived
-- from content alone exactly like document_link is from [[links]], so
-- dropping it and running `daat repair references` loses nothing.
--
-- A name is an entity's builtin `name` (set by importers), else its
-- schema's display field -- the same label /data's search uses. It's
-- only a reference target when it's distinctive (reference.name_key)
-- and names exactly one entity: products called "A", a medium called
-- "error" or "Water" would otherwise match nearly every document
-- (measured 2026-10-04 on ~6,400 celleste-lims documents: 4,588 for
-- "A" alone). Matching ignores case, spacing and separators ("Exp 185"
-- is Exp185), and keeps every match at every position, so a sample
-- named "Exp227 Sample96" also yields its experiment Exp227. A
-- deployment adds aliases for how its people write names
-- (platform.lua's reference_aliases).
--
-- reference_name is the lookup index (name key -> entity), kept by the
-- entity hooks so a save never loads every name; documents and the tag
-- types themselves are never reference targets. reference_prefix holds
-- the first REFERENCE_PREFIX_LENGTH characters of every key -- 207 of
-- them for 54,504 celleste-lims names -- so a save only looks up runs
-- that could start a name: ~490 keys for a 30 KB document instead of
-- ~11,300. Measured 2026-10-04 on 300 prod documents (~30 KB each)
-- against all 54,504 names: 41 ms per save, 565 ms for the largest,
-- down from 410 ms / 3.4 s without the prefixes.

db = require("database")
entity = require("entity")
schema = require("schema")
config = require("config")

reference = {}

REFERENCE_NAME_SCHEMA = """
CREATE TABLE IF NOT EXISTS reference_name (
    name_key VARCHAR(255) NOT NULL,
    entity_type VARCHAR(64) NOT NULL,
    entity_id INTEGER NOT NULL
);
"""

DOCUMENT_REFERENCE_SCHEMA = """
CREATE TABLE IF NOT EXISTS document_reference (
    document_id INTEGER NOT NULL,
    entity_type VARCHAR(64) NOT NULL,
    entity_id INTEGER NOT NULL
);
"""

REFERENCE_PREFIX_SCHEMA = """
CREATE TABLE IF NOT EXISTS reference_prefix (
    prefix VARCHAR(8) NOT NULL PRIMARY KEY
);
"""

REFERENCE_PREFIX_LENGTH = 4

REFERENCE_INDEXES = {
    {table = "reference_name", name = "idx_reference_name_key", columns = "name_key"},
    {table = "reference_name", name = "idx_reference_name_entity", columns = "entity_type, entity_id"},
    {table = "document_reference", name = "idx_document_reference_document", columns = "document_id"},
    {table = "document_reference", name = "idx_document_reference_entity", columns = "entity_type, entity_id"},
}

-- Never targets: documents are linked, not referenced, and the tag
-- types are about documents, not things documents name.
REFERENCE_SKIPPED_TYPES = {document = true, document_tag = true, tag = true, tag_relation = true, tag_evidence = true}

-- Words longer than this many tokens aren't names worth a lookup.
REFERENCE_MAX_NAME_TOKENS = 8

function reference.init_schema(db_path)
    db.exec(db_path, REFERENCE_NAME_SCHEMA)
    db.exec(db_path, DOCUMENT_REFERENCE_SCHEMA)
    db.exec(db_path, REFERENCE_PREFIX_SCHEMA)
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

-- The entity's label: its builtin name, else its display field.
function reference_label(db_path, entity_type, row)
    if row.name != nil and tostring(row.name) != "" then
        return tostring(row.name)
    end
    for _, field in ipairs(schema.fields(db_path, entity_type)) do
        if tonumber(field.display) == 1 and row[field.name] != nil then
            return tostring(row[field.name])
        end
    end
    return nil
end

-- A prefix is only ever added: one no name uses any more costs a few
-- wasted lookups until the next `daat repair references`, never a miss.
function reference_add_prefix(db_path, key)
    prefix = string.sub(key, 1, REFERENCE_PREFIX_LENGTH)
    rows = db.query(db_path, string.format("SELECT prefix FROM reference_prefix WHERE prefix = %s;", db.quote(prefix)))
    if rows == nil or #rows == 0 then
        -- Two saves adding the same new prefix at once: the loser's insert fails, harmlessly.
        pcall(db.exec, db_path, string.format("INSERT INTO reference_prefix (prefix) VALUES (%s);", db.quote(prefix)))
    end
end

-- Keeps reference_name in step with one entity (create, update,
-- archive, unarchive all land here): its row is replaced, or dropped
-- when it's archived, gone, or its name isn't distinctive.
function reference.index_entity(db_path, entity_type, entity_id)
    if REFERENCE_SKIPPED_TYPES[entity_type] != nil then
        return
    end
    db.exec(db_path, string.format("DELETE FROM reference_name WHERE entity_type = %s AND entity_id = %d;",
        db.quote(entity_type), tonumber(entity_id)))
    row = entity.get(db_path, entity_type, entity_id)
    if row == nil or (row.archived_at != nil and row.archived_at != "") then
        return
    end
    key = reference.name_key(reference_label(db_path, entity_type, row))
    if key != nil then
        db.exec(db_path, string.format("INSERT INTO reference_name (name_key, entity_type, entity_id) VALUES (%s, %s, %d);",
            db.quote(key), db.quote(entity_type), tonumber(entity_id)))
        reference_add_prefix(db_path, key)
    end
end

-- `daat repair references` (first half): every entity's name re-indexed.
function reference.rebuild_names(db_path)
    db.exec(db_path, "DELETE FROM reference_name;")
    db.exec(db_path, "DELETE FROM reference_prefix;")
    prefixes = {}
    indexed = 0
    for _, type_row in ipairs(schema.list(db_path)) do
        entity_type = type_row.name
        if REFERENCE_SKIPPED_TYPES[entity_type] == nil and db.table_exists(db_path, entity_type) == true then
            rows = db.query(db_path, string.format(
                "SELECT * FROM %s WHERE archived_at IS NULL OR archived_at = '';", entity_type))
            if rows != nil then
                for _, row in ipairs(rows) do
                    key = reference.name_key(reference_label(db_path, entity_type, row))
                    if key != nil then
                        db.exec(db_path, string.format(
                            "INSERT INTO reference_name (name_key, entity_type, entity_id) VALUES (%s, %s, %d);",
                            db.quote(key), db.quote(entity_type), tonumber(row.id)))
                        indexed = indexed + 1
                        prefixes[string.sub(key, 1, REFERENCE_PREFIX_LENGTH)] = true
                    end
                end
            end
        end
    end
    for prefix, _ in pairs(prefixes) do
        db.exec(db_path, string.format("INSERT INTO reference_prefix (prefix) VALUES (%s);", db.quote(prefix)))
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
    prefix_rows = db.query(db_path, "SELECT prefix FROM reference_prefix;")
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
            "SELECT name_key, entity_type, entity_id FROM reference_name WHERE name_key IN (%s);", table.concat(quoted, ", ")))
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
    db.exec(db_path, string.format("DELETE FROM document_reference WHERE document_id = %d;", tonumber(document_id)))
    for _, hit in ipairs(found) do
        db.exec(db_path, string.format("INSERT INTO document_reference (document_id, entity_type, entity_id) VALUES (%d, %s, %d);",
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

return reference
