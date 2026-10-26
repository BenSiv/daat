-- Passages: the most relevant parts of a document for one question,
-- chosen at search time (doc/passage-retrieval.md). Documents are
-- embedded and searched whole; once search has narrowed them down, each
-- shortlisted document is split here along its own structure, its
-- passages are scored against the question, and only the best are
-- shown -- to the agent and on the /documents page alike.
--
-- Nothing is stored as chunks: passages are derived from the document's
-- current text every time, so as documents are distilled and edited
-- their passages change with them. Only passage embeddings are cached
-- (document_passage_cache), keyed by the passage text, and they expire.

config = require("config")
db = require("database")
document = require("document")
hmac = require("hmac")

passage = {}

--------------------------------------------------------------------------
-- The embedding cache
--------------------------------------------------------------------------

-- One row per (passage text, embedding model). Derived and safe to empty
-- at any time; keyed by text, not document, so identical passages share
-- an entry and an edited document's old passages simply stop being used
-- and expire (passage_cache_days after last_used_at).
PASSAGE_CACHE_SCHEMA = """
CREATE TABLE IF NOT EXISTS document_passage_cache (
    text_hash VARCHAR(64) NOT NULL,
    model VARCHAR(128) NOT NULL,
    vector_packed BLOB NOT NULL,
    created_at TEXT DEFAULT (%s),
    last_used_at TEXT DEFAULT (%s),
    PRIMARY KEY (text_hash, model)
);
"""

function passage.init_schema(db_path)
    db.exec(db_path, string.format(PASSAGE_CACHE_SCHEMA, db.now_expr(db_path), db.now_expr(db_path)))
end

function passage.text_hash(text)
    return hmac.sha256("document_passage", text)
end

function quoted_list(values)
    parts = {}
    for _, v in ipairs(values) do
        table.insert(parts, db.quote(v))
    end
    return table.concat(parts, ", ")
end

-- passage.cache_get(db_path, model, hashes) -> {[hash] = unit vector}
-- One query for all of them; found entries get last_used_at refreshed
-- in one UPDATE.
function passage.cache_get(db_path, model, hashes)
    found = {}
    if #hashes == 0 then
        return found
    end
    rows = db.query(db_path, string.format(
        "SELECT text_hash, vector_packed FROM document_passage_cache WHERE model = %s AND text_hash IN (%s);",
        db.quote(model), quoted_list(hashes)))
    hit = {}
    if rows == nil then
        rows = {}
    end
    for _, row in ipairs(rows) do
        vector = document.unpack_vector(row.vector_packed)
        if vector != nil then
            found[row.text_hash] = vector
            table.insert(hit, row.text_hash)
        end
    end
    if #hit > 0 then
        db.exec(db_path, string.format(
            "UPDATE document_passage_cache SET last_used_at = %s WHERE model = %s AND text_hash IN (%s);",
            db.now_expr(db_path), db.quote(model), quoted_list(hit)))
    end
    return found
end

-- passage.cache_put(db_path, model, entries): entries {{hash, vector}};
-- stores each L2-normalised and packed, as document_embedding does.
-- Returns {[hash] = unit vector} for what it stored.
function passage.cache_put(db_path, model, entries)
    stored = {}
    values = {}
    for _, entry in ipairs(entries) do
        packed = document.pack_vector(entry[2])
        if packed != nil then
            table.insert(values, string.format("(%s, %s, %s, %s, %s)", db.quote(entry[1]), db.quote(model),
                document.hex_literal(packed), db.now_expr(db_path), db.now_expr(db_path)))
            stored[entry[1]] = document.unpack_vector(packed)
        end
    end
    if #values > 0 then
        db.exec(db_path, string.format(
            "%s document_passage_cache (text_hash, model, vector_packed, created_at, last_used_at) VALUES %s;",
            db.replace_into(db_path), table.concat(values, ", ")))
    end
    return stored
end

