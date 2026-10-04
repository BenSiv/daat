-- Tag upkeep in core (doc/tag-ontology.md, "The data decides the shape"):
-- each tag keeps a running centre -- its member count and the sum of its
-- members' vectors -- so a new or edited document can join its nearest
-- tag on save, without a batch job.
--
-- Vectors are the documents' cached embeddings (document_embedding),
-- cut to `tag_dims` and scaled to unit length, so a score is a cosine.
-- A centre counts every membership that isn't `excluded` (a `pinned` one
-- included: a person's assertion is a member like any other), whoever
-- wrote it -- this module's placement, a person, or an outside job
-- through the API -- because the membership hooks below keep tag_centre
-- in step with document_tag rather than placement updating it itself.
--
-- tag_centre is a derived index, like document_embedding: rebuilt from
-- document_tag + document_embedding by `daat repair tags`, the recovery
-- for anything that changes a vector without a hook (`daat repair
-- embeddings`, a raw SQL write) or two concurrent saves racing on one
-- centre's sum.
--
-- Evidence between tags (tag_evidence, "Evidence between tags" in the
-- doc): core's own kinds, `link` and `connection`, are recomputed from
-- document_link and document_tag when read and their inputs changed, not
-- on every write -- one outside job's apply writes thousands of
-- memberships, and nothing reads evidence until judgment or display.

db = require("database")
entity = require("entity")
config = require("config")
json = require("dkjson")

tag = {}

TAG_CENTRE_SCHEMA = """
CREATE TABLE IF NOT EXISTS tag_centre (
    tag_id INTEGER PRIMARY KEY,
    members INTEGER NOT NULL DEFAULT 0,
    sum_json TEXT NOT NULL,
    updated_at TEXT DEFAULT (%s)
);
"""

-- The fingerprint of core evidence's inputs when it was last computed.
TAG_EVIDENCE_STATE_SCHEMA = """
CREATE TABLE IF NOT EXISTS tag_evidence_state (
    id INTEGER PRIMARY KEY,
    fingerprint TEXT NOT NULL
);
"""

ACTIVE = "(archived_at IS NULL OR archived_at = '')"

-- Evidence a pair rests on before its lift counts, and how far lift is
-- pulled towards 1: PRIOR median-weights added to both sides.
TAG_EVIDENCE_MIN_SUPPORT = 3
TAG_EVIDENCE_PRIOR = 2.0

function tag.init_schema(db_path)
    db.exec(db_path, string.format(TAG_CENTRE_SCHEMA, db.now_expr(db_path)))
    db.exec(db_path, TAG_EVIDENCE_STATE_SCHEMA)
end

function tag_unit(v, dims)
    n = #v
    if dims != nil and dims < n then
        n = dims
    end
    out = {}
    norm = 0.0
    for i = 1, n do
        out[i] = v[i]
        norm = norm + v[i] * v[i]
    end
    if norm == 0.0 then
        return nil
    end
    norm = math.sqrt(norm)
    for i = 1, n do
        out[i] = out[i] / norm
    end
    return out
end

function tag_dot(a, b)
    s = 0.0
    for i = 1, #a do
        s = s + a[i] * b[i]
    end
    return s
end

-- The document's tagging vector, or nil when it has no embedding yet.
function tag.document_vector(db_path, document_id)
    rows = db.query(db_path, string.format(
        "SELECT vector_json FROM document_embedding WHERE document_id = %d;", tonumber(document_id)))
    if rows == nil or #rows == 0 then
        return nil
    end
    full, _, _ = json.decode(rows[1].vector_json)
    if type(full) != "table" then
        return nil
    end
    return tag_unit(full, config.platform_config().tag_dims)
end

function tag_load_centre(db_path, tag_id)
    rows = db.query(db_path, string.format(
        "SELECT members, sum_json FROM tag_centre WHERE tag_id = %d;", tonumber(tag_id)))
    if rows == nil or #rows == 0 then
        return 0, nil
    end
    sum, _, _ = json.decode(rows[1].sum_json)
    return tonumber(rows[1].members), sum
