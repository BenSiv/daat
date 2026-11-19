-- CLI dispatcher for `daat tag <merge|build|broaden|library|define>`,
-- kept separate from tag_upkeep so tag_build, tag_define, and tag_broader
-- depend on tag_upkeep one-way without a cycle back.

const entity = require("entity")
const tag_upkeep = require("tag_upkeep")
const tag_build = require("tag_build")
const tag_define = require("tag_define")
const tag_broader = require("tag_broader")

const tag_cli = {}

function tag_cli.do_tag(cmd_args, db_path)
    usage = "Usage: daat tag merge <into_id> <from_id>... [--label <label>] [--description <text>]\n" ..
        "       daat tag build [--dry-run [--name]] [--replace] [--max-tags N] [--coarseness C]\n" ..
        "       daat tag broaden [--dry-run]\n" ..
        "       daat tag library [add \"<label>\" [\"<description>\"]]\n" ..
        "       daat tag define [--dry-run] [--limit N] [--recheck]"
    if cmd_args[1] == "build" then
        flags = {}
        max_tags = nil
        coarseness = nil
        for i = 2, #cmd_args do
            flags[cmd_args[i]] = true
            if cmd_args[i] == "--max-tags" then
                max_tags = tonumber(cmd_args[i + 1])
            end
            if cmd_args[i] == "--coarseness" then
                coarseness = tonumber(cmd_args[i + 1])
            end
        end
        tag_build.run(db_path, {dry_run = flags["--dry-run"] == true, name = flags["--name"] == true,
            replace = flags["--replace"] == true, max_tags = max_tags, coarseness = coarseness})
        return
    end
    if cmd_args[1] == "define" then
        dry_run, limit, recheck = false, nil, false
        for i = 2, #cmd_args do
            if cmd_args[i] == "--dry-run" then
                dry_run = true
            elseif cmd_args[i] == "--recheck" then
                recheck = true
            elseif cmd_args[i] == "--limit" then
                limit = tonumber(cmd_args[i + 1])
            end
        end
        for _, line in ipairs(tag_define.repair(db_path, limit, dry_run, "system", recheck)) do
            print(line)
        end
        return
    end
    if cmd_args[1] == "broaden" then
        flags = {}
        for i = 2, #cmd_args do
            flags[cmd_args[i]] = true
        end
        for _, line in ipairs(tag_broader.run(db_path, {dry_run = flags["--dry-run"] == true})) do
            print(line)
        end
        return
    end
    if cmd_args[1] == "library" then
        if cmd_args[2] == "add" then
            if cmd_args[3] == nil or cmd_args[3] == "" then
                print("Usage: daat tag library add \"<label>\" [\"<description>\"]")
                return
            end
            id, err = tag_broader.library_add(db_path, cmd_args[3], cmd_args[4], "system")
            if id == nil then
                print("Not added: " .. tostring(err))
            else
                print(string.format("Added %q to the library (tag #%d, not in use yet)", cmd_args[3], id))
            end
            return
        end
        for _, entry in ipairs(tag_broader.library(db_path)) do
            state = "in use"
            if entry.archived then
                state = "not in use"
            end
            line = string.format("#%d %s (%s)", entry.id, entry.label, state)
            if entry.description != nil and entry.description != "" then
                line = line .. ": " .. entry.description
            end
            print(line)
        end
        return
    end
    if cmd_args[1] != "merge" then
        print(usage)
        return
    end
    into = tonumber(cmd_args[2])
    from, values = {}, {}
    i = 3
    while i <= #cmd_args do
        if cmd_args[i] == "--label" or cmd_args[i] == "--description" then
            values[string.sub(cmd_args[i], 3)] = cmd_args[i + 1]
            i = i + 2
        else
            table.insert(from, tonumber(cmd_args[i]))
            i = i + 1
        end
    end
    if into == nil or #from == 0 then
        print(usage)
        return
    end
    tag_upkeep.init_schema(db_path)
    ids = {[into] = true}
    for _, id in ipairs(from) do
        if id == nil or id == into or entity.get(db_path, "tag", id) == nil then
            print(usage)
            return
        end
        ids[id] = true
    end
    if entity.get(db_path, "tag", into) == nil then
        print("No such tag: #" .. tostring(into))
        return
    end
    if values.label != nil and tag_upkeep.label_taken(db_path, values.label, ids) then
        print("Another tag already has the label " .. values.label)
        return
    end
    author = os.getenv("USER")
    for _, id in ipairs(from) do
        moved, deduplicated = tag_upkeep.merge(db_path, into, id, author, "merged into #" .. into)
        print(string.format("Merged #%d into #%d: %d memberships moved, %d already on #%d", id, into, moved, deduplicated, into))
    end
    if next(values) != nil then
        entity.update(db_path, "tag", into, values, author, nil, "merged")
    end
    tag_upkeep.rebaseline(db_path, {into})
    row = entity.get(db_path, "tag", into)
    print(string.format("#%d %q", into, row.label))
end

return tag_cli
