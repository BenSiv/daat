-- Document semantic-embedding cache management, deferred quiet-period
-- queue draining, tag/aspect refresh hooks, and bulk reindex/repack.

const agent_provider_lib = require("agent_provider")
const aspect_lib = require("document.aspect")
const config = require("config")
const db = require("database")
const doc_pool = require("document.schema_pool")
const doc_text = require("document.text")
const entity = require("entity")
const hmac = require("hmac")
const json = require("dkjson")
const tag = require("tag")
const tag_upkeep_lib = require("tag.upkeep")
const vector_lib = require("vector")

const doc_embeddings = {}

const hex_literal = vector_lib.hex_literal
const legacy_embedding_text = doc_text.legacy_embedding_text
const embedding_text = doc_text.compute_embedding_text

function doc_embeddings.reindex_embedding(db_path, document_id, if_changed)
    doc = entity.get(db_path, "document", document_id)
    if doc == nil then
        return nil, "no such document"
    end
    text, body_chars = embedding_text(db_path, doc)

    model = agent_provider_lib.embedding_model()
    if model == nil then
        return nil, "no embedding model: no agent_provider, or it has no embeddings"
    end
    text_hash = hmac.sha256("document_embedding", text)
    if if_changed == true then
        rows = db.query(db_path, string.format(
            "SELECT model, text_hash, body_chars FROM document_embedding WHERE document_id = %d;", tonumber(document_id)))
        if rows != nil and rows[1] != nil and rows[1].model == model and rows[1].text_hash == text_hash then
            if doc_pool.sql_null_to_nil(rows[1].body_chars) == nil then
                db.exec(db_path, string.format("UPDATE document_embedding SET body_chars = %d WHERE document_id = %d;",
                    body_chars, tonumber(document_id)))
            end
            return false
        end
    end
    vector, err = agent_provider_lib.embeddings(model, text)
    if vector == nil then
        return nil, err
    end

    packed = vector_lib.pack(vector)
    packed_literal = "NULL"
    if packed != nil then
        packed_literal = hex_literal(packed)
    end
    db.exec(db_path, string.format(
        "%s document_embedding (document_id, model, vector_json, vector_packed, text_hash, body_chars, updated_at) VALUES (%d, %s, %s, %s, %s, %d, %s);",
        db.replace_into(db_path),
        tonumber(document_id), db.quote(model), db.quote(json.encode(vector)), packed_literal, db.quote(text_hash), body_chars, db.now_expr(db_path)
    ))
    return true
end

function doc_embeddings.refresh_embedding(db_path, document_id)
    old_vector = tag.document_vector(db_path, document_id)
    embedded, err = doc_embeddings.reindex_embedding(db_path, document_id, true)
    if embedded == true then
        tag.on_document_vector_changed(db_path, document_id, old_vector)
        tag.place_document(db_path, document_id)
    end
    if embedded != nil and config.platform_config().build_aspects == true then
        outcome, aspect_err = aspect_lib.refresh(db_path, document_id)
        if outcome == nil then
            return nil, "aspects: " .. tostring(aspect_err)
        end
    end
    return embedded, err
end

function utc_timestamp(seconds)
    return os.date("!%Y-%m-%d %H:%M:%S", seconds)
end

function doc_embeddings.queue_embedding(db_path, document_id)
    if config.platform_config().embedding_quiet_minutes == 0 then
        doc_embeddings.refresh_embedding(db_path, document_id)
        return
    end
    db.exec(db_path, string.format(
        "%s document_embedding_due (document_id, queued_at) VALUES (%d, %s);",
        db.replace_into(db_path), tonumber(document_id), db.quote(utc_timestamp(os.time()))))
end