-- passage.prune_cache(db_path, days) -> rows deleted
-- Entries unused for longer than `days` (passage_cache_days); <= 0
-- keeps everything. Times compare as UTC 'YYYY-MM-DD HH:MM:SS' text,
-- the form both backends' now() writes.
function passage.prune_cache(db_path, days)
    if days == nil or days <= 0 then
        return 0
    end
    cutoff = os.date("!%Y-%m-%d %H:%M:%S", os.time() - math.floor(days * 86400))
    rows = db.query(db_path, string.format(
        "SELECT COUNT(*) AS n FROM document_passage_cache WHERE last_used_at < %s;", db.quote(cutoff)))
    count = 0
    if rows != nil and rows[1] != nil then
        count = tonumber(rows[1].n)
    end
    if count > 0 then
        db.exec(db_path, string.format("DELETE FROM document_passage_cache WHERE last_used_at < %s;", db.quote(cutoff)))
    end
    return count
end

-- The last index in [from, to] where `pattern` (a Lua pattern whose
-- match should end the piece) matches, as the index of the match's last
-- character; nil if none.
function last_break(content, from, to, pattern)
    found = nil
    position = from
    while true do
        s, e = string.find(content, pattern, position)
        if s == nil or e > to then
            break
        end
        found = e
        position = s + 1
    end
    return found
end

-- Cuts content[a..b] into pieces of at most `max_chars`, preferring
-- paragraph breaks, then sentence ends, then any whitespace; a run with
-- none of those (one enormous token) is cut at the limit. Returns a list
-- of {first, last} index pairs covering a..b exactly.
function split_range(content, a, b, max_chars)
    pieces = {}
    while b - a + 1 > max_chars do
        limit = a + max_chars - 1
        -- Not so early that the piece is a sliver.
        floor = a + math.floor(max_chars / 4)
        cut = last_break(content, floor, limit, "\n[ \t]*\n")
        if cut == nil then
            cut = last_break(content, floor, limit, "[%.!%?][\"')%]]*%s")
        end
        if cut == nil then
            cut = last_break(content, floor, limit, "%s")
        end
        if cut == nil then
            cut = limit
        end
        table.insert(pieces, {a, cut})
        a = cut + 1
    end
    if a <= b then
        table.insert(pieces, {a, b})
    end
    return pieces
end

-- The start index of every heading line ("#", "##", ... then a space)
-- at or after `from`.
function heading_starts(content, from)
    starts = {}
    if string.find(string.sub(content, from, from + 6), "^#+%s") != nil then
        table.insert(starts, from)
    end
    position = from
    while true do
        nl = string.find(content, "\n", position, true)
        if nl == nil then
            break
        end
        if string.find(string.sub(content, nl + 1, nl + 8), "^#+%s") != nil then
            table.insert(starts, nl + 1)
        end
        position = nl + 1
    end
    return starts
end

function line_at(content, index)
    line_end = string.find(content, "\n", index, true)
    if line_end == nil then
        return string.sub(content, index)
    end
    return string.sub(content, index, line_end - 1)
end

