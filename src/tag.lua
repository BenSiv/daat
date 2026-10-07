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
-- doc): core's own kinds -- `link`, `connection`, `shared_link` and
-- `reference:<entity type>` -- are recomputed from document_link,
-- document_reference and document_tag when read and their inputs
-- changed, not on every write -- one outside job's apply writes thousands of
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

-- For tag_upkeep.lua, which works on the same vectors.
tag.unit = tag_unit
tag.dot = tag_dot

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
               (SELECT COUNT(*) FROM document WHERE %s) AS documents,
               (SELECT COUNT(*) FROM document_reference) AS refs,
               (SELECT COALESCE(SUM(entity_id), 0) FROM document_reference) AS ref_sum;""", ACTIVE, ACTIVE, ACTIVE))
    r = rows[1]
    return string.format("%s/%s/%s/%s/%s/%s/%s", tostring(r.links), tostring(r.last_link),
        tostring(r.memberships), tostring(r.last_membership), tostring(r.documents),
        tostring(r.refs), tostring(r.ref_sum))
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

-- Documents pointing at the same target -- an entity they reference, a
-- page they both link -- as evidence between their tags: `targets` maps
-- each target to {tag -> {document -> true}}. One unit per target,
-- shared across the tag pairs it touches (inside one tag included), so
-- a target named everywhere weighs almost nothing. A pair seen from
-- fewer than two documents on either side gets support 0 -- one
-- inventory sheet naming nine experiments shouldn't tie two tags -- but
-- its weight still counts towards the totals lift is measured against.
function tag_shared_targets(targets)
    totals = {}
    for _, by_tag in pairs(targets) do
        ts = {}
        for t, _ in pairs(by_tag) do
            table.insert(ts, t)
        end
        table.sort(ts)
        share = 2.0 / (#ts * (#ts + 1))
        for i = 1, #ts do
            for j = i, #ts do
                key = tostring(ts[i]) .. ":" .. tostring(ts[j])
                if totals[key] == nil then
                    totals[key] = {tag_a = ts[i], tag_b = ts[j], weight = 0.0, support = 0, docs_a = {}, docs_b = {}}
                end
                entry = totals[key]
                entry.weight = entry.weight + share
                entry.support = entry.support + 1
                for d, _ in pairs(by_tag[ts[i]]) do
                    entry.docs_a[d] = true
                end
                for d, _ in pairs(by_tag[ts[j]]) do
                    entry.docs_b[d] = true
                end
            end
        end
    end
    for _, entry in pairs(totals) do
        if entry.tag_a != entry.tag_b then
            na, nb = 0, 0
            for _, _ in pairs(entry.docs_a) do
                na = na + 1
            end
            for _, _ in pairs(entry.docs_b) do
                nb = nb + 1
            end
            if na < 2 or nb < 2 then
                entry.support = 0
            end
        end
        entry.docs_a, entry.docs_b = nil, nil
    end
    return totals
end

function tag_add_target(targets, target, tag_ids, document_id)
    if targets[target] == nil then
        targets[target] = {}
    end
    for _, t in ipairs(tag_ids) do
        if targets[target][t] == nil then
            targets[target][t] = {}
        end
        targets[target][t][document_id] = true
    end
end

-- Core's evidence, computed: {link = {key -> total}, connection = {...},
-- shared_link = {...}, ["reference:<entity type>"] = {...}}.
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
    links, connections, ends, linked_pages = {}, {}, {}, {}
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
        elseif from_id != to_id and tags_of[from_id] != nil then
            tag_add_target(linked_pages, to_id, tags_of[from_id], from_id)
            if tags_of[to_id] != nil then
                tag_spread_edge(links, tags_of[from_id], tags_of[to_id], true)
            end
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
    computed = {link = links, connection = connections, shared_link = tag_shared_targets(linked_pages)}
    refs = db.query(db_path, """
        SELECT r.document_id, r.entity_type, r.entity_id FROM document_reference r
        JOIN document d ON d.id = r.document_id AND (d.archived_at IS NULL OR d.archived_at = '');""")
    if refs == nil then
        refs = {}
    end
    by_type = {}
    for _, row in ipairs(refs) do
        doc_id = tonumber(row.document_id)
        if tags_of[doc_id] != nil then
            if by_type[row.entity_type] == nil then
                by_type[row.entity_type] = {}
            end
            tag_add_target(by_type[row.entity_type], tonumber(row.entity_id), tags_of[doc_id], doc_id)
        end
    end
    for entity_type, targets in pairs(by_type) do
        computed["reference:" .. entity_type] = tag_shared_targets(targets)
    end
    return computed
end

-- Only a [[link]] has a direction; every other core kind is a shared
-- target or a connection, both undirected.
function tag_core_direction(kind)
    if kind == "link" then
        return "directed"
    end
    return "undirected"
end

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
                    direction = tag_core_direction(kind), weight = tag_round(total.weight),
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

--------------------------------------------------------------------------
-- #tag in text ("#tag in text" in the doc)
--------------------------------------------------------------------------

-- A tag's label as it's written in text: lowercase, every run of
-- anything but letters and digits one "-" ("Cocoa bean fermentation"
-- -> "cocoa-bean-fermentation").
function tag.slug(label)
    slug, _ = string.gsub(string.lower(tostring(label)), "[^%w]+", "-")
    slug, _ = string.gsub(slug, "^%-+", "")
    slug, _ = string.gsub(slug, "%-+$", "")
    return slug
end

-- The label a new tag gets from its slug: "cocoa-bean" -> "Cocoa bean".
function tag_label_from_slug(slug)
    label, _ = string.gsub(slug, "[%-_]+", " ")
    return string.upper(string.sub(label, 1, 1)) .. string.sub(label, 2)
end

-- Calls replace(slug, written) for each #tag in plain text (no code in
-- it) and splices in what it returns, or keeps the text when it returns
-- nil. A tag starts the text or follows whitespace or "(" -- so a URL's
-- page#section never counts -- begins with a letter (#123 doesn't), and
-- isn't followed by "/" (no #a/b paths) or by "!"/"?" (a spreadsheet's
-- #REF!, #NAME? in imported text). "[[...]]" is skipped whole: a link's
-- text is a title, not tags.
function tag_replace_in_text(text, replace)
    out = {}
    pos = 1
    n = string.len(text)
    while pos <= n do
        s, e, raw = string.find(text, "#([%a][%w_%-]*)", pos)
        l1 = string.find(text, "[[", pos, true)
        if l1 != nil and (s == nil or l1 < s) then
            l2 = string.find(text, "]]", l1 + 2, true)
            if l2 == nil then
                table.insert(out, string.sub(text, pos))
                pos = n + 1
            else
                table.insert(out, string.sub(text, pos, l2 + 1))
                pos = l2 + 2
            end
        elseif s == nil then
            table.insert(out, string.sub(text, pos))
            pos = n + 1
        else
            trimmed, _ = string.gsub(raw, "[%-_]+$", "")
            last = s + string.len(trimmed)
            before_ok = s == 1 or string.find(string.sub(text, s - 1, s - 1), "[%s%(]") != nil
            after = string.sub(text, e + 1, e + 1)
            if before_ok and after != "/" and after != "!" and after != "?" then
                table.insert(out, string.sub(text, pos, s - 1))
                written = string.sub(text, s, last)
                replacement = replace(string.lower(trimmed), written)
                if replacement == nil then
                    replacement = written
                end
                table.insert(out, replacement)
                pos = last + 1
            else
                table.insert(out, string.sub(text, pos, e))
                pos = e + 1
            end
        end
    end
    return table.concat(out)
end

-- tag_replace_in_text over a document's content, leaving code alone:
-- fenced blocks (``` or ~~~) and inline `code` spans pass through as is.
function tag_replace_outside_code(content, replace)
    lines = {}
    fence = false
    for line in string.gmatch(content .. "\n", "(.-)\n") do
        if string.find(line, "^%s*```") != nil or string.find(line, "^%s*~~~") != nil then
            fence = not fence
            table.insert(lines, line)
        elseif fence then
            table.insert(lines, line)
        else
            parts = {}
            pos = 1
            while true do
                s, e = string.find(line, "`[^`]*`", pos)
                if s == nil then
                    table.insert(parts, tag_replace_in_text(string.sub(line, pos), replace))
                    break
                end
                table.insert(parts, tag_replace_in_text(string.sub(line, pos, s - 1), replace))
                table.insert(parts, string.sub(line, s, e))
                pos = e + 1
            end
            table.insert(lines, table.concat(parts))
        end
    end
    return table.concat(lines, "\n")
end

-- The #tags in a document's content, as slugs, each once, in order.
function tag.text_tags(content)
    slugs, seen = {}, {}
    if content == nil then
        return slugs
    end
    tag_replace_outside_code(content, function(slug, written)
        if seen[slug] == nil then
            seen[slug] = true
            table.insert(slugs, slug)
        end
        return nil
    end)
    return slugs
end

function tag_slug_ids(db_path)
    ids = {}
    rows = db.query(db_path, string.format("SELECT id, label FROM tag WHERE %s ORDER BY id;", ACTIVE))
    if rows == nil then
        return ids
    end
    for _, row in ipairs(rows) do
        slug = tag.slug(row.label)
        if ids[slug] == nil then
            ids[slug] = tonumber(row.id)
        end
    end
    return ids
end

-- On save: each #tag the person wrote is a membership they asserted
-- (pinned, via text), created with the tag if it doesn't exist yet; one
-- that left the text is archived. While it's in the text it wins: a
-- computed membership becomes it, and so does an excluded one (a removal
-- elsewhere). A pinned membership set some other way is left as it is.
--
-- "Wrote" is exact: on an edit (`old_content` given), only #tags the
-- edit added are asserted -- text that was already there, an import's
-- say, isn't. And only a person's write counts at all: `author` "system"
-- or an API key's "api:<label>" (an import, a sync) is skipped, since
-- text a program copied in isn't anyone asserting a tag. Measured on
-- 6,865 imported documents, syncing their text would have made 172 tags
-- out of spreadsheet errors and catalogue numbers. A chat edit is the
-- chatting person's.
function tag.sync_text_tags(db_path, document_id, content, author, old_content)
    if author == nil or author == "system" or string.sub(tostring(author), 1, 4) == "api:" then
        return
    end
    already = {}
    if old_content != nil then
        for _, slug in ipairs(tag.text_tags(old_content)) do
            already[slug] = true
        end
    end
    rows = db.query(db_path, string.format(
        "SELECT id, tag, decision, via FROM document_tag WHERE document = %d AND %s;", tonumber(document_id), ACTIVE))
    if rows == nil then
        rows = {}
    end
    by_text = {}
    for _, row in ipairs(rows) do
        if row.via == "text" then
            by_text[tonumber(row.tag)] = true
        end
    end
    ids = tag_slug_ids(db_path)
    wanted = {}
    for _, slug in ipairs(tag.text_tags(content)) do
        if already[slug] == nil or (ids[slug] != nil and by_text[ids[slug]] != nil) then
            if ids[slug] == nil then
                ids[slug], _ = entity.create(db_path, "tag", {label = tag_label_from_slug(slug), source = "manual"}, "system")
            end
            if ids[slug] != nil then
                wanted[tonumber(ids[slug])] = true
            end
        end
    end
    have = {}
    for _, row in ipairs(rows) do
        tag_id = tonumber(row.tag)
        if row.via == "text" then
            if wanted[tag_id] == nil then
                archived_id, _ = entity.archive(db_path, "document_tag", tonumber(row.id), "system", nil, "#tag removed from the text")
                if archived_id != nil then
                    tag.on_membership_archived(db_path, tonumber(row.id), true)
                end
            else
                have[tag_id] = true
            end
        elseif wanted[tag_id] != nil and have[tag_id] == nil then
            if row.decision != "pinned" then
                entity.update(db_path, "document_tag", tonumber(row.id), {decision = "pinned", via = "text"}, "system")
            end
            have[tag_id] = true
        end
    end
    for tag_id, _ in pairs(wanted) do
        if have[tag_id] == nil then
            entity.create(db_path, "document_tag", {
                document = tostring(document_id), tag = tostring(tag_id), decision = "pinned", via = "text",
            }, "system")
        end
    end
end

-- For rendering: each #tag naming an existing tag becomes a link to the
-- tag's page, which document.render_html turns into a chip -- never a
-- [[link]], so it's never a document_link either.
function tag.inline_text_tags(db_path, content)
    ids = tag_slug_ids(db_path)
    return tag_replace_outside_code(content, function(slug, written)
        if ids[slug] == nil then
            return nil
        end
        return "[" .. written .. "](detail?type=tag&entity_id=" .. tostring(ids[slug]) .. ")"
    end)
end

return tag