function doc_embeddings.embed_pending(db_path)
    quiet_minutes = config.platform_config().embedding_quiet_minutes
    cutoff = utc_timestamp(os.time() - quiet_minutes * 60)
    rows = db.query(db_path, string.format("""
        SELECT q.document_id, q.queued_at, d.id AS live_id FROM document_embedding_due q
        LEFT JOIN document d ON d.id = q.document_id AND (d.archived_at IS NULL OR d.archived_at = '')
        WHERE q.queued_at <= %s ORDER BY q.queued_at;""", db.quote(cutoff)))
    if rows == nil then
        rows = {}
    end
    counts = {embedded = 0, unchanged = 0, failed = 0, dropped = 0, waiting = 0}
    for _, row in ipairs(rows) do
        document_id = tonumber(row.document_id)
        outcome = "dropped"
        if doc_pool.sql_null_to_nil(row.live_id) != nil then
            ok, embedded = pcall(doc_embeddings.refresh_embedding, db_path, document_id)
            if ok == true and embedded == true then
                outcome = "embedded"
            elseif ok == true and embedded == false then
                outcome = "unchanged"
            else
                outcome = "failed"
            end
        end
        counts[outcome] = counts[outcome] + 1
        if outcome != "failed" then
            db.exec(db_path, string.format(
                "DELETE FROM document_embedding_due WHERE document_id = %d AND queued_at = %s;",
                document_id, db.quote(row.queued_at)))
        end
    end
    waiting = db.query(db_path, "SELECT COUNT(*) AS n FROM document_embedding_due;")
    if waiting != nil and waiting[1] != nil then
        counts.waiting = tonumber(waiting[1].n) - counts.failed
    end
    counts.upkeep = {}
    if counts.embedded > 0 and config.platform_config().tag_restructure == true then
        ok, report = pcall(tag_upkeep_lib.run, db_path, {judge = true, apply = true})
        if ok then
            counts.upkeep = report
        else
            counts.upkeep = {"tag upkeep failed: " .. tostring(report)}
        end
    end
    return counts
end

function doc_embeddings.repack_all_embeddings(db_path)
    rows = db.query(db_path, "SELECT document_id, vector_json FROM document_embedding WHERE vector_packed IS NULL;")
    packed_count = 0
    if rows == nil then
        return 0
    end
    for _, row in ipairs(rows) do
        decoded, _, _ = json.decode(row.vector_json)
        packed = vector_lib.pack(decoded)
        if packed != nil then
            db.exec(db_path, string.format("UPDATE document_embedding SET vector_packed = %s WHERE document_id = %d;",
                hex_literal(packed), tonumber(row.document_id)))
            packed_count = packed_count + 1
        end
    end
    return packed_count
end

function doc_embeddings.reindex_all_embeddings(db_path, all)
    model = agent_provider_lib.embedding_model()
    stored = {}
    rows = db.query(db_path, "SELECT document_id, model, text_hash FROM document_embedding;")
    if rows == nil then
        rows = {}
    end
    for _, row in ipairs(rows) do
        stored[tonumber(row.document_id)] = row
    end
    reindexed = 0
    failed = 0
    unchanged = 0
    for _, doc in ipairs(doc_pool.all_active(db_path)) do
        row = stored[tonumber(doc.id)]
        legacy_current = false
        if all != true and row != nil and row.model == model and doc_pool.sql_null_to_nil(row.text_hash) == nil then
            current = entity.get(db_path, "document", doc.id)
            if current != nil then
                text, body_chars = embedding_text(db_path, current)
                if text == legacy_embedding_text(current) then
                    db.exec(db_path, string.format("UPDATE document_embedding SET text_hash = %s, body_chars = %d WHERE document_id = %d;",
                        db.quote(hmac.sha256("document_embedding", text)), body_chars, tonumber(doc.id)))
                    legacy_current = true
                end
            end
        end
        if legacy_current then
            unchanged = unchanged + 1
        else
            if_changed = all != true and row != nil and row.model == model
            ok, err = doc_embeddings.reindex_embedding(db_path, doc.id, if_changed)
            if ok == true then
                reindexed = reindexed + 1
            elseif ok == false then
                unchanged = unchanged + 1
            else
                failed = failed + 1
            end
        end
    end
    return reindexed, failed, unchanged
end

return doc_embeddings