end

function tag_save_centre(db_path, tag_id, members, sum)
    if members <= 0 or sum == nil then
        db.exec(db_path, string.format("DELETE FROM tag_centre WHERE tag_id = %d;", tonumber(tag_id)))
        return
    end
    db.exec(db_path, string.format(
        "%s tag_centre (tag_id, members, sum_json, updated_at) VALUES (%d, %d, %s, %s);",
        db.replace_into(db_path), tonumber(tag_id), members, db.quote(json.encode(sum)), db.now_expr(db_path)))
end

-- Adds `add` to a tag's centre and takes `remove` out of it, either may
-- be nil; both at once replaces a member's old vector with its new one.
-- A vector of the wrong length (tag_dims changed since the centre was
-- built) is skipped; `daat repair tags` rebuilds at the new length.
function tag.adjust_centre(db_path, tag_id, add, remove)
    if add == nil and remove == nil then
        return
    end
    members, sum = tag_load_centre(db_path, tag_id)
    length = 0
    if add != nil then
        length = #add
    else
        length = #remove
    end
    if sum == nil then
        sum = {}
        for i = 1, length do
            sum[i] = 0.0
        end
    end
    if #sum != length then
        return
    end
    if add != nil then
        for i = 1, length do
            sum[i] = sum[i] + add[i]
        end
        members = members + 1
    end
    if remove != nil and #remove == length then
        for i = 1, length do
            sum[i] = sum[i] - remove[i]
        end
        members = members - 1
    end
    tag_save_centre(db_path, tag_id, members, sum)
end

-- Every active tag's centre, unit length: {{id=, centre=}, ...}.
function tag.active_centres(db_path)
    rows = db.query(db_path, """
        SELECT c.tag_id, c.sum_json FROM tag_centre c JOIN tag t ON t.id = c.tag_id
        WHERE c.members > 0 AND (t.archived_at IS NULL OR t.archived_at = '');""")
    centres = {}
    if rows == nil then
        return centres
    end
    for _, row in ipairs(rows) do
        sum, _, _ = json.decode(row.sum_json)
        if type(sum) == "table" then
            centre = tag_unit(sum, nil)
            if centre != nil then
                table.insert(centres, {id = tonumber(row.tag_id), centre = centre})
            end
        end
    end
    return centres
end

function tag_memberships(db_path, document_id)
    rows = db.query(db_path, string.format(
        "SELECT id, tag, decision FROM document_tag WHERE document = %d AND %s;", tonumber(document_id), ACTIVE))
    if rows == nil then
        return {}
    end
    return rows
end

--------------------------------------------------------------------------
-- Membership hooks: tag_centre follows document_tag, whoever writes it.
--------------------------------------------------------------------------

function tag.on_membership_created(db_path, membership_id)
    row = entity.get(db_path, "document_tag", membership_id)
    if row == nil or row.decision == "excluded" then
        return
    end
    tag.adjust_centre(db_path, row.tag, tag.document_vector(db_path, row.document), nil)
end

function tag.on_membership_updated(db_path, membership_id, field_changes)
    if field_changes.decision == nil and field_changes.tag == nil and field_changes.document == nil then
        return
    end
    row = entity.get(db_path, "document_tag", membership_id)
    if row == nil then
        return
    end
    old_decision, old_tag, old_document = row.decision, row.tag, row.document
    if field_changes.decision != nil then
        old_decision = field_changes.decision.old
    end
    if field_changes.tag != nil then
        old_tag = field_changes.tag.old
    end
    if field_changes.document != nil then
        old_document = field_changes.document.old
    end
    if old_decision != "excluded" and old_tag != nil and old_document != nil then
        tag.adjust_centre(db_path, old_tag, nil, tag.document_vector(db_path, old_document))
    end
    if row.decision != "excluded" then
        tag.adjust_centre(db_path, row.tag, tag.document_vector(db_path, row.document), nil)
    end
