-- Groups specific tags under library-backed broader tags (`source = 'broader'`)
-- via `tag.parent` for browsing, preserving human-set parent assignments.
-- See doc/tag-ontology.md.

const db = require("database")
const entity = require("entity")
const config = require("config")
const tag = require("tag")
const tag_upkeep = require("tag.upkeep")
const agent_provider = require("agent_provider")

const tag_broader = {}

const BROADER_PROMPT = """You organise the subject tags of a lab's knowledge base into broad subject areas, for browsing.
Group by what the documents are about, not by the kind of document: literature, protocols, data and meeting notes on the same subject belong in the same area. Tags whose subject is outside the lab's field can share one area.
Use the areas of the library below. Only when no library area fits a tag, add a new area, and say why in one line. Put every tag in exactly one area; leave out library areas no tag belongs to.
For each area you use reply:
AREA: <library label, exactly as given>
- <tag label, exactly as given>
For a new area:
NEW AREA: <label, 1-4 words> | <one-sentence description> | <why no library area fits>
- <tag label>
Reply with those lines only."""

function tag_broader.library(db_path)
    rows = db.query(db_path, """
        SELECT id, label, description, archived_at FROM tag WHERE source = 'broader'
        ORDER BY CASE WHEN archived_at IS NULL OR archived_at = '' THEN 0 ELSE 1 END, id;""")
    library, seen = {}, {}
    if rows == nil then
        return library
    end
    for _, row in ipairs(rows) do
        key = string.lower(tostring(row.label))
        if seen[key] == nil then
            seen[key] = true
            table.insert(library, {id = tonumber(row.id), label = tostring(row.label), description = row.description,
                archived = row.archived_at != nil and row.archived_at != ""})
        end
    end
    table.sort(library, function(a, b) return string.lower(a.label) < string.lower(b.label) end)
    return library
end

function tag_broader.library_add(db_path, label, description, author)
    for _, entry in ipairs(tag_broader.library(db_path)) do
        if string.lower(entry.label) == string.lower(label) then
            return nil, "already in the library: " .. entry.label
        end
    end
    values = {label = label, source = "broader", computed_at = os.date("!%Y-%m-%d %H:%M:%S")}
    if description != nil and description != "" then
        values.description = description
    end
    id, issues = entity.create(db_path, "tag", values, author)
    if id == nil then
        return nil, "could not add " .. label
    end
    entity.archive(db_path, "tag", id, author, nil, "library area, not in use yet")
    return id
end

-- Tags whose latest `parent` event in entity_event has a non-"system" author
-- are human-placed and excluded from automated regrouping. See doc/decisions/007-usage-driven-knowledge-pool-and-curation-ladder.md.
function tag_broader.hand_placed(db_path)
    rows = db.query(db_path, """
        SELECT entity_id, author FROM entity_event
        WHERE entity_type = 'tag' AND field_changes LIKE '%"parent"%'
        ORDER BY event_id;""")
    last = {}
    if rows != nil then
        for _, row in ipairs(rows) do
            last[tostring(tonumber(row.entity_id))] = row.author
        end
    end
    out = {}
    parents = db.query(db_path, "SELECT id, parent FROM tag WHERE archived_at IS NULL OR archived_at = '';")
    if parents == nil then
        return out
    end
    for _, row in ipairs(parents) do
        key = tostring(tonumber(row.id))
        author = last[key]
        if author != nil and author != "" and author != "system" and row.parent != nil and row.parent != "" then
            out[key] = tostring(row.parent)
        end
    end
    return out
end

function tag_broader.specific_tags(db_path)
    hand = tag_broader.hand_placed(db_path)
    broad = {}
    rows = db.query(db_path, "SELECT id FROM tag WHERE source = 'broader';")
    if rows != nil then
        for _, row in ipairs(rows) do
            broad[tostring(tonumber(row.id))] = true
        end
    end
    out = {}
    for _, t in ipairs(tag_upkeep.tags(db_path)) do
        if t.source != "broader" and t.centred != nil and (t.parent == nil or broad[tostring(t.parent)] == true)
            and hand[tostring(t.id)] == nil then
            table.insert(out, t)
        end
    end
    return out
end

function tag_broader.parse(answer)
    areas = {}
    current = nil
    for line in string.gmatch(tostring(answer), "[^\n]+") do
        fresh = string.match(line, "^%s*NEW AREA%s*:%s*(.-)%s*$")
        known = string.match(line, "^%s*AREA%s*:%s*(.-)%s*$")
        member = string.match(line, "^%s*[%-%*]%s*(.-)%s*$")
        rest = fresh
        if rest == nil then
            rest = known
        end
        if rest != nil then
            label, after = string.match(rest, "^(.-)%s*|%s*(.*)$")
            if label == nil then
                label, after = rest, nil
            end
            description, why = nil, nil
            if after != nil then
                description, why = string.match(after, "^(.-)%s*|%s*(.*)$")
                if description == nil then
                    description = after
                end
            end
            label = string.gsub(label, "^[\"'%s%*]+", "")
            label = string.gsub(label, "[\"'%.%s%*]+$", "")
            current = {label = string.sub(label, 1, 80), description = description, why = why,
                new = fresh != nil, members = {}}
            table.insert(areas, current)
        elseif member != nil and current != nil then
            member = string.gsub(member, "^[\"'%*]+", "")
            member = string.gsub(member, "[\"'%*]+$", "")
            current.members[string.lower(member)] = true
        end
    end
    return areas
