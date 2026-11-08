-- Aspects: a few extra vectors for a long document, so search can find
-- it by a subject it covers anywhere in its text (doc/aspect-retrieval-plan.md).
--
-- A document's own embedding covers only its start: the embedding model
-- reads at most 2,048 tokens and drops the rest (measured on prod
-- 2026-11-04: the stored vector is the embedding of the first 7-10k
-- characters). A document longer than aspect_min_chars is split into
-- the same passages stage 2 of search uses (src/passage.lua), they are
-- grouped by meaning, and each group becomes one aspect vector.
--
-- Aspects only decide whether a document is found. They are never
-- shown, linked, heated or tiered: the document stays the unit.
-- Derived like document_embedding: rebuilt when the text changes, safe
-- to drop, refilled by `daat repair aspects`.

config = require("config")
db = require("database")
entity = require("entity")
document = require("document")
passage = require("passage")
hmac = require("hmac")

aspect = {}

-- One row per aspect of a document. vector_packed is int8: the vector
-- (cut to aspect_dims when set) scaled by its largest component, so a
-- 768-dimension aspect is 768 bytes; search renormalises on read.
-- passage_offset is where the group's most central passage starts, as
-- stage 2 shows it ("[at character N]", counting from 0);
-- member_offsets lists where each of the group's passages starts, the
-- same way, comma-separated in document order -- what curating the
-- aspect reads (src/curate.lua). text_hash covers the content, the
-- model and every setting that shapes the aspects, so a change of any
-- of them rebuilds them.
ASPECT_SCHEMA = """
CREATE TABLE IF NOT EXISTS document_aspect (
    document_id INTEGER NOT NULL,
    model VARCHAR(128) NOT NULL,
    aspect INTEGER NOT NULL,
    vector_packed BLOB NOT NULL,
    passage_offset INTEGER NOT NULL,
    passage_count INTEGER NOT NULL,
    member_offsets TEXT NOT NULL,
    text_hash VARCHAR(64) NOT NULL,
    updated_at TEXT DEFAULT (%s),
    PRIMARY KEY (document_id, model, aspect)
);
"""

function aspect.init_schema(db_path)
    db.exec(db_path, string.format(ASPECT_SCHEMA, db.now_expr(db_path)))
end

--------------------------------------------------------------------------
-- Pure parts: grouping and packing
--------------------------------------------------------------------------

function dot(a, b)
    if a == nil or b == nil or #a != #b then
        return 0.0
    end
    total = 0.0
    for i = 1, #a do
        total = total + a[i] * b[i]
    end
    return total
end

function normalized(v)
    norm = 0.0
    for i = 1, #v do
        norm = norm + v[i] * v[i]
    end
    if norm == 0.0 then
        return nil
    end
    norm = math.sqrt(norm)
    out = {}
    for i = 1, #v do
        out[i] = v[i] / norm
    end
    return out
end

-- How many aspects a document of `n` passages gets: about the square
-- root of its passages, at most `max`, at least 1.
function aspect.group_count(n, max)
    if n <= 0 then
        return 0
    end
    return math.max(1, math.min(max, math.ceil(math.sqrt(n))))
end

-- Iterations of k-means at most; it usually settles in a few.
GROUP_ITERATIONS = 12

