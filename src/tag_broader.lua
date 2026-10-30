-- The broader tag level (doc/tag-ontology.md, "Broader tags"): the
-- computed tags are grouped into a few broad subjects, each a tag of its
-- own (source "broader") that the specific tags point to through
-- `parent`. The specific tags and their documents don't change; the
-- broad level is for browsing -- the graph's "Colour by tag" colours by
-- it, "Colour by sub-tag" by the specific tags (Ben, 2026-10-29: 50
-- tags were too many to see, without changing the clustering).
--
-- The agent groups by subject: one call gets every tag (label and
-- description) and puts each in a subject area it names. Document
-- similarity can't do this -- on prod it grouped by kind of document
-- (literature, protocols, internal records), and given that grouping as
-- a starting point the agent only renamed it (2026-10-30). The data
-- comes in where the agent leaves a tag out: it joins the area whose
-- tags' centred centres (tag_upkeep.lua) are nearest its own.
--
-- A broad tag holds no documents of its own and has no centre, so a new
-- document is never placed in one. A person's parent (on a manual tag,
-- or pointing at a tag that isn't broader) is left as it is.

db = require("database")
entity = require("entity")
config = require("config")
tag = require("tag")
tag_upkeep = require("tag_upkeep")
agent_provider = require("agent_provider")

tag_broader = {}

BROADER_PROMPT = """You organise the subject tags of a lab's knowledge base into broad subject areas, for browsing.
Group by what the documents are about, not by the kind of document: literature, protocols, data and meeting notes on the same subject belong in the same area. Tags whose subject is outside the lab's field can share one area.
Make 5 to 12 areas, and put every tag in exactly one. For each area reply:
AREA: <label> | <one-sentence description of the subject area>
- <tag label, exactly as given>
- <tag label>
Labels are 1-4 words, broader than any tag in the area, and distinct from each other. Reply with those lines only."""

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

-- The agent's reply: {{label, description, members = {lowercased tag
-- label -> true}}, ...}, in order.
function tag_broader.parse(answer)
    areas = {}
    current = nil
    for line in string.gmatch(tostring(answer), "[^\n]+") do
        rest = string.match(line, "^%s*AREA%s*:%s*(.-)%s*$")
        member = string.match(line, "^%s*[%-%*]%s*(.-)%s*$")
        if rest != nil then
            label, description = string.match(rest, "^(.-)%s*|%s*(.*)$")
            if label == nil then
                label, description = rest, nil
            end
            label = string.gsub(label, "^[\"'%s%*]+", "")
            label = string.gsub(label, "[\"'%.%s%*]+$", "")
            current = {label = string.sub(label, 1, 80), description = description, members = {}}
            table.insert(areas, current)
        elseif member != nil and current != nil then
            member = string.gsub(member, "^[\"'%*]+", "")
            member = string.gsub(member, "[\"'%*]+$", "")
            current.members[string.lower(member)] = true
        end
    end
    return areas
end

-- The area whose assigned tags' centred centres are, on average, nearest
-- the tag's own. -> area index, or nil.
function broader_nearest(t, tags, area_of)
    best, best_score = nil, -2.0
    sums, counts = {}, {}
    for i, other in ipairs(tags) do
        a = area_of[i]
        if a != nil and other.centred != nil and t.centred != nil then
            if sums[a] == nil then
                sums[a], counts[a] = 0, 0
            end
            sums[a] = sums[a] + tag.dot(t.centred, other.centred)
            counts[a] = counts[a] + 1
        end
    end
    for a, total in pairs(sums) do
        score = total / counts[a]
        if score > best_score then
            best, best_score = a, score
        end
    end
    return best
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
    prompt = {}
    for _, t in ipairs(tags) do
        entry = "- " .. tostring(t.label)
        if t.description != nil and t.description != "" then
            entry = entry .. ": " .. t.description
        end
        table.insert(prompt, entry)
    end
    answer, err = agent_provider.generate(nil, tag_upkeep.context() .. BROADER_PROMPT, table.concat(prompt, "\n"))
    if answer == nil then
        table.insert(lines, "Stopped: " .. tostring(err))
        return lines
    end
    areas = tag_broader.parse(answer)
    if #areas == 0 then
        table.insert(lines, "Stopped: no area could be read from the agent's reply")
        return lines
    end
    count = #areas
    names = {}
    group_of = {}
    for a, area in ipairs(areas) do
        names[a] = {label = area.label, description = area.description}
    end
    for i, t in ipairs(tags) do
        for a, area in ipairs(areas) do
            if group_of[i] == nil and area.members[string.lower(tostring(t.label))] == true then
                group_of[i] = a
            end
        end
    end
    -- Tags the agent left out join their nearest area.
    for i, t in ipairs(tags) do
        if group_of[i] == nil then
            a = broader_nearest(t, tags, group_of)
            if a == nil then
                a = 1
            end
            group_of[i] = a
            table.insert(lines, string.format("%q was left out; placed in %s, the nearest area", tostring(t.label), names[a].label))
        end
    end

    used = 0
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
            used = used + 1
            table.insert(lines, string.format("%s (%d tags): %s", names[g].label, #members, table.concat(members, "; ")))
        end
    end
    if opts.dry_run == true then
        table.insert(lines, string.format("Dry run: %d broad tags over %d tags, nothing written", used, #tags))
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
