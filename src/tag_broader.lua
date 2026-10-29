-- The broader tag level (doc/tag-ontology.md, "Broader tags"): the
-- computed tags are grouped into a few broad subjects, each a tag of its
-- own (source "broader") that the specific tags point to through
-- `parent`. The specific tags and their documents don't change; the
-- broad level is for browsing -- the graph's "Colour by tag" colours by
-- it, "Colour by sub-tag" by the specific tags (Ben, 2026-10-29: 50
-- tags were too many to see, without changing the clustering).
--
-- The data proposes, the agent decides, as elsewhere in tag upkeep:
-- average linkage over the tags' centred centres (tag_upkeep.lua) cut at
-- the level that lives longest within BROADER_RANGE; then one agent call
-- names each group and may move a tag that doesn't fit its group.
--
-- A broad tag holds no documents of its own and has no centre, so a new
-- document is never placed in one. A person's parent (on a manual tag,
-- or pointing at a tag that isn't broader) is left as it is.

db = require("database")
entity = require("entity")
config = require("config")
tag = require("tag")
tag_upkeep = require("tag_upkeep")
tag_build = require("tag_build")
agent_provider = require("agent_provider")

tag_broader = {}

-- Broad tags: a tag per BROADER_TAGS_PER_GROUP specific ones, between
-- these bounds.
BROADER_RANGE = {4, 12}
BROADER_TAGS_PER_GROUP = 5

BROADER_PROMPT = """You organise the subject tags of a lab's knowledge base into a few broad areas, for browsing.
You get the tags already grouped by how close their documents are. For each group, reply with one line:
GROUP <n>: <label> | <one-sentence description of the broad area>
Labels are 1-4 words, broader than any tag in the group, and distinct from each other.
If a tag clearly belongs in another group, add one line per tag:
MOVE <tag label> -> <group number>
Reply with those lines only."""

