-- `daat repair <name> [args]` -- rebuilds of state daat derives from its
-- own source-of-truth tables, kept out of the everyday command groups so
-- they don't crowd the CLI surface however many get added.
--
-- What belongs here: deterministic, idempotent, free to rerun at any
-- time, correct for any deployment -- the platform's own REINDEX. Every
-- write path already keeps this state current (entity.create/update's
-- document hooks), so a repair is only for recovery: a raw SQL insert, a
-- restored backup, a provider outage that dropped a best-effort
-- embedding. What doesn't: one-off migrations of a specific deployment's
-- data, or anything involving a model's judgment that should be reviewed
-- before it's written -- those live with the deployment, not here.
--
-- A new repair is one REPAIRS entry; `daat repair` with no name lists
-- them all.

document = require("document")
tag = require("tag")

repair = {}

function repair_links(cmd_args, db_path)
    entity_id = tonumber(cmd_args[2])
    if entity_id != nil then
        ok, err = document.resync_links(db_path, entity_id)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Resynced links for document #" .. tostring(entity_id))
        return
    end
    resynced = document.resync_all_links(db_path)
    print(string.format("Resynced links for %d document(s)", resynced))
end

function repair_embeddings(cmd_args, db_path)
    entity_id = tonumber(cmd_args[2])
    if entity_id != nil then
        ok, err = document.reindex_embedding(db_path, entity_id)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Reindexed embedding for document #" .. tostring(entity_id))
        return
    end
    reindexed, failed = document.reindex_all_embeddings(db_path)
    print(string.format("Reindexed %d document(s), %d failed", reindexed, failed))
end

function repair_pool_count(cmd_args, db_path)
    count = document.resync_pool_count(db_path)
    print("document_count resynced to " .. tostring(count))
end

-- With a document id, re-places that one document by nearest tag;
-- without, rebuilds every tag's centre from its memberships (after
-- `repair embeddings`, a raw SQL write, or a change of tag_dims).
function repair_tags(cmd_args, db_path)
    entity_id = tonumber(cmd_args[2])
    if entity_id != nil then
        chosen = tag.place_document(db_path, entity_id)
        if #chosen == 0 then
            print("Document #" .. tostring(entity_id) .. " not placed: no embedding, or no tags with a centre")
            return
        end
        names = {}
        for _, tag_id in ipairs(chosen) do
            table.insert(names, "#" .. tostring(tag_id))
        end
        print("Document #" .. tostring(entity_id) .. " is in tag " .. table.concat(names, ", "))
        return
    end
    tags, members = tag.rebuild_centres(db_path)
    print(string.format("Rebuilt %d tag centre(s) from %d membership(s)", tags, members))
end

function repair_tag_evidence(cmd_args, db_path)
    written = tag.refresh_evidence(db_path)
    print(string.format("Refreshed core tag evidence: %d row(s) written", written))
end

-- Ordered (a list, not a map) so `daat repair`'s listing is stable.
REPAIRS = {
    {name = "links", usage = "links [document_id]", run = repair_links,
     description = "Re-parse [[...]] links (and their context notes) from document content into document_link."},
    {name = "embeddings", usage = "embeddings [document_id]", run = repair_embeddings,
     description = "Recompute semantic-search embeddings (one embedding-provider call per document)."},
    {name = "tags", usage = "tags [document_id]", run = repair_tags,
     description = "Rebuild tag centres from memberships, or re-place one document by nearest tag."},
    {name = "tag-evidence", usage = "tag-evidence", run = repair_tag_evidence,
     description = "Recompute core tag evidence (link, connection) from links and memberships."},
    {name = "pool-count", usage = "pool-count", run = repair_pool_count,
     description = "Recount active documents into knowledge_pool_state.document_count."},
}

function repair.do_repair(cmd_args, db_path)
    name = cmd_args[1]
    for _, entry in ipairs(REPAIRS) do
        if entry.name == name then
            entry.run(cmd_args, db_path)
            return
        end
    end
    if name != nil then
        print("'" .. tostring(name) .. "' is not a repair")
    end
    print("Usage: daat repair <name> [args]")
    for _, entry in ipairs(REPAIRS) do
        print(string.format("  %-26s %s", entry.usage, entry.description))
    end
end

return repair