end

function tag.on_membership_archived(db_path, membership_id, archived)
    row = entity.get(db_path, "document_tag", membership_id)
    if row == nil or row.decision == "excluded" then
        return
    end
    vector = tag.document_vector(db_path, row.document)
    if archived then
        tag.adjust_centre(db_path, row.tag, nil, vector)
    else
        tag.adjust_centre(db_path, row.tag, vector, nil)
    end
end

--------------------------------------------------------------------------
-- Document hooks
--------------------------------------------------------------------------

-- A document's vector changed (old may be nil: it wasn't counted yet):
-- swap it in every tag it belongs to.
function tag.on_document_vector_changed(db_path, document_id, old)
    new = tag.document_vector(db_path, document_id)
    if new == nil then
        return
    end
    for _, row in ipairs(tag_memberships(db_path, document_id)) do
        if row.decision != "excluded" then
            tag.adjust_centre(db_path, row.tag, new, old)
        end
    end
end

-- An archived document leaves its tags' centres; unarchived, it returns.
function tag.on_document_archived(db_path, document_id, archived)
    rows = tag_memberships(db_path, document_id)
    if #rows == 0 then
        return
    end
    vector = tag.document_vector(db_path, document_id)
    if vector == nil then
        return
    end
    for _, row in ipairs(rows) do
        if row.decision != "excluded" then
            if archived then
                tag.adjust_centre(db_path, row.tag, nil, vector)
            else
                tag.adjust_centre(db_path, row.tag, vector, nil)
            end
        end
    end
end

-- Join the nearest tag: the best-scoring active centre, plus the second
-- best when it's within `tag_second_within` of the best. Only `computed`
-- memberships are this function's to change: a `pinned` tag stays and
-- isn't duplicated, an `excluded` one is never chosen. Returns the
-- chosen tag ids (empty when there are no tags or no vector yet).
function tag.place_document(db_path, document_id)
    chosen = {}
    vector = tag.document_vector(db_path, document_id)
    if vector == nil then
        return chosen
    end
    centres = tag.active_centres(db_path)
    if #centres == 0 then
        return chosen
    end
    excluded, pinned, computed = {}, {}, {}
    for _, row in ipairs(tag_memberships(db_path, document_id)) do
        tag_id = tonumber(row.tag)
        if row.decision == "excluded" then
            excluded[tag_id] = true
        elseif row.decision == "pinned" then
            pinned[tag_id] = true
        else
            computed[tag_id] = tonumber(row.id)
        end
    end
    best, best_score, second, second_score = nil, -2.0, nil, -2.0
    for _, c in ipairs(centres) do
        if excluded[c.id] == nil and #c.centre == #vector then
            score = tag_dot(vector, c.centre)
            if score > best_score then
                second, second_score = best, best_score
                best, best_score = c.id, score
            elseif score > second_score then
                second, second_score = c.id, score
            end
        end
    end
    if best == nil then
        return chosen
    end
    wanted = {}
    wanted[best] = best_score
    within = config.platform_config().tag_second_within
    if second != nil and within != nil and best_score - second_score < within then
        wanted[second] = second_score
    end
    for tag_id, membership_id in pairs(computed) do
        if wanted[tag_id] == nil then
            archived_id, _ = entity.archive(db_path, "document_tag", membership_id, "system", nil, "tag upkeep: a nearer tag")
            if archived_id != nil then
                tag.on_membership_archived(db_path, membership_id, true)
            end
        end
    end
    for tag_id, score in pairs(wanted) do
        table.insert(chosen, tag_id)
        if computed[tag_id] == nil and pinned[tag_id] == nil then
            entity.create(db_path, "document_tag", {
                document = tostring(document_id), tag = tostring(tag_id),
                score = string.format("%.4f", score), decision = "computed",
            }, "system")
        end
    end
    return chosen