-- aspect.group(vectors, k, seed) -> {{members, centroid, medoid}, ...}
-- Spherical k-means over unit vectors, deterministic: the first centre
-- is the vector least like `seed` (the document's own vector, which
-- already covers its opening; nil: the first vector), each next centre
-- the vector least like any centre so far, ties to the earlier one.
-- `members` are indexes into `vectors` in order, `centroid` is the
-- group's normalised mean, `medoid` the member closest to it. Empty
-- groups are dropped; groups come in the order of their first member.
function aspect.group(vectors, k, seed)
    n = #vectors
    if n == 0 or k <= 0 then
        return {}
    end
    k = math.min(k, n)
    centres = {}
    first = 1
    if seed != nil then
        lowest = nil
        for i = 1, n do
            s = dot(vectors[i], seed)
            if lowest == nil or s < lowest then
                lowest = s
                first = i
            end
        end
    end
    table.insert(centres, vectors[first])
    nearest = {}
    for i = 1, n do
        nearest[i] = dot(vectors[i], vectors[first])
    end
    while #centres < k do
        pick = nil
        lowest = nil
        for i = 1, n do
            if lowest == nil or nearest[i] < lowest then
                lowest = nearest[i]
                pick = i
            end
        end
        table.insert(centres, vectors[pick])
        for i = 1, n do
            s = dot(vectors[i], vectors[pick])
            if s > nearest[i] then
                nearest[i] = s
            end
        end
    end

    assignment = {}
    for iteration = 1, GROUP_ITERATIONS do
        changed = false
        for i = 1, n do
            best = 1
            best_score = nil
            for c = 1, #centres do
                s = dot(vectors[i], centres[c])
                if best_score == nil or s > best_score then
                    best_score = s
                    best = c
                end
            end
            if assignment[i] != best then
                assignment[i] = best
                changed = true
            end
        end
        if changed == false and iteration > 1 then
            break
        end
        for c = 1, #centres do
            sum = nil
            for i = 1, n do
                if assignment[i] == c then
                    if sum == nil then
                        sum = {}
                        for d = 1, #vectors[i] do
                            sum[d] = vectors[i][d]
                        end
                    else
                        for d = 1, #vectors[i] do
                            sum[d] = sum[d] + vectors[i][d]
                        end
                    end
                end
            end
            if sum != nil then
                unit = normalized(sum)
                if unit != nil then
                    centres[c] = unit
                end
            end
        end
    end

    groups = {}
    for c = 1, #centres do
        members = {}
        for i = 1, n do
            if assignment[i] == c then
                table.insert(members, i)
            end
        end
        if #members > 0 then
            medoid = members[1]
            best_score = nil
            for _, i in ipairs(members) do
                s = dot(vectors[i], centres[c])
                if best_score == nil or s > best_score then
                    best_score = s
                    medoid = i
                end
            end
            table.insert(groups, {members = members, centroid = centres[c], medoid = medoid})
        end
    end
    table.sort(groups, function(a, b) return a.members[1] < b.members[1] end)
    return groups
end

-- A vector cut to its first `dims` dimensions (0 or more than it has:
-- all of them) and renormalised -- how an aspect is stored and how the
-- query is compared with it.
function aspect.cut(vector, dims)
    if vector == nil then
        return nil
    end
    if dims == nil or dims <= 0 or dims >= #vector then
        return normalized(vector)
    end
    head = {}
    for i = 1, dims do
        head[i] = vector[i]
    end
    return normalized(head)
end

