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

-- Ordered (a list, not a map) so `daat repair`'s listing is stable.
REPAIRS = {
    {name = "links", usage = "links [document_id]", run = repair_links,
     description = "Re-parse [[...]] links (and their context notes) from document content into document_link."},
    {name = "embeddings", usage = "embeddings [document_id]", run = repair_embeddings,
     description = "Recompute semantic-search embeddings (one embedding-provider call per document)."},
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