end

-- `daat repair tags`: every centre recomputed from active memberships.
function tag.rebuild_centres(db_path)
    db.exec(db_path, "DELETE FROM tag_centre;")
    rows = db.query(db_path, """
        SELECT dt.document, dt.tag FROM document_tag dt JOIN document d ON d.id = dt.document
        WHERE (dt.archived_at IS NULL OR dt.archived_at = '') AND dt.decision != 'excluded'
          AND (d.archived_at IS NULL OR d.archived_at = '');""")
    if rows == nil then
        rows = {}
    end
    vectors, missing, sums, counts = {}, {}, {}, {}
    members = 0
    for _, row in ipairs(rows) do
        doc_id = tonumber(row.document)
        if vectors[doc_id] == nil and missing[doc_id] == nil then
            vectors[doc_id] = tag.document_vector(db_path, doc_id)
            if vectors[doc_id] == nil then
                missing[doc_id] = true
            end
        end
        vector = vectors[doc_id]
        if vector != nil then
            tag_id = tonumber(row.tag)
            if sums[tag_id] == nil then
                sums[tag_id], counts[tag_id] = {}, 0
                for i = 1, #vector do
                    sums[tag_id][i] = 0.0
                end
            end
            if #sums[tag_id] == #vector then
                for i = 1, #vector do
                    sums[tag_id][i] = sums[tag_id][i] + vector[i]
                end
                counts[tag_id] = counts[tag_id] + 1
                members = members + 1
            end
        end
    end
    tags = 0
    for tag_id, sum in pairs(sums) do
        tag_save_centre(db_path, tag_id, counts[tag_id], sum)
        tags = tags + 1
    end
    return tags, members
end

--------------------------------------------------------------------------
-- Evidence between tags
--------------------------------------------------------------------------

function tag_evidence_fingerprint(db_path)
    rows = db.query(db_path, string.format("""
        SELECT (SELECT COUNT(*) FROM document_link WHERE to_document_id IS NOT NULL AND %s) AS links,
               (SELECT COALESCE(MAX(id), 0) FROM document_link) AS last_link,
               (SELECT COUNT(*) FROM document_tag WHERE %s) AS memberships,
               (SELECT COALESCE(MAX(last_event_id), 0) FROM document_tag) AS last_membership,
               (SELECT COUNT(*) FROM document WHERE %s) AS documents;""", ACTIVE, ACTIVE, ACTIVE))
    r = rows[1]
    return string.format("%s/%s/%s/%s/%s", tostring(r.links), tostring(r.last_link),
        tostring(r.memberships), tostring(r.last_membership), tostring(r.documents))
end

-- Each active document's tags (excluded ones aren't memberships).
function tag_document_tags(db_path)
    rows = db.query(db_path, """
        SELECT dt.document, dt.tag FROM document_tag dt JOIN document d ON d.id = dt.document
        WHERE (dt.archived_at IS NULL OR dt.archived_at = '') AND dt.decision != 'excluded'
          AND (d.archived_at IS NULL OR d.archived_at = '');""")
    tags_of = {}
    if rows == nil then
        return tags_of
    end
    for _, row in ipairs(rows) do
        doc_id = tonumber(row.document)
        if tags_of[doc_id] == nil then
            tags_of[doc_id] = {}
        end
        table.insert(tags_of[doc_id], tonumber(row.tag))
    end
    return tags_of
end