-- int8, scaled so the largest component is +-127. The scale isn't
-- stored: unpacking renormalises, and only direction matters.
function aspect.pack(vector, dims)
    unit = aspect.cut(vector, dims)
    if unit == nil then
        return nil
    end
    largest = 0.0
    for i = 1, #unit do
        largest = math.max(largest, math.abs(unit[i]))
    end
    q = {}
    for i = 1, #unit do
        x = unit[i] / largest * 127
        if x >= 0 then
            q[i] = math.floor(x + 0.5)
        else
            q[i] = -math.floor(-x + 0.5)
        end
    end
    return string.pack("<" .. string.rep("b", #q), table.unpack(q))
end

function aspect.unpack(packed)
    if packed == nil or packed == "" then
        return nil
    end
    values = {string.unpack("<" .. string.rep("b", string.len(packed)), packed)}
    table.remove(values) -- string.unpack's trailing "next position"
    return normalized(values)
end

--------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------

-- Everything that shapes a document's aspects, hashed with its content:
-- a change to any of them makes the stored aspects stale.
function aspect_hash(content, model, conf)
    return hmac.sha256("document_aspect", table.concat({
        tostring(model), tostring(conf.aspect_max), tostring(conf.aspect_dims), tostring(conf.aspect_vector),
        tostring(conf.passage_max_chars), tostring(conf.passage_min_chars), content}, "\n"))
end

function aspect.drop(db_path, document_id)
    db.exec(db_path, string.format("DELETE FROM document_aspect WHERE document_id = %d;", tonumber(document_id)))
end

function own_vector(db_path, document_id, model)
    rows = db.query(db_path, string.format(
        "SELECT vector_packed FROM document_embedding WHERE document_id = %d AND model = %s;",
        tonumber(document_id), db.quote(model)))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return document.unpack_vector(rows[1].vector_packed)
end

-- aspect.refresh(db_path, document_id) -> outcome, count | nil, err
-- Builds a document's aspects if they're missing or stale. Outcomes:
-- "built" (with the number of aspects), "unchanged", "short" (no
-- aspects: the document fits its own vector, any old ones dropped).
-- Passage vectors come from document_passage_cache; missing ones are
-- embedded in batches and cached, which warms stage 2 of search too.
function aspect.refresh(db_path, document_id)
    document_id = tonumber(document_id)
    conf = config.platform_config()
    agent_provider = require("agent_provider")
    model = agent_provider.embedding_model()
    if model == nil then
        return nil, "no embedding model"
    end
    doc = entity.get(db_path, "document", document_id)
    if doc == nil then
        return nil, "no such document"
    end
    text = document.embedding_text(db_path, document_id)
    content = doc.content
    if content == nil then
        content = ""
    end
    if text == nil or string.len(text) <= conf.aspect_min_chars then
        aspect.drop(db_path, document_id)
        return "short", 0
    end
    hash = aspect_hash(content, model, conf)
    rows = db.query(db_path, string.format(
        "SELECT text_hash FROM document_aspect WHERE document_id = %d AND model = %s LIMIT 1;",
        document_id, db.quote(model)))
    if rows != nil and rows[1] != nil and rows[1].text_hash == hash then
        return "unchanged", 0
    end

    passages = passage.split(content, conf.passage_max_chars, conf.passage_min_chars)
    if #passages < 2 then
        aspect.drop(db_path, document_id)
        return "short", 0
    end
    vectors_by_hash, err = passage.vectors(db_path, model, passages, #passages)
    if vectors_by_hash == nil then
        return nil, err
    end
    vectors = {}
    kept = {}
    for _, p in ipairs(passages) do
        v = vectors_by_hash[p.hash]
        if v != nil then
            table.insert(vectors, v)
            table.insert(kept, p)
        end
    end
    groups = aspect.group(vectors, aspect.group_count(#vectors, conf.aspect_max), own_vector(db_path, document_id, model))

    values = {}
    for i, g in ipairs(groups) do
        source = g.centroid
        if conf.aspect_vector == "medoid" then
            source = vectors[g.medoid]
        end
        packed = aspect.pack(source, conf.aspect_dims)
        if packed != nil then
            offsets = {}
            for _, m in ipairs(g.members) do
                table.insert(offsets, tostring(kept[m].offset - 1))
            end
            table.insert(values, string.format("(%d, %s, %d, %s, %d, %d, %s, %s, %s)",
                document_id, db.quote(model), i, document.hex_literal(packed), kept[g.medoid].offset - 1,
                #g.members, db.quote(table.concat(offsets, ",")), db.quote(hash), db.now_expr(db_path)))
        end
    end
    aspect.drop(db_path, document_id)
    if #values > 0 then
        db.exec(db_path, "INSERT INTO document_aspect (document_id, model, aspect, vector_packed, passage_offset, passage_count, member_offsets, text_hash, updated_at) VALUES " ..
            table.concat(values, ", ") .. ";")
    end
    return "built", #values
end

-- `daat repair aspects`: every active document's aspects brought up to
-- date (or one document's). Documents are visited in id order; `limit`
-- caps how many are built in one run, so a backfill can go in steps.
-- -> {built, unchanged, short, failed, aspects}
function aspect.refresh_all(db_path, limit)
    counts = {built = 0, unchanged = 0, short = 0, failed = 0, aspects = 0}
    rows = db.query(db_path, "SELECT id FROM document WHERE (archived_at IS NULL OR archived_at = '') AND (merged_into IS NULL OR merged_into = '') ORDER BY id;")
    if rows == nil then
        return counts
    end
    for _, row in ipairs(rows) do
        if limit != nil and counts.built >= limit then
            break
        end
        ok, outcome, count = pcall(aspect.refresh, db_path, row.id)
        if ok != true or outcome == nil then
            counts.failed = counts.failed + 1
            -- pcall's error, or refresh's own (nil, err). Spelled out:
            -- luam's `and`/`or` take booleans only, and the one-line
            -- version crashed prod's first backfill on its first failure.
            why = outcome
            if ok == true then
                why = count
            end
            io.write(io.stderr, string.format("document %s: aspects failed: %s\n", tostring(row.id), tostring(why)))
        else
            counts[outcome] = counts[outcome] + 1
            if outcome == "built" then
                counts.aspects = counts.aspects + count
            end
        end
    end
    return counts
end

-- aspect.passages(db_path, document_id, n) -> {passage_offset, passages} | nil
-- Aspect `n` of a document as it stands: its passages, in document
-- order, re-split from the content (passage.split is deterministic, so
-- the offsets the build stored find them again). nil when the document
-- has no such aspect, or its content changed since the build.
function aspect.passages(db_path, document_id, n)
    rows = db.query(db_path, string.format(
        "SELECT passage_offset, member_offsets FROM document_aspect WHERE document_id = %d AND aspect = %d ORDER BY model LIMIT 1;",
        tonumber(document_id), tonumber(n)))
    if rows == nil or rows[1] == nil then
        return nil
    end
    doc = entity.get(db_path, "document", tonumber(document_id))
    if doc == nil or doc.content == nil then
        return nil
    end
    conf = config.platform_config()
    by_offset = {}
    for _, p in ipairs(passage.split(doc.content, conf.passage_max_chars, conf.passage_min_chars)) do
        by_offset[p.offset - 1] = p
    end
    chosen = {}
    for offset in string.gmatch(tostring(rows[1].member_offsets), "%d+") do
        p = by_offset[tonumber(offset)]
        if p == nil then
            return nil
        end
        table.insert(chosen, p)
    end
    if #chosen == 0 then
        return nil
    end
    return {passage_offset = tonumber(rows[1].passage_offset), passages = chosen}
end

--------------------------------------------------------------------------
-- Search
--------------------------------------------------------------------------

-- aspect.best_matches(db_path, query_vector, model, where) ->
--   {[document_id] = {similarity, aspect, passage_offset}}
-- The best aspect of every searchable document against the query.
-- `where` is the searchable-document condition on `d`.
function aspect.best_matches(db_path, query_vector, model, where)
    best = {}
    query_unit = aspect.cut(query_vector, config.platform_config().aspect_dims)
    if query_unit == nil then
        return best
    end
    rows = db.query(db_path, string.format("""
        SELECT a.document_id, a.aspect, a.passage_offset, a.vector_packed
        FROM document_aspect a JOIN document d ON d.id = a.document_id
        WHERE a.model = %s AND %s;""", db.quote(model), where))
    if rows == nil then
        return best
    end
    for _, row in ipairs(rows) do
        -- A vector of another length (aspect_dims changed, not yet
        -- rebuilt) compares as 0, never as an error.
        s = dot(query_unit, aspect.unpack(row.vector_packed))
        id = tonumber(row.document_id)
        if best[id] == nil or s > best[id].similarity then
            best[id] = {similarity = s, aspect = tonumber(row.aspect), passage_offset = tonumber(row.passage_offset)}
        end
    end
    return best
end

return aspect