-- The specific tags to group: every active tag with a centre whose
-- parent is empty or a broad tag (a person's nesting stays).
function tag_broader.specific_tags(db_path)
    broad = {}
    rows = db.query(db_path, "SELECT id FROM tag WHERE source = 'broader' AND (archived_at IS NULL OR archived_at = '');")
    if rows != nil then
        for _, row in ipairs(rows) do
            broad[tostring(tonumber(row.id))] = true
        end
    end
    out = {}
    for _, t in ipairs(tag_upkeep.tags(db_path)) do
        if t.source != "broader" and t.centred != nil and (t.parent == nil or broad[tostring(t.parent)] == true) then
            table.insert(out, t)
        end
    end
    return out
end

-- Groups the tags by average linkage over 1 - cosine of their centred
-- centres, cut at the longest-lived level in range. -> group per tag
-- index, the number of groups.
function tag_broader.group(tags)
    n = #tags
    distance = {}
    sizes = {}
    for i = 1, n do
        distance[i] = {}
        sizes[i] = 1
        for j = 1, n do
            if i == j then
                distance[i][j] = 0.0
            else
                distance[i][j] = 1.0 - tag.dot(tags[i].centred, tags[j].centred)
            end
        end
    end
    merges = tag_build.average_linkage(distance, sizes)
    low = math.max(2, math.min(BROADER_RANGE[1], n - 1))
    high = math.max(low, math.min(BROADER_RANGE[2], math.floor(n / 2)))
    target = math.floor(n / BROADER_TAGS_PER_GROUP + 0.5)
    best, best_life = nil, -1.0
    for i = 1, #merges - 1 do
        groups = n - i
        life = merges[i + 1][3] - merges[i][3]
        if groups >= low and groups <= high and life >= best_life then
            best, best_life = groups, life
        end
    end
    if best == nil then
        best = math.max(1, math.min(high, target))
    end
    return tag_build.cut(merges, n, best), best
end

-- The agent's reply: names per group number, and moves by tag label.
function tag_broader.parse(answer, groups)
    names, moves = {}, {}
    for line in string.gmatch(tostring(answer), "[^\n]+") do
        n, rest = string.match(line, "^%s*GROUP%s+(%d+)%s*:%s*(.-)%s*$")
        if n != nil then
            label, description = string.match(rest, "^(.-)%s*|%s*(.*)$")
            if label == nil then
                label, description = rest, nil
            end
            label = string.gsub(label, "^[\"'%s%*]+", "")
            label = string.gsub(label, "[\"'%.%s%*]+$", "")
            if label != "" then
                names[tonumber(n)] = {label = string.sub(label, 1, 80), description = description}
            end
        end
        from, to = string.match(line, "^%s*MOVE%s+(.-)%s*%->%s*(%d+)%s*$")
        if from != nil and tonumber(to) != nil and tonumber(to) >= 1 and tonumber(to) <= groups then
            from = string.gsub(from, "^[\"'%s%*]+", "")
            from = string.gsub(from, "[\"'%s%*]+$", "")
            moves[string.lower(from)] = tonumber(to)
        end
    end
    return names, moves
end

-- `daat tag broaden [--dry-run] [--replace]`.
function tag_broader.run(db_path, opts)
    lines = {}
    existing = db.query(db_path, "SELECT id, label FROM tag WHERE source = 'broader' AND (archived_at IS NULL OR archived_at = '');")
    if opts.dry_run != true and existing != nil and #existing > 0 and opts.replace != true then
        table.insert(lines, "Refused: broad tags exist -- --replace archives them and groups the tags again")
        return lines
    end
    tags = tag_broader.specific_tags(db_path)
    if #tags < 4 then
        table.insert(lines, "Nothing to group: " .. #tags .. " tag(s)")
        return lines
    end
    group_of, count = tag_broader.group(tags)

    prompt = {}
    for g = 1, count do
        members = {}
        for i, t in ipairs(tags) do
            if group_of[i] == g then
                entry = "- " .. tostring(t.label)
                if t.description != nil and t.description != "" then
                    entry = entry .. ": " .. t.description
                end
                table.insert(members, entry)
            end
        end
        table.insert(prompt, "Group " .. g .. ":\n" .. table.concat(members, "\n"))
    end
    answer, err = agent_provider.generate(nil, tag_upkeep.context() .. BROADER_PROMPT, table.concat(prompt, "\n\n"))
    if answer == nil then
        table.insert(lines, "Stopped: " .. tostring(err))
        return lines
    end
    names, moves = tag_broader.parse(answer, count)
    for i, t in ipairs(tags) do
        to = moves[string.lower(tostring(t.label))]
        if to != nil and to != group_of[i] then
            table.insert(lines, string.format("moved %q from group %d to %d", tostring(t.label), group_of[i], to))
            group_of[i] = to
        end
    end

    for g = 1, count do
        if names[g] == nil then
            names[g] = {label = "Group " .. g, description = nil}
        end
        members = {}
        for i, t in ipairs(tags) do
            if group_of[i] == g then
                table.insert(members, tostring(t.label))
            end
        end
        if #members > 0 then
            table.insert(lines, string.format("%s (%d tags): %s", names[g].label, #members, table.concat(members, "; ")))
        end
    end
    if opts.dry_run == true then
        table.insert(lines, string.format("Dry run: %d broad tags over %d tags, nothing written", count, #tags))
        return lines
    end

    author = "system"
    if existing != nil then
        for _, row in ipairs(existing) do
            entity.archive(db_path, "tag", tonumber(row.id), author, nil, "replaced by tag broaden")
        end
    end
    now = os.date("!%Y-%m-%d %H:%M:%S")
    written = 0
    for g = 1, count do
        has = false
        for i, _ in ipairs(tags) do
            if group_of[i] == g then
                has = true
            end
        end
        if has then
            values = {label = names[g].label, source = "broader", computed_at = now}
            if names[g].description != nil and names[g].description != "" then
                values.description = names[g].description
            end
            broad_id, issues = entity.create(db_path, "tag", values, author)
            if broad_id != nil then
                written = written + 1
                for i, t in ipairs(tags) do
                    if group_of[i] == g then
                        entity.update(db_path, "tag", t.id, {parent = tostring(broad_id)}, author, nil, "tag broaden")
                    end
                end
            else
                table.insert(lines, "could not write " .. tostring(names[g].label))
            end
        end
    end
    table.insert(lines, string.format("Wrote %d broad tags over %d tags", written, #tags))
    return lines
end

return tag_broader
