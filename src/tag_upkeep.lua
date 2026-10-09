-- Tag restructuring in core (doc/tag-ontology.md, phase 3b): the data
-- proposes, the agent decides. tag.lua keeps each tag's running centre
-- and places documents on save; this module watches the tags themselves:
--
--   split -- a tag whose spread grew past what it had when built (by
--            TAG_SPLIT_SPREAD) is cut in two by 2-means over its own
--            members; the agent says whether the halves are one subject
--            (SAME: nothing changes) or two (DIFFERENT: it names both,
--            keeping the current label where it still fits);
--   merge -- two tags whose centres came closer than any two were when
--            built; the agent says SAME (merged into the larger, named
--            for the whole) or DIFFERENT (kept apart);
--   fit   -- a tag that took in TAG_FIT_GROWTH more members since its
--            label was last judged; the agent says whether the label and
--            description still fit (FITS) or proposes new ones (RENAME).
--
-- Spread comes from the running summary alone: the sum of a tag's unit
-- vectors has length members * mean cosine to the centre, so spread =
-- 1 - |sum| / members. Thresholds are relative -- to the tag's own built
-- spread, to the closest pair at build -- never fixed cosines.
--
-- A person's choices win: a manual tag is never split, merged or
-- renamed; a pinned membership never moves; a verdict is remembered and
-- not asked again: a declined split accepts the tag's looseness as its
-- new baseline, a declined merge stands until the tags' members change
-- by TAG_REJUDGE_CHANGE.
-- Every change is an ordinary entity write by "system" (ledgered, the
-- centres kept by tag.lua's membership hooks); a merged-away tag is
-- archived, never deleted.
--
-- Runs after `daat document embed-pending` embeds anything, when
-- platform.lua's tag_restructure is on; `daat repair tags --restructure`
-- runs it by hand, with --dry-run (proposals only) and --judge (ask the
-- agent too, still writing nothing).

db = require("database")
entity = require("entity")
config = require("config")
json = require("dkjson")
tag = require("tag")
agent_provider = require("agent_provider")

tag_upkeep = {}

TAG_SPLIT_SPREAD = 1.15
TAG_REJUDGE_CHANGE = 0.10
TAG_FIT_GROWTH = 0.20
-- Agent calls per run, so one run's cost stays bounded; the rest wait
-- for the next run.
TAG_JUDGMENTS_PER_RUN = 5
-- A --pairs-above review asks about at most this many pairs.
TAG_REVIEW_PAIRS = 20
TAG_TWO_MEANS_ROUNDS = 10
TAG_PROMPT_TITLES = 8
TAG_PROMPT_EXCERPT = 200

-- Per tag: its spread when built (or last restructured) and its member
-- count when its label was last judged.
TAG_UPKEEP_SCHEMA = """
CREATE TABLE IF NOT EXISTS tag_upkeep (
    tag_id INTEGER PRIMARY KEY,
    built_spread REAL NOT NULL,
    fit_members INTEGER NOT NULL
);
"""

-- The pool's closest pair of centres when the tags were built.
TAG_UPKEEP_STATE_SCHEMA = """
CREATE TABLE IF NOT EXISTS tag_upkeep_state (
    id INTEGER PRIMARY KEY,
    merge_cosine REAL NOT NULL
);
"""

-- Every verdict, with the member counts it was given at -- the memory
-- that keeps a declined split or merge from being asked again.
TAG_JUDGMENT_SCHEMA = """
CREATE TABLE IF NOT EXISTS tag_judgment (
    id INTEGER PRIMARY KEY %s,
    kind VARCHAR(16) NOT NULL,
    tag_a INTEGER NOT NULL,
    tag_b INTEGER,
    members_a INTEGER NOT NULL,
    members_b INTEGER,
    verdict VARCHAR(16) NOT NULL,
    reason TEXT,
    judged_at TEXT DEFAULT (%s)
);
"""

SPLIT_PROMPT = """You review one tag in a lab's knowledge base. Its documents have drifted into two groups, A (the larger) and B; each is summarised by its most central titles.
Answer SAME if one tag still fits both groups -- the same subject -- or DIFFERENT if they are distinct subjects worth a tag each.
Reply on the first line with SAME or DIFFERENT, then " -- " and one short reason.
If DIFFERENT, add two lines naming the groups:
A: <label> | <one-sentence description>
B: <label> | <one-sentence description>
Keep the tag's current label for A if it still fits A. Labels are 2-5 words, specific (organism, method, material) rather than generic, no quotes."""

MERGE_PROMPT = """You compare two tags in a lab's knowledge base. Each is summarised by its label and its most central titles.
Answer SAME if they are about the same subject and would be clearer to a reader as one tag, or DIFFERENT if each is a distinct subject worth its own tag.
Reply on the first line with SAME or DIFFERENT, then " -- " and one short reason.
If SAME, add one line naming the merged tag (keep the first tag's label if it fits all of it):
NAME: <label> | <one-sentence description>
Labels are 2-5 words, specific (organism, method, material) rather than generic, no quotes."""

FIT_PROMPT = """You review one tag in a lab's knowledge base after it took in new documents. You get its label, its description, its most central titles and its newest titles.
Answer FITS if the label and description still describe all of them, or RENAME if they no longer do.
Reply on the first line with FITS or RENAME, then " -- " and one short reason.
If RENAME, add one line:
NAME: <label> | <one-sentence description>
Labels are 2-5 words, specific (organism, method, material) rather than generic, no quotes."""

ACTIVE_ROW = "(archived_at IS NULL OR archived_at = '')"

function tag_upkeep.init_schema(db_path)
    db.exec(db_path, TAG_UPKEEP_SCHEMA)
    db.exec(db_path, TAG_UPKEEP_STATE_SCHEMA)
    db.exec(db_path, string.format(TAG_JUDGMENT_SCHEMA, db.autoincrement_keyword(db_path), db.now_expr(db_path)))
end

function upkeep_norm(v)
    s = 0.0
    for i = 1, #v do
        s = s + v[i] * v[i]
    end
    return math.sqrt(s)
end

function upkeep_spread(members, sum)
    if members <= 0 then
        return 0.0
    end
    return 1.0 - upkeep_norm(sum) / members
end

-- Luam's and/or take booleans only, so no `rows or {}`: these stand in.
function upkeep_list(rows)
    if rows == nil then
        return {}
    end
    return rows
end

function upkeep_string(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

-- NULL comes back as nil or as an empty string depending on the backend.
function sql_text(value)
    if value == nil or value == "" or value == "NULL" then
        return nil
    end
    return value
end

function upkeep_save_baseline(db_path, tag_id, spread, fit_members)
    db.exec(db_path, string.format("%s tag_upkeep (tag_id, built_spread, fit_members) VALUES (%d, %.6f, %d);",
        db.replace_into(db_path), tonumber(tag_id), spread, fit_members))
end

function upkeep_save_merge_cosine(db_path, merge_cosine)
    db.exec(db_path, string.format("%s tag_upkeep_state (id, merge_cosine) VALUES (1, %.6f);",
        db.replace_into(db_path), merge_cosine))
end

-- The highest cosine between two centres (1.0 with fewer than two tags,
-- so nothing merges).
function upkeep_closest_pair(tags)
    best = -1.0
    for i = 1, #tags do
        for j = i + 1, #tags do
            if #tags[i].centre == #tags[j].centre then
                best = math.max(best, tag.dot(tags[i].centre, tags[j].centre))
            end
        end
    end
    if best < -0.5 then
        return 1.0
    end
    return best
end

-- Every active tag with a centre: {{id, label, description, source,
-- parent, members, sum, centre, spread}, ...}, by id.
function tag_upkeep.tags(db_path)
    rows = db.query(db_path, string.format("""
        SELECT c.tag_id, c.members, c.sum_json, t.label, t.description, t.source, t.parent
        FROM tag_centre c JOIN tag t ON t.id = c.tag_id
        WHERE (t.archived_at IS NULL OR t.archived_at = '') ORDER BY c.tag_id;"""))
    tags = {}
    if rows == nil then
        return tags
    end
    for _, row in ipairs(rows) do
        sum, _, _ = json.decode(row.sum_json)
        members = tonumber(row.members)
        if type(sum) == "table" and members > 0 then
            centre = tag.unit(sum, nil)
            if centre != nil then
                table.insert(tags, {
                    id = tonumber(row.tag_id), label = row.label, description = sql_text(row.description),
                    source = row.source, parent = sql_text(row.parent), members = members, sum = sum,
                    centre = centre, spread = upkeep_spread(members, sum),
                })
            end
        end
    end
    return tags
end

-- Baselines as stored, filled in from the current state for any tag
-- (or a pool) that has none yet -- written back unless `dry_run`.
function upkeep_baselines(db_path, tags, dry_run)
    stored = {}
    rows = db.query(db_path, "SELECT tag_id, built_spread, fit_members FROM tag_upkeep;")
    for _, row in ipairs(upkeep_list(rows)) do
        stored[tonumber(row.tag_id)] = {built_spread = tonumber(row.built_spread), fit_members = tonumber(row.fit_members)}
    end
    for _, t in ipairs(tags) do
        if stored[t.id] == nil then
            stored[t.id] = {built_spread = t.spread, fit_members = t.members}
            if not dry_run then
                upkeep_save_baseline(db_path, t.id, t.spread, t.members)
            end
        end
    end
    merge_cosine = nil
    state = db.query(db_path, "SELECT merge_cosine FROM tag_upkeep_state WHERE id = 1;")
    if state != nil and state[1] != nil then
        merge_cosine = tonumber(state[1].merge_cosine)
    else
        merge_cosine = upkeep_closest_pair(tags)
        if not dry_run then
            upkeep_save_merge_cosine(db_path, merge_cosine)
        end
    end
    return stored, merge_cosine
end

-- `daat repair tags` rebuilt the centres: what's there now is "built".
function tag_upkeep.record_baselines(db_path)
    tag_upkeep.init_schema(db_path)
    tags = tag_upkeep.tags(db_path)
    for _, t in ipairs(tags) do
        upkeep_save_baseline(db_path, t.id, t.spread, t.members)
    end
    upkeep_save_merge_cosine(db_path, upkeep_closest_pair(tags))
    return #tags
end

-- A tag's active, non-excluded memberships on active documents, each with
-- its tagging vector: {{membership, document, decision, vector}, ...}.
function upkeep_members(db_path, tag_id)
    rows = db.query(db_path, string.format("""
        SELECT dt.id, dt.document, dt.decision, e.vector_json FROM document_tag dt
        JOIN document d ON d.id = dt.document AND (d.archived_at IS NULL OR d.archived_at = '')
        LEFT JOIN document_embedding e ON e.document_id = dt.document
        WHERE dt.tag = %d AND (dt.archived_at IS NULL OR dt.archived_at = '') AND dt.decision != 'excluded'
        ORDER BY dt.id;""", tonumber(tag_id)))
    dims = config.platform_config().tag_dims
    members = {}
    for _, row in ipairs(upkeep_list(rows)) do
        vector = nil
        if sql_text(row.vector_json) != nil then
            full, _, _ = json.decode(row.vector_json)
            if type(full) == "table" then
                vector = tag.unit(full, dims)
            end
        end
        table.insert(members, {membership = tonumber(row.id), document = tonumber(row.document),
            decision = row.decision, vector = vector})
    end
    return members
end

function upkeep_mean(vectors)
    if #vectors == 0 then
        return nil
    end
    sum = {}
    for i = 1, #vectors[1] do
        sum[i] = 0.0
    end
    for _, v in ipairs(vectors) do
        for i = 1, #sum do
            sum[i] = sum[i] + v[i]
        end
    end
    return tag.unit(sum, nil)
end

-- 2-means over the members with a vector, seeded deterministically (the
-- member farthest from the centre, then the one farthest from it), so the
-- same tag always splits the same way. -> a, b (member lists, a the
-- larger), or nil when the members don't divide.
function upkeep_two_means(members, centre)
    placed = {}
    for _, m in ipairs(members) do
        if m.vector != nil and #m.vector == #centre then
            table.insert(placed, m)
        end
    end
    if #placed < 2 then
        return nil
    end
    seed_a, low = placed[1], 2.0
    for _, m in ipairs(placed) do
        score = tag.dot(m.vector, centre)
        if score < low then
            seed_a, low = m, score
        end
    end
    seed_b, low = nil, 2.0
    for _, m in ipairs(placed) do
        score = tag.dot(m.vector, seed_a.vector)
        if m != seed_a and score < low then
            seed_b, low = m, score
        end
    end
    ca, cb = seed_a.vector, seed_b.vector
    side = {}
    for round = 1, TAG_TWO_MEANS_ROUNDS do
        changed = false
        in_a, in_b = {}, {}
        for i, m in ipairs(placed) do
            to_a = tag.dot(m.vector, ca) >= tag.dot(m.vector, cb)
            if side[i] != to_a then
                changed = true
            end
            side[i] = to_a
            if to_a then
                table.insert(in_a, m.vector)
            else
                table.insert(in_b, m.vector)
            end
        end
        if #in_a == 0 or #in_b == 0 then
            return nil
        end
        ca, cb = upkeep_mean(in_a), upkeep_mean(in_b)
        if not changed then
            break
        end
    end
    a, b = {}, {}
    for i, m in ipairs(placed) do
        if side[i] then
            table.insert(a, m)
        else
            table.insert(b, m)
        end
    end
    if #b > #a then
        a, b = b, a
        ca, cb = cb, ca
    end
    return a, b, ca, cb
end

-- What the data proposes right now: splits first, then merges (closest
-- pair first, each tag in at most one proposal), then fit checks for
-- tags left untouched. Manual tags take no part. With `pairs_above` (a
-- review: tags built elsewhere can start closer than the build baseline
-- assumes), every pair above that cosine is proposed as a merge, and
-- nothing else.
function tag_upkeep.proposals(db_path, dry_run, pairs_above)
    tags = tag_upkeep.tags(db_path)
    baselines, merge_cosine = upkeep_baselines(db_path, tags, dry_run)
    review = pairs_above != nil
    if review then
        merge_cosine = pairs_above
    end
    split_min = config.platform_config().tag_split_min
    busy = {}
    proposals = {}
    for _, t in ipairs(tags) do
        base = baselines[t.id]
        if not review and t.source != "manual" and t.members >= split_min and t.spread > base.built_spread * TAG_SPLIT_SPREAD then
            table.insert(proposals, {kind = "split", a = t, built_spread = base.built_spread})
            busy[t.id] = true
        end
    end
    pairs_found = {}
    for i = 1, #tags do
        for j = i + 1, #tags do
            ta, tb = tags[i], tags[j]
            if ta.source != "manual" and tb.source != "manual" and #ta.centre == #tb.centre then
                cosine = tag.dot(ta.centre, tb.centre)
                if cosine > merge_cosine then
                    table.insert(pairs_found, {ta, tb, cosine})
                end
            end
        end
    end
    table.sort(pairs_found, function(x, y) return x[3] > y[3] end)
    for _, pair in ipairs(pairs_found) do
        ta, tb = pair[1], pair[2]
        if review or (busy[ta.id] == nil and busy[tb.id] == nil) then
            if tb.members > ta.members then
                ta, tb = tb, ta
            end
            table.insert(proposals, {kind = "merge", a = ta, b = tb, cosine = pair[3], merge_cosine = merge_cosine, review = review})
            busy[ta.id], busy[tb.id] = true, true
        end
    end
    for _, t in ipairs(tags) do
        base = baselines[t.id]
        if not review and busy[t.id] == nil and t.source != "manual" and t.members >= base.fit_members * (1 + TAG_FIT_GROWTH)
                and t.members > base.fit_members then
            table.insert(proposals, {kind = "fit", a = t, fit_members = base.fit_members})
        end
    end
    return proposals
end

-- A merge the agent declined (DIFFERENT) stands while both tags' member
-- counts are within TAG_REJUDGE_CHANGE of what it was judged at. (A
-- declined split moves the tag's built spread instead, and fit checks
-- are spaced by fit_members.)
function upkeep_standing_verdict(db_path, p)
    if p.kind != "merge" then
        return nil
    end
    other = "tag_b IS NULL"
    if p.b != nil then
        other = string.format("tag_b = %d", p.b.id)
    end
    rows = db.query(db_path, string.format(
        "SELECT verdict, members_a, members_b, reason FROM tag_judgment WHERE kind = %s AND tag_a = %d AND %s ORDER BY id DESC LIMIT 1;",
        db.quote(p.kind), p.a.id, other))
    if rows == nil or rows[1] == nil then
        return nil
    end
    row = rows[1]
    if row.verdict != "DIFFERENT" then
        return nil
    end
    function close(now, then_count)
        then_count = tonumber(then_count)
        return then_count != nil and math.abs(now - then_count) < then_count * TAG_REJUDGE_CHANGE
    end
    if not close(p.a.members, row.members_a) then
        return nil
    end
    if p.b != nil and not close(p.b.members, row.members_b) then
        return nil
    end
    return row
end

function upkeep_context()
    extra = config.load_theme().system_prompt_extra
    if extra == nil or extra == "" then
        return ""
    end
    return "Context about this knowledge base:\n" .. extra .. "\n\n"
end

-- Titles (and the start of each document) for a prompt: the members
-- closest to `centre` first, or the newest when `newest` is set.
function upkeep_titles(db_path, members, centre, newest)
    ranked = {}
    for _, m in ipairs(members) do
        if newest or (m.vector != nil and #m.vector == #centre) then
            table.insert(ranked, m)
        end
    end
    if newest then
        table.sort(ranked, function(x, y) return x.membership > y.membership end)
    else
        table.sort(ranked, function(x, y) return tag.dot(x.vector, centre) > tag.dot(y.vector, centre) end)
    end
    ids = {}
    for i = 1, math.min(TAG_PROMPT_TITLES, #ranked) do
        table.insert(ids, tostring(ranked[i].document))
    end
    if #ids == 0 then
        return "(none)"
    end
    rows = db.query(db_path, string.format(
        "SELECT id, title, SUBSTR(COALESCE(content, ''), 1, %d) AS excerpt FROM document WHERE id IN (%s);",
        TAG_PROMPT_EXCERPT, table.concat(ids, ", ")))
    by_id = {}
    for _, row in ipairs(upkeep_list(rows)) do
        by_id[tostring(row.id)] = row
    end
    lines = {}
    for _, id in ipairs(ids) do
        row = by_id[id]
        if row != nil then
            excerpt = string.gsub(upkeep_string(row.excerpt), "%s+", " ")
            table.insert(lines, "- " .. tostring(row.title) .. ": " .. excerpt)
        end
    end
    return table.concat(lines, "\n")
end

function upkeep_tag_header(t)
    header = "Label: " .. tostring(t.label) .. "\n"
    if t.description != nil then
        header = header .. "Description: " .. t.description .. "\n"
    end
    return header
end

-- The agent's answer: {verdict, reason, names = {A = {label, description}, ...}}.
function tag_upkeep.parse(answer, verdicts)
    lines = {}
    for line in string.gmatch(upkeep_string(answer), "[^\n]+") do
        line = string.gsub(line, "^%s+", "")
        if line != "" then
            table.insert(lines, line)
        end
    end
    parsed = {verdict = "UNPARSED", reason = string.sub(upkeep_string(answer), 1, 300), names = {}}
    if #lines == 0 then
        return parsed
    end
    first = string.upper(lines[1])
    for _, word in ipairs(verdicts) do
        if string.sub(first, 1, #word) == word then
            parsed.verdict = word
            reason = string.match(lines[1], "%-%-%s*(.*)$")
            if reason != nil then
                parsed.reason = string.sub(reason, 1, 300)
            end
        end
    end
    for i = 2, #lines do
        key, rest = string.match(lines[i], "^%**([%a]+)%**%s*:%s*(.+)$")
        if key != nil then
            label, description = string.match(rest, "^(.-)%s*|%s*(.*)$")
            if label == nil then
                label, description = rest, nil
            end
            label = string.gsub(label, "^[\"'%s]+", "")
            label = string.gsub(label, "[\"'%.%s]+$", "")
            if label != "" then
                if description == "" then
                    description = nil
                end
                parsed.names[string.upper(key)] = {label = string.sub(label, 1, 80), description = description}
            end
        end
    end
    return parsed
end

function upkeep_ask(db_path, p)
    if p.kind == "split" then
        members = upkeep_members(db_path, p.a.id)
        a, b, ca, cb = upkeep_two_means(members, p.a.centre)
        if a == nil then
            return nil, "the members don't divide in two"
        end
        p.part_a, p.part_b = a, b
        prompt = upkeep_tag_header(p.a) .. "\nGroup A (" .. #a .. " documents)\n" .. upkeep_titles(db_path, a, ca, false) ..
            "\n\nGroup B (" .. #b .. " documents)\n" .. upkeep_titles(db_path, b, cb, false)
        answer, err = agent_provider.generate(nil, upkeep_context() .. SPLIT_PROMPT, prompt)
        return answer, err, {"SAME", "DIFFERENT"}
    elseif p.kind == "merge" then
        ma, mb = upkeep_members(db_path, p.a.id), upkeep_members(db_path, p.b.id)
        prompt = "First tag (" .. p.a.members .. " documents)\n" .. upkeep_tag_header(p.a) .. upkeep_titles(db_path, ma, p.a.centre, false) ..
            "\n\nSecond tag (" .. p.b.members .. " documents)\n" .. upkeep_tag_header(p.b) .. upkeep_titles(db_path, mb, p.b.centre, false)
        answer, err = agent_provider.generate(nil, upkeep_context() .. MERGE_PROMPT, prompt)
        return answer, err, {"SAME", "DIFFERENT"}
    end
    members = upkeep_members(db_path, p.a.id)
    prompt = upkeep_tag_header(p.a) .. "\nMost central\n" .. upkeep_titles(db_path, members, p.a.centre, false) ..
        "\n\nNewest\n" .. upkeep_titles(db_path, members, p.a.centre, true)
    answer, err = agent_provider.generate(nil, upkeep_context() .. FIT_PROMPT, prompt)
    return answer, err, {"FITS", "RENAME"}
end

-- Another active tag already has this label (case-insensitive)?
function upkeep_label_taken(db_path, label, except)
    rows = db.query(db_path, string.format(
        "SELECT id FROM tag WHERE LOWER(label) = LOWER(%s) AND (archived_at IS NULL OR archived_at = '');", db.quote(label)))
    for _, row in ipairs(upkeep_list(rows)) do
        if except[tonumber(row.id)] == nil then
            return true
        end
    end
    return false
end

function upkeep_rename(db_path, t, name, reason)
    if name == nil then
        return
    end
    values = {}
    if name.label != t.label then
        values.label = name.label
    end
    if name.description != nil and name.description != t.description then
        values.description = name.description
    end
    if next(values) != nil then
        entity.update(db_path, "tag", t.id, values, "system", nil, reason)
    end
end

function upkeep_record(db_path, p, parsed)
    members_b = "NULL"
    tag_b = "NULL"
    if p.b != nil then
        tag_b, members_b = tostring(p.b.id), tostring(p.b.members)
    end
    db.exec(db_path, string.format(
        "INSERT INTO tag_judgment (kind, tag_a, tag_b, members_a, members_b, verdict, reason) VALUES (%s, %d, %s, %d, %s, %s, %s);",
        db.quote(p.kind), p.a.id, tag_b, p.a.members, members_b, db.quote(parsed.verdict), db.quote(parsed.reason)))
end

-- After a change, the tags' current spread and members are their new
-- "built" state.
function upkeep_rebaseline(db_path, ids)
    wanted = {}
    for _, id in ipairs(ids) do
        wanted[tonumber(id)] = true
    end
    for _, t in ipairs(tag_upkeep.tags(db_path)) do
        if wanted[t.id] == true then
            upkeep_save_baseline(db_path, t.id, t.spread, t.members)
        end
    end
end

-- A label judged against `members` documents: the next fit check waits
-- for TAG_FIT_GROWTH more. The tag's built spread is left alone.
function upkeep_save_fit(db_path, tag_id, members)
    db.exec(db_path, string.format("UPDATE tag_upkeep SET fit_members = %d WHERE tag_id = %d;", members, tonumber(tag_id)))
end

-- A split judged SAME: the tag's current looseness is accepted as its
-- own, so it's proposed again only if it loosens TAG_SPLIT_SPREAD more.
function upkeep_save_spread(db_path, tag_id, spread)
    db.exec(db_path, string.format("UPDATE tag_upkeep SET built_spread = %.6f WHERE tag_id = %d;", spread, tonumber(tag_id)))
end

-- Carries out a judged proposal. -> what was done, in words.
function upkeep_apply(db_path, p, parsed)
    if p.kind == "split" then
        if parsed.verdict != "DIFFERENT" then
            if parsed.verdict == "SAME" then
                -- One tag fits both halves: the label was judged too.
                upkeep_save_spread(db_path, p.a.id, p.a.spread)
                upkeep_save_fit(db_path, p.a.id, p.a.members)
            end
            return "kept as one tag"
        end
        name_a, name_b = parsed.names["A"], parsed.names["B"]
        if name_b == nil then
            return "not split: no name for the new tag"
        end
        if upkeep_label_taken(db_path, name_b.label, {}) or (name_a != nil and upkeep_label_taken(db_path, name_a.label, {[p.a.id] = true})) then
            return "not split: a proposed label is already another tag's"
        end
        values = {label = name_b.label, source = "computed", computed_at = os.date("!%Y-%m-%d %H:%M:%S")}
        if name_b.description != nil then
            values.description = name_b.description
        end
        if p.a.parent != nil then
            values.parent = p.a.parent
        end
        new_id, issues = entity.create(db_path, "tag", values, "system")
        if new_id == nil then
            return "not split: " .. json.encode(issues)
        end
        reason = "tag upkeep: split from #" .. p.a.id
        moved = 0
        for _, m in ipairs(p.part_b) do
            if m.decision == "computed" then
                entity.update(db_path, "document_tag", m.membership, {tag = tostring(new_id)}, "system", nil, reason)
                moved = moved + 1
            end
        end
        upkeep_rename(db_path, p.a, name_a, "tag upkeep: split")
        upkeep_rebaseline(db_path, {p.a.id, new_id})
        return string.format("split: %d documents moved to new tag #%d %q", moved, new_id, name_b.label)
    elseif p.kind == "merge" then
        if parsed.verdict != "SAME" then
            return "kept apart"
        end
        name = parsed.names["NAME"]
        if name != nil and upkeep_label_taken(db_path, name.label, {[p.a.id] = true, [p.b.id] = true}) then
            return "not merged: the proposed label is already another tag's"
        end
        members = upkeep_members(db_path, p.b.id)
        for _, m in ipairs(members) do
            if m.decision != "computed" then
                return "not merged: a person pinned a document to #" .. p.b.id
            end
        end
        on_keep = {}
        for _, m in ipairs(upkeep_members(db_path, p.a.id)) do
            on_keep[m.document] = true
        end
        reason = "tag upkeep: merged into #" .. p.a.id
        for _, m in ipairs(members) do
            if on_keep[m.document] == true then
                entity.archive(db_path, "document_tag", m.membership, "system", nil, reason)
                tag.on_membership_archived(db_path, m.membership, true)
            else
                entity.update(db_path, "document_tag", m.membership, {tag = tostring(p.a.id)}, "system", nil, reason)
            end
        end
        entity.archive(db_path, "tag", p.b.id, "system", nil, reason)
        db.exec(db_path, string.format("DELETE FROM tag_upkeep WHERE tag_id = %d;", p.b.id))
        upkeep_rename(db_path, p.a, name, "tag upkeep: merged")
        upkeep_rebaseline(db_path, {p.a.id})
        return string.format("merged #%d into #%d", p.b.id, p.a.id)
    end
    if parsed.verdict == "RENAME" then
        name = parsed.names["NAME"]
        if name == nil then
            return "not renamed: no name given"
        end
        if upkeep_label_taken(db_path, name.label, {[p.a.id] = true}) then
            return "not renamed: the proposed label is already another tag's"
        end
        upkeep_rename(db_path, p.a, name, "tag upkeep: label no longer fit its documents")
    end
    if parsed.verdict == "RENAME" or parsed.verdict == "FITS" then
        upkeep_save_fit(db_path, p.a.id, p.a.members)
    end
    if parsed.verdict == "RENAME" then
        return "renamed"
    end
    return "label still fits"
end

function upkeep_describe(p)
    if p.kind == "split" then
        return string.format("split #%d %q (%d members, spread %.3f, built %.3f)",
            p.a.id, p.a.label, p.a.members, p.a.spread, p.built_spread)
    elseif p.kind == "merge" then
        threshold = "closest at build"
        if p.review then
            threshold = "reviewing pairs above"
        end
        return string.format("merge #%d %q (%d) and #%d %q (%d) (centres %.3f apart in cosine, %s %.3f)",
            p.a.id, p.a.label, p.a.members, p.b.id, p.b.label, p.b.members, p.cosine, threshold, p.merge_cosine)
    end
    return string.format("fit #%d %q (%d members, %d when its label was last judged)",
        p.a.id, p.a.label, p.a.members, p.fit_members)
end

-- One upkeep pass. opts: judge (ask the agent), apply (write: verdicts,
-- changes, baselines), pairs_above (the merge review, never applied).
-- Without apply nothing is written. -> report lines.
function tag_upkeep.run(db_path, opts)
    -- Its own tables, idempotently: a CLI or job run on a store no web
    -- request has touched since a deploy wouldn't have them yet.
    tag_upkeep.init_schema(db_path)
    report = {}
    if opts.pairs_above != nil and opts.apply then
        return {"--pairs-above is a review: run it with --dry-run"}
    end
    proposals = tag_upkeep.proposals(db_path, not opts.apply, opts.pairs_above)
    limit = TAG_JUDGMENTS_PER_RUN
    if opts.pairs_above != nil then
        limit = TAG_REVIEW_PAIRS
    end
    asked = 0
    for _, p in ipairs(proposals) do
        line = upkeep_describe(p)
        standing = upkeep_standing_verdict(db_path, p)
        if standing != nil then
            line = line .. ": kept -- judged " .. standing.verdict .. " before (" .. tostring(standing.reason) .. ")"
        elseif not opts.judge then
            line = line .. ": would ask the agent"
        elseif asked >= limit then
            line = line .. ": left for the next run"
        else
            asked = asked + 1
            answer, err, verdicts = upkeep_ask(db_path, p)
            if answer == nil then
                line = line .. ": not judged -- " .. tostring(err)
            else
                parsed = tag_upkeep.parse(answer, verdicts)
                line = line .. ": " .. parsed.verdict .. " -- " .. parsed.reason
                for key, name in pairs(parsed.names) do
                    line = line .. "\n    " .. key .. ": " .. name.label
                end
                if opts.apply then
                    outcome = upkeep_apply(db_path, p, parsed)
                    upkeep_record(db_path, p, parsed)
                    line = line .. "\n    -> " .. outcome
                end
            end
        end
        table.insert(report, line)
    end
    return report
end

return tag_upkeep
