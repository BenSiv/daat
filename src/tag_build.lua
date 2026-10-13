-- Cold start (doc/tag-ontology.md, phase 3c): tags built in daat, from
-- its own embeddings, for a deployment that has none -- after which
-- tag.lua places documents and tag_upkeep.lua restructures them.
--
--   1. Vectors: each document's tagging vector (tag_dims) with the pool's
--      average taken out, renormalised -- in one field every document
--      shares a large common direction (tag_upkeep.lua's comment).
--   2. Micro-clusters: spherical k-means, k ~ sqrt(n) (up to
--      BUILD_MICRO_MAX, as cluster_tags.py), seeded k-means++
--      from a fixed seed, so the same pool always builds the same way.
--   3. Consensus (evidence accumulation, as cluster_tags.py's --tree, but
--      over micro-clusters rather than documents, which an n x n matrix
--      can't hold in Luam): BUILD_RUNS more k-means runs, each on a
--      BUILD_FRACTION resample with k drawn from m/2 to 2m; for
--      each pair of micro-clusters, the share of their documents' pairs
--      that landed together.
--   4. Average linkage over 1 - that share, cut where a level lives
--      longest (the gap between successive merge heights) within
--      BUILD_TAG_RANGE.
--      Documents with under tag_min_text characters of their own text
--      (a folder page, a template, a file with no text) are left out.
--   5. Every document joins its nearest tag centre (and a second within
--      tag_second_within); tags under BUILD_MIN_SIZE are dissolved into
--      their neighbours first.
--   6. The agent names each tag from its most central titles; a label two
--      tags share, or a manual tag already has, is asked again.
--
-- `daat tag build --dry-run` reports the cut, the sizes, central titles
-- and -- when the deployment has tags -- how the build agrees with them
-- (the check before cluster_tags.py is retired); `--name` adds the
-- agent's labels; without --dry-run it writes, refused while computed
-- tags exist.

db = require("database")
entity = require("entity")
config = require("config")
json = require("dkjson")
tag = require("tag")
tag_upkeep = require("tag_upkeep")
agent_provider = require("agent_provider")
document = require("document")

tag_build = {}

BUILD_SEED = 42
-- Documents build_vectors left out for too little text (for the report).
BUILD_SHORT = 0
BUILD_RUNS = 10
BUILD_FRACTION = 0.8
BUILD_MAX_ITERATIONS = 15
BUILD_TAG_RANGE = {15, 60}
BUILD_MIN_SIZE = 10
-- Micro-clusters: sqrt(n), capped -- above the tag range's top on a
-- real pool, or the cut has no resolution near it (prod 2026-10-12:
-- sqrt(n/2) = 63 micro-clusters cut at 60 tags, the range's edge). No
-- floor beyond 2: on a small pool a fixed floor leaves micro-clusters of
-- a few documents that consensus runs never put together.
BUILD_MICRO_MAX = 150
BUILD_DOCS_PER_TAG = 60

NAMING_PROMPT = """You name one group of documents from a lab's knowledge base, built as a tag.
Reply with one line: <label> | <one-sentence description of what the documents are about>.
The label is 2-5 words, a subject: specific (organism, method, material) rather than generic ("Research", "Science").
Never name publishing or access boilerplate (open access, licences, journals, downloads). No quotes, no preamble."""

DISTINCT_PROMPT = """Several groups of documents in a lab's knowledge base were given the same label. Each is summarised below by its most central titles.
Give each a distinct 2-5 word label that says how it differs from the others, keeping the shared subject where it fits.
Reply with exactly one label per line, in the order given -- no numbering, quotes or preamble."""

-- Park-Miller minimal standard: exact in doubles, the same everywhere.
function build_rng(seed)
    state = seed % 2147483647
    if state <= 0 then
        state = state + 2147483646
    end
    return function(n)
        state = (16807 * state) % 2147483647
        return (state % n) + 1
    end
end

function build_dot(a, b)
    s = 0.0
    for i = 1, #a do
        s = s + a[i] * b[i]
    end
    return s
end

function build_unit(v)
    s = 0.0
    for i = 1, #v do
        s = s + v[i] * v[i]
    end
    if s == 0.0 then
        return nil
    end
    s = math.sqrt(s)
    out = {}
    for i = 1, #v do
        out[i] = v[i] / s
    end
    return out
end

function build_list(rows)
    if rows == nil then
        return {}
    end
    return rows
end

-- Luam's and/or take booleans only, so no defaulting a missing count
-- with `or`: these stand in.
function build_get(t, key)
    if t[key] == nil then
        return 0
    end
    return t[key]
end

function build_add(t, key, by)
    t[key] = build_get(t, key) + by
end

-- Active documents with an embedding: ids, centred unit vectors.
function build_vectors(db_path)
    dims = config.platform_config().tag_dims
    rows = db.query(db_path, """
        SELECT e.document_id, e.vector_packed, e.body_chars,
               CASE WHEN e.vector_packed IS NULL THEN e.vector_json END AS vector_json
        FROM document_embedding e JOIN document d ON d.id = e.document_id
        WHERE (d.archived_at IS NULL OR d.archived_at = '') ORDER BY e.document_id;""")
    ids, raw = {}, {}
    min_text = config.platform_config().tag_min_text
    BUILD_SHORT = 0
    for _, row in ipairs(build_list(rows)) do
        -- Too little text of its own to have a subject (tag_min_text);
        -- body_chars unknown (NULL) counts as enough.
        body_chars = tonumber(row.body_chars)
        if body_chars != nil and body_chars < min_text then
            BUILD_SHORT = BUILD_SHORT + 1
        else
            full = document.unpack_vector(row.vector_packed)
            if full == nil and row.vector_json != nil and row.vector_json != "" then
                decoded, _, _ = json.decode(row.vector_json)
                if type(decoded) == "table" then
                    full = decoded
                end
            end
            if full != nil and #full > 0 then
                cut = tag.unit(full, dims)
                if cut != nil then
                    table.insert(ids, tonumber(row.document_id))
                    table.insert(raw, cut)
                end
            end
        end
    end
    if #raw == 0 then
        return ids, raw
    end
    mean = {}
    for i = 1, #raw[1] do
        mean[i] = 0.0
    end
    for _, v in ipairs(raw) do
        for i = 1, #mean do
            mean[i] = mean[i] + v[i] / #raw
        end
    end
    vectors, kept = {}, {}
    for j, v in ipairs(raw) do
        if #v == #mean then
            shifted = {}
            for i = 1, #mean do
                shifted[i] = v[i] - mean[i]
            end
            u = build_unit(shifted)
            if u != nil then
                table.insert(kept, ids[j])
                table.insert(vectors, u)
            end
        end
    end
    return kept, vectors
end

-- Spherical k-means over vectors[index[1..]]: k-means++ seeding from
-- `rng`, then Lloyd rounds until assignments settle. -> labels (one per
-- index entry, 1..k), centres.
function build_kmeans(vectors, index, k, rng)
    n = #index
    if k > n then
        k = n
    end
    centres = {vectors[index[rng(n)]]}
    best = {}
    for i = 1, n do
        best[i] = build_dot(vectors[index[i]], centres[1])
    end
    while #centres < k do
        total = 0.0
        for i = 1, n do
            total = total + math.max(0.0, 1.0 - best[i])
        end
        target = (rng(1000000) / 1000000) * total
        pick = n
        running = 0.0
        for i = 1, n do
            running = running + math.max(0.0, 1.0 - best[i])
            if running >= target then
                pick = i
                break
            end
        end
        c = vectors[index[pick]]
        table.insert(centres, c)
        for i = 1, n do
            d = build_dot(vectors[index[i]], c)
            if d > best[i] then
                best[i] = d
            end
        end
    end
    labels = {}
    for round = 1, BUILD_MAX_ITERATIONS do
        changed = 0
        for i = 1, n do
            v = vectors[index[i]]
            top, top_score = 1, -2.0
            for c = 1, #centres do
                s = build_dot(v, centres[c])
                if s > top_score then
                    top, top_score = c, s
                end
            end
            if labels[i] != top then
                changed = changed + 1
            end
            labels[i] = top
        end
        sums = {}
        for c = 1, #centres do
            sums[c] = nil
        end
        for i = 1, n do
            c = labels[i]
            v = vectors[index[i]]
            if sums[c] == nil then
                sums[c] = {}
                for j = 1, #v do
                    sums[c][j] = 0.0
                end
            end
            for j = 1, #v do
                sums[c][j] = sums[c][j] + v[j]
            end
        end
        for c = 1, #centres do
            if sums[c] != nil then
                u = build_unit(sums[c])
                if u != nil then
                    centres[c] = u
                end
            end
        end
        if changed <= n / 1000 then
            break
        end
    end
    return labels, centres
end

-- Average linkage (size-weighted) over a distance matrix of m items with
-- `sizes`. -> merges {{a, b, height}, ...} in order, items numbered 1..m
-- and each merge creating item m + step.
function build_average_linkage(distance, sizes)
    m = #sizes
    active, size, dist = {}, {}, {}
    for i = 1, m do
        active[i] = true
        size[i] = sizes[i]
        dist[i] = {}
        for j = 1, m do
            dist[i][j] = distance[i][j]
        end
    end
    merges = {}
    next_id = m
    for step = 1, m - 1 do
        ba, bb, bd = nil, nil, math.huge
        for i, _ in pairs(active) do
            for j, _ in pairs(active) do
                if i < j and dist[i][j] < bd then
                    ba, bb, bd = i, j, dist[i][j]
                end
            end
        end
        if ba == nil then
            break
        end
        next_id = next_id + 1
        dist[next_id] = {}
        for k, _ in pairs(active) do
            if k != ba and k != bb then
                d = (dist[ba][k] * size[ba] + dist[bb][k] * size[bb]) / (size[ba] + size[bb])
                dist[next_id][k] = d
                dist[k][next_id] = d
            end
        end
        size[next_id] = size[ba] + size[bb]
        active[ba], active[bb] = nil, nil
        active[next_id] = true
        table.insert(merges, {ba, bb, bd})
    end
    return merges
end

-- The micro-clusters grouped into `groups` tags by replaying the merges
-- until that many remain. -> group number per micro-cluster.
function build_cut(merges, m, groups)
    parent = {}
    function find(x)
        while parent[x] != nil do
            x = parent[x]
        end
        return x
    end
    remaining = m
    for step, merge in ipairs(merges) do
        if remaining <= groups then
            break
        end
        parent[merge[1]] = m + step
        parent[merge[2]] = m + step
        remaining = remaining - 1
    end
    -- Groups numbered 1..count in order of first appearance.
    roots, out, count = {}, {}, 0
    for i = 1, m do
        r = find(i)
        if roots[r] == nil then
            count = count + 1
            roots[r] = count
        end
        out[i] = roots[r]
    end
    return out
end

-- The tag count whose level lives longest within the range: cutting after
-- merge i leaves m - i groups, living for h[i+1] - h[i]. The range's floor
-- scales with the pool -- a tag per BUILD_DOCS_PER_TAG documents at least,
-- up to BUILD_TAG_RANGE's -- so a small pool can have a few tags.
function build_choose(merges, m, n)
    low = math.min(BUILD_TAG_RANGE[1], math.max(2, math.floor(n / BUILD_DOCS_PER_TAG)))
    high = math.min(BUILD_TAG_RANGE[2], m - 1)
    best, best_life = nil, -1.0
    for i = 1, #merges - 1 do
        groups = m - i
        life = merges[i + 1][3] - merges[i][3]
        -- >=: merges run from many groups to few, so a tie goes to the
        -- coarser cut -- the simpler answer.
        if groups >= low and groups <= high and life >= best_life then
            best, best_life = groups, life
        end
    end
    if best == nil then
        best, best_life = math.max(1, math.min(high, m)), 0.0
    end
    return best, best_life, low, high
end

function build_centres(vectors, label_of, k)
    sums = {}
    for i, v in ipairs(vectors) do
        c = label_of[i]
        if c != nil then
            if sums[c] == nil then
                sums[c] = {}
                for j = 1, #v do
                    sums[c][j] = 0.0
                end
            end
            for j = 1, #v do
                sums[c][j] = sums[c][j] + v[j]
            end
        end
    end
    centres = {}
    for c = 1, k do
        if sums[c] != nil then
            centres[c] = build_unit(sums[c])
        end
    end
    return centres
end

-- Documents to their nearest tag centre, tags under BUILD_MIN_SIZE
-- dissolved first. -> {{centre, members = {{position, score, second}}}}.
function build_assign(vectors, micro, group_of, groups)
    label_of = {}
    for i = 1, #vectors do
        label_of[i] = group_of[micro[i]]
    end
    centres = build_centres(vectors, label_of, groups)
    for pass = 1, 2 do
        sizes = {}
        for i = 1, #vectors do
            build_add(sizes, label_of[i], 1)
        end
        live = 0
        for c = 1, groups do
            if centres[c] != nil and build_get(sizes, c) >= BUILD_MIN_SIZE then
                live = live + 1
            end
        end
        if live > 0 then
            for c = 1, groups do
                if build_get(sizes, c) < BUILD_MIN_SIZE then
                    centres[c] = nil
                end
            end
        end
        for i, v in ipairs(vectors) do
            top, top_score = nil, -2.0
            for c = 1, groups do
                if centres[c] != nil then
                    s = build_dot(v, centres[c])
                    if s > top_score then
                        top, top_score = c, s
                    end
                end
            end
            label_of[i] = top
        end
        centres = build_centres(vectors, label_of, groups)
    end
    within = config.platform_config().tag_second_within
    tags, slot = {}, {}
    for c = 1, groups do
        if centres[c] != nil then
            table.insert(tags, {centre = centres[c], members = {}})
            slot[c] = #tags
        end
    end
    for i, v in ipairs(vectors) do
        scores = {}
        for c, t in pairs(slot) do
            table.insert(scores, {t, build_dot(v, centres[c])})
        end
        table.sort(scores, function(a, b) return a[2] > b[2] end)
        if #scores > 0 then
            table.insert(tags[scores[1][1]].members, {position = i, score = scores[1][2]})
            if within != nil and #scores > 1 and scores[1][2] - scores[2][2] < within then
                table.insert(tags[scores[2][1]].members, {position = i, score = scores[2][2], second = true})
            end
        end
    end
    table.sort(tags, function(a, b) return #a.members > #b.members end)
    return tags
end

-- The whole build, nothing written. -> plan {ids, vectors, tags = {{
-- centre, members = {positions}}, ...}, micro, groups, life, low, high}.
function tag_build.plan(db_path, report)
    started = os.time()
    ids, vectors = build_vectors(db_path)
    n = #ids
    if n < 2 then
        return nil, "fewer than two documents with an embedding"
    end
    report(string.format("%d documents with an embedding (pool average removed, %d dimensions); %d left out with under %d characters of text",
        n, #vectors[1], BUILD_SHORT, config.platform_config().tag_min_text))
    m = math.max(2, math.min(BUILD_MICRO_MAX, math.floor(math.sqrt(n) + 0.5)))
    rng = build_rng(BUILD_SEED)
    everyone = {}
    for i = 1, n do
        everyone[i] = i
    end
    micro, _ = build_kmeans(vectors, everyone, m, rng)
    count = {}
    for c = 1, m do
        count[c] = 0
    end
    for i = 1, n do
        count[micro[i]] = count[micro[i]] + 1
    end
    report(string.format("%d micro-clusters (%ds)", m, os.time() - started))

    -- Consensus: share of each micro pair's document pairs put together.
    together = {}
    for a = 1, m do
        together[a] = {}
        for b = 1, m do
            together[a][b] = 0.0
        end
    end
    weight = {}
    for a = 1, m do
        weight[a] = {}
        for b = 1, m do
            weight[a][b] = 0.0
        end
    end
    for run = 1, BUILD_RUNS do
        sample = {}
        for i = 1, n do
            if rng(1000) <= BUILD_FRACTION * 1000 then
                table.insert(sample, i)
            end
        end
        -- k from m/2 to 2m, as cluster_tags.py: a run much coarser than
        -- the real groups forces some of them together and blurs them.
        k_low = math.max(2, math.floor(m / 2))
        k = k_low + rng(math.max(1, 2 * m - k_low + 1)) - 1
        labels, _ = build_kmeans(vectors, sample, k, rng)
        hist = {}
        for a = 1, m do
            hist[a] = {}
        end
        sampled = {}
        for a = 1, m do
            sampled[a] = 0
        end
        for s, i in ipairs(sample) do
            a = micro[i]
            build_add(hist[a], labels[s], 1)
            sampled[a] = sampled[a] + 1
        end
        for a = 1, m do
            for b = a, m do
                if sampled[a] > 0 and sampled[b] > 0 then
                    shared = 0.0
                    for l, ca in pairs(hist[a]) do
                        cb = hist[b][l]
                        if cb != nil then
                            shared = shared + ca * cb
                        end
                    end
                    rate = shared / (sampled[a] * sampled[b])
                    together[a][b] = together[a][b] + rate
                    weight[a][b] = weight[a][b] + 1
                    together[b][a], weight[b][a] = together[a][b], weight[a][b]
                end
            end
        end
        report(string.format("consensus run %d/%d: k=%d on %d documents (%ds)", run, BUILD_RUNS, k, #sample, os.time() - started))
    end
    distance = {}
    for a = 1, m do
        distance[a] = {}
        for b = 1, m do
            if a == b then
                distance[a][b] = 0.0
            elseif weight[a][b] > 0 then
                distance[a][b] = 1.0 - together[a][b] / weight[a][b]
            else
                distance[a][b] = 1.0
            end
        end
    end
    merges = build_average_linkage(distance, count)
    groups, life, low, high = build_choose(merges, m, n)
    group_of = build_cut(merges, m, groups)
    report(string.format("cut: %d tags (level lives %.3f; range %d-%d)", groups, life, low, high))

    tags = build_assign(vectors, micro, group_of, groups)
    if #tags != groups then
        report(string.format("%d tags after dissolving those under %d documents", #tags, BUILD_MIN_SIZE))
    end
    return {ids = ids, vectors = vectors, tags = tags, micro = m, groups = groups, life = life, low = low, high = high}
end

-- How the plan agrees with the deployment's current tags (each
-- document's first active tag): adjusted Rand over documents in both,
-- and each built tag's largest current tag. nil when there are none.
function build_agreement(db_path, plan)
    rows = db.query(db_path, """
        SELECT dt.document, dt.tag, t.label FROM document_tag dt JOIN tag t ON t.id = dt.tag
        WHERE (dt.archived_at IS NULL OR dt.archived_at = '') AND dt.decision != 'excluded'
          AND (t.archived_at IS NULL OR t.archived_at = '')
        ORDER BY dt.document, CASE WHEN dt.decision = 'pinned' THEN 0 ELSE 1 END, dt.score DESC;""")
    current, label = {}, {}
    for _, row in ipairs(build_list(rows)) do
        d = tonumber(row.document)
        if current[d] == nil then
            current[d] = tonumber(row.tag)
            label[tonumber(row.tag)] = row.label
        end
    end
    if next(current) == nil then
        return nil
    end
    built = {}
    for t, tg in ipairs(plan.tags) do
        for _, mbr in ipairs(tg.members) do
            if mbr.second != true then
                built[plan.ids[mbr.position]] = t
            end
        end
    end
    cells, rowsum, colsum, total = {}, {}, {}, 0
    for d, b in pairs(built) do
        c = current[d]
        if c != nil then
            key = b .. ":" .. c
            build_add(cells, key, 1)
            build_add(rowsum, b, 1)
            build_add(colsum, c, 1)
            total = total + 1
        end
    end
    function pairs_of(x)
        return x * (x - 1) / 2
    end
    index, sum_rows, sum_cols = 0.0, 0.0, 0.0
    for _, v in pairs(cells) do
        index = index + pairs_of(v)
    end
    for _, v in pairs(rowsum) do
        sum_rows = sum_rows + pairs_of(v)
    end
    for _, v in pairs(colsum) do
        sum_cols = sum_cols + pairs_of(v)
    end
    expected = sum_rows * sum_cols / pairs_of(total)
    maximum = (sum_rows + sum_cols) / 2
    ari = 0.0
    if maximum != expected then
        ari = (index - expected) / (maximum - expected)
    end
    best_match = {}
    for key, v in pairs(cells) do
        b, c = string.match(key, "^(%d+):(%d+)$")
        b, c = tonumber(b), tonumber(c)
        if best_match[b] == nil or v > best_match[b][2] then
            best_match[b] = {label[c], v}
        end
    end
    tagged = 0
    for _, v in pairs(colsum) do
        tagged = tagged + 1
    end
    return {ari = ari, documents = total, current_tags = tagged, best = best_match, rowsum = rowsum}
end

function build_members_for_titles(plan, t)
    members = {}
    for _, mbr in ipairs(plan.tags[t].members) do
        if mbr.second != true then
            table.insert(members, {document = plan.ids[mbr.position], vector = plan.vectors[mbr.position], membership = mbr.position})
        end
    end
    return members
end

-- The agent's label and description for each tag; labels two tags got,
-- or that a manual tag has, asked again together.
function build_name(db_path, plan, report)
    context = tag_upkeep.context()
    for t, tg in ipairs(plan.tags) do
        titles = tag_upkeep.titles(db_path, build_members_for_titles(plan, t), tg.centre, false)
        answer, err = agent_provider.generate(nil, context .. NAMING_PROMPT, titles)
        tg.titles = titles
        if answer == nil then
            return nil, "naming tag " .. t .. ": " .. tostring(err)
        end
        line = string.match(tostring(answer), "[^\n]+")
        if line == nil then
            line = ""
        end
        label, description = string.match(line, "^(.-)%s*|%s*(.*)$")
        if label == nil then
            label, description = line, nil
        end
        label = string.gsub(label, "^[\"'%s%*]+", "")
        label = string.gsub(label, "[\"'%.%s%*]+$", "")
        tg.label, tg.description = string.sub(label, 1, 80), description
        report(string.format("named %d/%d: %s", t, #plan.tags, tg.label))
    end
    by_label = {}
    for t, tg in ipairs(plan.tags) do
        key = string.lower(tg.label)
        if by_label[key] == nil then
            by_label[key] = {}
        end
        table.insert(by_label[key], t)
    end
    for key, group in pairs(by_label) do
        if #group > 1 or tag_upkeep.label_taken(db_path, plan.tags[group[1]].label, {}) then
            prompt = {}
            for i, t in ipairs(group) do
                table.insert(prompt, "Group " .. i .. "\n" .. plan.tags[t].titles)
            end
            answer, _ = agent_provider.generate(nil, context .. DISTINCT_PROMPT, table.concat(prompt, "\n\n"))
            i = 0
            for line in string.gmatch(tostring(answer), "[^\n]+") do
                line = string.gsub(line, "^[%s%-%*%d%.%)]+", "")
                line = string.gsub(line, "[\"'%.%s%*]+$", "")
                if line != "" and i < #group then
                    i = i + 1
                    plan.tags[group[i]].label = string.sub(line, 1, 80)
                end
            end
        end
    end
    return plan
end

-- Creates the tags and memberships and records the upkeep baselines.
function build_write(db_path, plan, report)
    author = "system"
    now = os.date("!%Y-%m-%d %H:%M:%S")
    for t, tg in ipairs(plan.tags) do
        values = {label = tg.label, source = "computed", computed_at = now}
        if tg.description != nil and tg.description != "" then
            values.description = tg.description
        end
        tag_id, issues = entity.create(db_path, "tag", values, author)
        if tag_id == nil then
            return nil, "creating tag " .. tostring(tg.label) .. ": " .. json.encode(issues)
        end
        for _, mbr in ipairs(tg.members) do
            entity.create(db_path, "document_tag", {
                document = tostring(plan.ids[mbr.position]), tag = tostring(tag_id),
                score = string.format("%.4f", mbr.score), decision = "computed",
            }, author)
        end
        report(string.format("wrote tag #%d %q: %d documents", tag_id, tg.label, #tg.members))
    end
    tag.rebuild_centres(db_path)
    tag_upkeep.record_baselines(db_path)
    return true
end

-- `daat tag build [--dry-run [--name]]`.
function tag_build.run(db_path, opts)
    function report(line)
        print(line)
        io.flush()
    end
    if opts.dry_run != true then
        rows = db.query(db_path, "SELECT COUNT(*) AS n FROM tag WHERE source = 'computed' AND (archived_at IS NULL OR archived_at = '');")
        if rows != nil and rows[1] != nil and tonumber(rows[1].n) > 0 then
            report("Refused: this deployment already has computed tags -- a cold start builds the first ones (--dry-run compares with them)")
            return
        end
    end
    plan, err = tag_build.plan(db_path, report)
    if plan == nil then
        report("Nothing built: " .. tostring(err))
        return
    end
    agreement = build_agreement(db_path, plan)
    if opts.name == true or opts.dry_run != true then
        plan, err = build_name(db_path, plan, report)
        if plan == nil then
            report("Nothing built: " .. tostring(err))
            return
        end
    end
    report("")
    for t, tg in ipairs(plan.tags) do
        primary = 0
        for _, mbr in ipairs(tg.members) do
            if mbr.second != true then
                primary = primary + 1
            end
        end
        head = string.format("tag %d: %d documents (%d as second)", t, primary, #tg.members - primary)
        if tg.label != nil then
            head = head .. " -- " .. tg.label
        end
        if agreement != nil and agreement.best[t] != nil then
            head = head .. string.format("  [mostly %q: %d of %d]", tostring(agreement.best[t][1]), agreement.best[t][2], agreement.rowsum[t])
        end
        report(head)
        if tg.titles == nil then
            tg.titles = tag_upkeep.titles(db_path, build_members_for_titles(plan, t), tg.centre, false)
        end
        for line in string.gmatch(tg.titles, "[^\n]+") do
            report("    " .. string.sub(line, 1, 110))
        end
    end
    if agreement != nil then
        report(string.format("\nAgreement with the current tags: adjusted Rand %.3f over %d documents (%d current tags, %d built)",
            agreement.ari, agreement.documents, agreement.current_tags, #plan.tags))
    end
    if opts.dry_run then
        report("Dry run: nothing written")
        return
    end
    ok, err = build_write(db_path, plan, report)
    if ok == nil then
        report("Stopped: " .. tostring(err))
    end
end

return tag_build