end

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

function tag_broader.run(db_path, opts)
    lines = {}
    tags = tag_broader.specific_tags(db_path)
    if #tags < 4 then
        table.insert(lines, "Nothing to group: " .. #tags .. " tag(s)")
        return lines
    end
    library = tag_broader.library(db_path)
    by_label = {}
    entries = {}
    for _, entry in ipairs(library) do
        by_label[string.lower(entry.label)] = entry
        line = "- " .. entry.label
        if entry.description != nil and entry.description != "" then
            line = line .. ": " .. entry.description
        end
        table.insert(entries, line)
    end
    if #entries == 0 then
        table.insert(entries, "(empty: add new areas)")
    end
    listed = {}
    for _, t in ipairs(tags) do
        entry = "- " .. tostring(t.label)
        if t.description != nil and t.description != "" then
            entry = entry .. ": " .. t.description
        end
        table.insert(listed, entry)
    end
    answer, err = agent_provider.generate(nil, tag_upkeep.context() .. BROADER_PROMPT,
        "Library:\n" .. table.concat(entries, "\n") .. "\n\nTags:\n" .. table.concat(listed, "\n"))
    if answer == nil then
        table.insert(lines, "Stopped: " .. tostring(err))
        return lines
    end
    areas = tag_broader.parse(answer)
    if #areas == 0 then
        table.insert(lines, "Stopped: no area could be read from the agent's reply")
        return lines
    end
    for _, area in ipairs(areas) do
        area.entry = by_label[string.lower(area.label)]
        if area.entry != nil then
            area.new = false
            area.label = area.entry.label
            area.description = area.entry.description
        elseif area.new != true then
            area.new = true
            area.why = "(named as a library area, but not in the library)"
        end
    end
    group_of = {}
    for i, t in ipairs(tags) do
        for a, area in ipairs(areas) do
            if group_of[i] == nil and area.members[string.lower(tostring(t.label))] == true then
                group_of[i] = a
            end
        end
    end
    for i, t in ipairs(tags) do
        if group_of[i] == nil then
            a = broader_nearest(t, tags, group_of)
            if a == nil then
                a = 1
            end
            group_of[i] = a
            table.insert(lines, string.format("%q was left out; placed in %s, the nearest area", tostring(t.label), areas[a].label))
        end
    end

    used = {}
    for a, area in ipairs(areas) do
        members = {}
        for i, t in ipairs(tags) do
            if group_of[i] == a then
                table.insert(members, tostring(t.label))
            end
        end
        if #members > 0 then
            used[a] = true
            head = area.label
            if area.new then
                head = "NEW " .. head
            end
            table.insert(lines, string.format("%s (%d tags): %s", head, #members, table.concat(members, "; ")))
            if area.new then
                table.insert(lines, "    why new: " .. tostring(area.why))
            end
        end
    end
    picked = {}
    for a, area in ipairs(areas) do
        if used[a] == true and area.entry != nil then
            picked[area.entry.id] = true
        end
    end
    -- Keep broader areas referenced by human-placed tags active.
    hand = tag_broader.hand_placed(db_path)
    held = 0
    for _, parent in pairs(hand) do
        if tonumber(parent) != nil then
            picked[tonumber(parent)] = true
        end
        held = held + 1
    end
    if held > 0 then
        table.insert(lines, string.format("%d tag(s) placed by a person kept where they are", held))
    end
    unused = {}
    for _, entry in ipairs(library) do
        if entry.archived != true and picked[entry.id] != true then
            table.insert(unused, entry.label)
        end
    end
    if #unused > 0 then
        table.insert(lines, "no longer used: " .. table.concat(unused, "; "))
    end
    if opts.dry_run == true then
        count = 0
        for _, _ in pairs(used) do
            count = count + 1
        end
        table.insert(lines, string.format("Dry run: %d broad tags over %d tags, nothing written", count, #tags))
        return lines
    end

    author = "system"
    now = os.date("!%Y-%m-%d %H:%M:%S")
    written, created = 0, 0
    for a, area in ipairs(areas) do
        if used[a] == true then
            broad_id = nil
            if area.entry != nil then
                broad_id = area.entry.id
                if area.entry.archived then
                    entity.unarchive(db_path, "tag", broad_id, author)
                end
            else
                values = {label = area.label, source = "broader", computed_at = now}
                if area.description != nil and area.description != "" then
                    values.description = area.description
                end
                broad_id, issues = entity.create(db_path, "tag", values, author)
                if broad_id != nil then
                    created = created + 1
                    by_label[string.lower(area.label)] = {id = broad_id, label = area.label}
                end
            end
            if broad_id != nil then
                written = written + 1
                for i, t in ipairs(tags) do
                    if group_of[i] == a and tostring(t.parent) != tostring(broad_id) then
                        entity.update(db_path, "tag", t.id, {parent = tostring(broad_id)}, author, nil, "tag broaden")
                    end
                end
            else
                table.insert(lines, "could not write " .. tostring(area.label))
            end
        end
    end
    for _, entry in ipairs(library) do
        if entry.archived != true and picked[entry.id] != true then
            entity.archive(db_path, "tag", entry.id, author, nil, "tag broaden: no tag in this area")
        end
    end
    table.insert(lines, string.format("Wrote %d broad tags over %d tags (%d new to the library)", written, #tags, created))
    return lines
end

return tag_broader