-- Adds one edge's unit to every tag pair it touches, shared evenly: a
-- document in two tags gives each half, so being in more tags never
-- makes an edge count more.
function tag_spread_edge(totals, from_tags, to_tags, ordered)
    share = 1.0 / (#from_tags * #to_tags)
    for _, a in ipairs(from_tags) do
        for _, b in ipairs(to_tags) do
            x, y = a, b
            if ordered == false and y < x then
                x, y = b, a
            end
            key = tostring(x) .. ":" .. tostring(y)
            if totals[key] == nil then
                totals[key] = {tag_a = x, tag_b = y, weight = 0.0, support = 0}
            end
            totals[key].weight = totals[key].weight + share
            totals[key].support = totals[key].support + 1
        end
    end
end

-- Core's evidence, computed: {link = {key -> total}, connection = {...}}.
-- link: a [[link]] between two tagged documents, directed. connection:
-- a connection document (document.is_connection_title, linking exactly
-- two documents) is one undirected edge between the two; it's an edge,
-- so its own links aren't counted as links.
function tag_core_evidence(db_path)
    document = require("document")
    tags_of = tag_document_tags(db_path)
    rows = db.query(db_path, """
        SELECT l.from_document_id, l.to_document_id, f.title AS from_title
        FROM document_link l
        JOIN document f ON f.id = l.from_document_id AND (f.archived_at IS NULL OR f.archived_at = '')
        JOIN document t ON t.id = l.to_document_id AND (t.archived_at IS NULL OR t.archived_at = '')
        WHERE l.to_document_id IS NOT NULL AND (l.archived_at IS NULL OR l.archived_at = '');""")
    links, connections, ends = {}, {}, {}
    if rows == nil then
        rows = {}
    end
    for _, row in ipairs(rows) do
        from_id, to_id = tonumber(row.from_document_id), tonumber(row.to_document_id)
        if document.is_connection_title(row.from_title) then
            if ends[from_id] == nil then
                ends[from_id] = {}
            end
            ends[from_id][to_id] = true
        elseif from_id != to_id and tags_of[from_id] != nil and tags_of[to_id] != nil then
            tag_spread_edge(links, tags_of[from_id], tags_of[to_id], true)
        end
    end
    for _, targets in pairs(ends) do
        pair = {}
        for doc_id, _ in pairs(targets) do
            table.insert(pair, doc_id)
        end
        if #pair == 2 and tags_of[pair[1]] != nil and tags_of[pair[2]] != nil then
            tag_spread_edge(connections, tags_of[pair[1]], tags_of[pair[2]], false)
        end
    end
    return {link = links, connection = connections}
end

TAG_CORE_DIRECTION = {link = "directed", connection = "undirected"}

function tag_round(x)
    return string.format("%.4f", x)
end

-- Brings core's tag_evidence rows in line with what its inputs say now:
-- creates new pairs, updates changed ones, archives pairs that are gone.
-- Returns the number of rows written.
function tag.refresh_evidence(db_path)
    computed = tag_core_evidence(db_path)
    existing = db.query(db_path, string.format(
        "SELECT id, tag_a, tag_b, kind, weight, support FROM tag_evidence WHERE producer = 'core' AND %s;", ACTIVE))
    if existing == nil then
        existing = {}
    end
    seen = {}
    written = 0
    for _, row in ipairs(existing) do
        key = tostring(tonumber(row.tag_a)) .. ":" .. tostring(tonumber(row.tag_b))
        total = nil
        if computed[row.kind] != nil then
            total = computed[row.kind][key]
        end
        if total == nil or seen[row.kind .. "/" .. key] != nil then
            entity.archive(db_path, "tag_evidence", tonumber(row.id), "system", nil, "tag evidence: pair no longer linked")
            written = written + 1
        else
            seen[row.kind .. "/" .. key] = true
            if tag_round(tonumber(row.weight)) != tag_round(total.weight) or tonumber(row.support) != total.support then
                entity.update(db_path, "tag_evidence", tonumber(row.id),
                    {weight = tag_round(total.weight), support = tostring(total.support)}, "system")
                written = written + 1
            end
        end
    end
    for kind, totals in pairs(computed) do
        for key, total in pairs(totals) do
            if seen[kind .. "/" .. key] == nil then
                entity.create(db_path, "tag_evidence", {
                    tag_a = tostring(total.tag_a), tag_b = tostring(total.tag_b), kind = kind,
                    direction = TAG_CORE_DIRECTION[kind], weight = tag_round(total.weight),
                    support = tostring(total.support), producer = "core",
                }, "system")
                written = written + 1
            end
        end
    end
    db.exec(db_path, string.format("%s tag_evidence_state (id, fingerprint) VALUES (1, %s);",
        db.replace_into(db_path), db.quote(tag_evidence_fingerprint(db_path))))
    return written
end

function tag_median(values)
    sorted = {}
    for _, v in ipairs(values) do
        if v > 0 then
            table.insert(sorted, v)
        end
    end
    if #sorted == 0 then
        return 1.0
    end
    table.sort(sorted)
    return sorted[math.floor(#sorted / 2) + 1]
end

-- Lift for every evidence row, by its own (kind, producer) group only:
-- observed weight against what the tags' totals in that group predict
-- (directed: out(a) * in(b) / m; undirected: k(a) * k(b) / 2m, k(a)^2 / 4m
-- inside one tag), both sides plus PRIOR median weights so a pair on a
-- couple of edges stays near 1. Rows under min_support get no lift.
-- Pure: takes and returns plain tables, so it's testable without a store.
function tag.lifts(rows, min_support)
    groups = {}
    for _, row in ipairs(rows) do
        key = row.kind .. "/" .. row.producer
        if groups[key] == nil then
            groups[key] = {}
        end
        table.insert(groups[key], row)
    end
    out = {}
    for _, group in pairs(groups) do
        out_w, in_w, k, weights = {}, {}, {}, {}
        m = 0.0
        for _, row in ipairs(group) do
            a, b, w = row.tag_a, row.tag_b, row.weight
            table.insert(weights, w)
            m = m + w
            for _, t in ipairs({out_w, in_w, k}) do
                if t[a] == nil then
                    t[a] = 0.0
                end
                if t[b] == nil then
                    t[b] = 0.0
                end
            end
            out_w[a] = out_w[a] + w
            in_w[b] = in_w[b] + w
            k[a] = k[a] + w
            k[b] = k[b] + w
        end
        prior = TAG_EVIDENCE_PRIOR * tag_median(weights)
        for _, row in ipairs(group) do
            if row.support >= min_support and m > 0 then
                a, b = row.tag_a, row.tag_b
                expected = 0.0
                if row.direction == "directed" then
                    expected = out_w[a] * in_w[b] / m
                elseif a == b then
                    expected = k[a] * k[a] / (4 * m)
                else
                    expected = k[a] * k[b] / (2 * m)
                end
                table.insert(out, {tag_a = a, tag_b = b, kind = row.kind, producer = row.producer,
                    direction = row.direction, weight = row.weight, support = row.support,
                    lift = (row.weight + prior) / (expected + prior)})
            end
        end
    end
    return out
end

-- Every active evidence row with its lift, core's own rows refreshed
-- first if their inputs changed since they were computed.
function tag.evidence(db_path)
    state = db.query(db_path, "SELECT fingerprint FROM tag_evidence_state WHERE id = 1;")
    if state == nil or #state == 0 or state[1].fingerprint != tag_evidence_fingerprint(db_path) then
        tag.refresh_evidence(db_path)
    end
    rows = db.query(db_path, string.format(
        "SELECT tag_a, tag_b, kind, direction, weight, support, producer FROM tag_evidence WHERE %s;", ACTIVE))
    if rows == nil then
        rows = {}
    end
    plain = {}
    for _, row in ipairs(rows) do
        support = tonumber(row.support)
        if support == nil then
            support = 0
        end
        table.insert(plain, {tag_a = tonumber(row.tag_a), tag_b = tonumber(row.tag_b), kind = row.kind,
            direction = row.direction, weight = tonumber(row.weight), support = support,
            producer = row.producer})
    end
    return tag.lifts(plain, TAG_EVIDENCE_MIN_SUPPORT)
end

return tag