-- passage.split(content, max_chars, min_chars) -> {{text, offset, heading}, ...}
-- The document's own text (past any metadata preamble) cut at its
-- headings, sections longer than max_chars cut further (split_range),
-- and pieces shorter than min_chars merged into a neighbour. Every
-- passage is an exact contiguous slice: string.sub(content, offset,
-- offset + #text - 1) == text. `heading` is the nearest heading line at
-- or before the passage (nil if none), for showing what it's about.
-- Deterministic: the same content always gives the same passages.
function passage.split(content, max_chars, min_chars)
    if content == nil or content == "" then
        return {}
    end
    first = document.preamble_end(content)
    last = string.len(content)
    if first > last then
        return {}
    end
    headings = heading_starts(content, first)
    -- Sections: from the text start to the first heading (if any text
    -- comes before it), then heading to heading.
    bounds = {}
    if #headings == 0 or headings[1] > first then
        table.insert(bounds, first)
    end
    for _, h in ipairs(headings) do
        table.insert(bounds, h)
    end
    pieces = {}
    for i, a in ipairs(bounds) do
        b = last
        if bounds[i + 1] != nil then
            b = bounds[i + 1] - 1
        end
        for _, piece in ipairs(split_range(content, a, b, max_chars)) do
            table.insert(pieces, piece)
        end
    end
    -- Merge slivers forward (into the next piece), the last one backward.
    merged = {}
    carry = nil
    for _, piece in ipairs(pieces) do
        if carry != nil then
            piece = {carry, piece[2]}
            carry = nil
        end
        if piece[2] - piece[1] + 1 < min_chars then
            carry = piece[1]
        else
            table.insert(merged, piece)
        end
    end
    if carry != nil then
        if #merged > 0 then
            merged[#merged][2] = last
        else
            table.insert(merged, {carry, last})
        end
    end
    passages = {}
    for _, piece in ipairs(merged) do
        heading = nil
        for _, h in ipairs(headings) do
            if h <= piece[1] then
                heading = line_at(content, h)
            end
        end
        table.insert(passages, {text = string.sub(content, piece[1], piece[2]), offset = piece[1], heading = heading})
    end
    return passages
end

--------------------------------------------------------------------------
-- Scoring and selection
--------------------------------------------------------------------------

-- The share of the query's distinct terms a passage contains.
function term_share(text, terms)
    if #terms == 0 then
        return 0
    end
    lower = string.lower(text)
    found = 0
    for _, term in ipairs(terms) do
        if string.find(lower, term, 1, true) != nil then
            found = found + 1
        end
    end
    return found / #terms
end

function dot(a, b)
    if a == nil or b == nil or #a != #b then
        return 0
    end
    total = 0
    for i = 1, #a do
        total = total + a[i] * b[i]
    end
    return total
end

-- What a passage is embedded as: its text, led by its heading when the
-- passage doesn't already start with it (a section's later pieces), so
-- its meaning includes what it's about. The cache is keyed by this.
function embed_text(p)
    if p.heading != nil and string.sub(p.text, 1, string.len(p.heading)) != p.heading then
        return p.heading .. "\n" .. p.text
    end
    return p.text
end

-- Cuts text to at most `limit` characters at a word boundary.
function cut_to(text, limit)
    if string.len(text) <= limit then
        return text
    end
    cut = string.sub(text, 1, limit)
    trimmed = string.match(cut, "^(.*)%s%S*$")
    if trimmed != nil and string.len(trimmed) > limit - 40 then
        cut = trimmed
    end
    return cut .. " ..."
end

-- Formats the chosen passages, in document order, each marked with the
-- character it starts at (so the reader can go on from there with
-- entity.get field=content offset=...).
function format_passages(chosen)
    table.sort(chosen, function(a, b) return a.offset < b.offset end)
    parts = {}
    for _, p in ipairs(chosen) do
        lead = string.format("[at character %d", p.offset - 1)
        if p.heading != nil and string.sub(p.text, 1, string.len(p.heading)) != p.heading then
            lead = lead .. ", under " .. p.heading
        end
        table.insert(parts, lead .. "]\n" .. p.shown)
    end
    return table.concat(parts, "\n\n")
end

-- passage.select(passages, scores, budget, per_document) -> chosen
-- The best-scoring passages, at most per_document of them, while their
-- total length fits the budget; the best one is cut to the budget if it
-- alone is longer. Pure, so it's unit-tested on its own.
function passage.select(passages, scores, budget, per_document)
    order = {}
    for i = 1, #passages do
        table.insert(order, i)
    end
    table.sort(order, function(a, b)
        if scores[a] == scores[b] then
            return passages[a].offset < passages[b].offset
        end
        return scores[a] > scores[b]
    end)
    chosen = {}
    used = 0
    for _, i in ipairs(order) do
        if #chosen >= per_document then
            break
        end
        p = passages[i]
        if #chosen == 0 then
            shown = cut_to(p.text, budget)
            table.insert(chosen, {offset = p.offset, heading = p.heading, text = p.text, shown = shown})
            used = string.len(shown)
        elseif used + string.len(p.text) <= budget then
            table.insert(chosen, {offset = p.offset, heading = p.heading, text = p.text, shown = p.text})
            used = used + string.len(p.text)
        end
    end
    return chosen
end
passage.format_passages = format_passages

-- passage.excerpts(db_path, results, query_text, query_vector, model, budget, full)
--   -> {[document id] = excerpt}
-- The excerpt search shows for each result: its best passages by
-- meaning (cosine with the query's embedding) plus a little by words
-- (passage_lexical_weight), within `budget` characters. A document
-- that fits the budget whole is shown whole. A document left out of the
-- map (no query embedding, a provider failure) falls back to the
-- caller's keyword window -- passage scoring never makes search worse.
-- All results share one cache lookup and one batched embedding call,
-- capped at passage_max_embeds_per_search new embeddings; passages over
-- the cap are scored by words only.
function passage.excerpts(db_path, results, query_text, query_vector, model, budget, full)
    conf = config.platform_config()
    per_document = conf.passages_per_document
    if full == true then
        per_document = per_document * 2
    end
    excerpts = {}
    if query_vector == nil or model == nil then
        return excerpts
    end
    query_packed = document.pack_vector(query_vector)
    if query_packed == nil then
        return excerpts
    end
    query_unit = document.unpack_vector(query_packed)
    terms = document.query_terms(query_text)

    -- Split every result; documents that fit whole need nothing more.
    work = {}
    hashes = {}
    seen = {}
    for _, r in ipairs(results) do
        content = r.content
        if content != nil and content != "" then
            body_start = document.preamble_end(content)
            if string.len(content) - body_start + 1 <= budget then
                excerpts[tonumber(r.id)] = string.sub(content, body_start)
            else
                ps = passage.split(content, conf.passage_max_chars, conf.passage_min_chars)
                for _, p in ipairs(ps) do
                    p.embed = embed_text(p)
                    p.hash = passage.text_hash(p.embed)
                    if seen[p.hash] == nil then
                        seen[p.hash] = true
                        table.insert(hashes, p.hash)
                    end
                end
                table.insert(work, {id = tonumber(r.id), passages = ps})
            end
        end
    end
    if #work == 0 then
        return excerpts
    end

    vectors = passage.cache_get(db_path, model, hashes)
    missing = {}
    missing_text = {}
    for _, item in ipairs(work) do
        for _, p in ipairs(item.passages) do
            if vectors[p.hash] == nil and missing_text[p.hash] == nil and #missing < conf.passage_max_embeds_per_search then
                missing_text[p.hash] = p.embed
                table.insert(missing, p.hash)
            end
        end
    end
    if #missing > 0 then
        agent_provider = require("agent_provider")
        texts = {}
        for _, h in ipairs(missing) do
            table.insert(texts, missing_text[h])
        end
        new_vectors, err = agent_provider.embeddings_batch(model, texts)
        if new_vectors == nil then
            io.write(io.stderr, "passage embeddings failed, using keyword excerpts: " .. tostring(err) .. "\n")
            return excerpts
        end
        entries = {}
        for i, h in ipairs(missing) do
            table.insert(entries, {h, new_vectors[i]})
        end
        for h, v in pairs(passage.cache_put(db_path, model, entries)) do
            vectors[h] = v
        end
    end

    for _, item in ipairs(work) do
        scores = {}
        for i, p in ipairs(item.passages) do
            scores[i] = dot(query_unit, vectors[p.hash]) + conf.passage_lexical_weight * term_share(p.text, terms)
        end
        chosen = passage.select(item.passages, scores, budget, per_document)
        if #chosen > 0 then
            excerpts[item.id] = format_passages(chosen)
        end
    end
    return excerpts
end

return passage
