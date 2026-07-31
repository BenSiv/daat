-- Label printing: renders a ZPL string for one entity row, ready to
-- hand to a Zebra printer via the client-side Browser Print SDK (see
-- html.lua/cgi.lua's own pieces of this feature, and doc/schema.md's
-- own "Label printing" section for the full design).
--
-- The template itself is a real, user-created, ledgered entity row
-- (schemas/label_template.lua), not a config file -- so "editing a
-- label template" is exactly as auditable as editing a sample, with no
-- separate approval/registry mechanism needed (see that schema's own
-- header comment for why). What IS reused from view.lua: the same
-- select-only SQL safety check and the same dual-backend parameterized
-- query runner (view.run_sql) -- a label_template row's `sql` field is
-- genuinely just a single-parameter view, structurally.

db = require("db")
view = require("view")

label = {}

-- ZPL's own command-prefix characters -- a substituted field value
-- containing either one unescaped would corrupt the label (e.g. break
-- out of a ^FD...^FS field-data block or start a new command
-- mid-value). There's no standard ZPL string-escaping convention (ZPL
-- has no quoting), so the safe move is stripping them from substituted
-- values entirely rather than trying to encode them.
function escape_zpl(value)
    text = tostring(value)
    text = string.gsub(text, "%^", "")
    text = string.gsub(text, "~", "")
    return text
end

-- Finds the one label_template row for this entity_type, if any.
-- entity_type here is always an already-registered schema name (the
-- caller's own /detail-route type= param, the same trust level every
-- other entity_type use in cgi.lua already has), not raw free text.
function find_template(db_path, entity_type)
    if db.table_exists(db_path, "label_template") == false then
        return nil
    end
    -- `sql` is a reserved word in MariaDB (fine on SQLite, which has no
    -- such restriction) -- quoted as an identifier so this runs on both
    -- backends.
    rows = db.query(db_path, string.format(
        "SELECT %s, zpl FROM label_template WHERE for_entity_type = %s AND archived_at IS NULL LIMIT 1;",
        db.quote_ident("sql"), db.quote(entity_type)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

-- Whether entity_type has a label template at all -- how the /detail
-- route decides whether to show a "Print Label" button.
function label.has_template(db_path, entity_type)
    return find_template(db_path, entity_type) != nil
end

-- Substitutes every {{column_name}} token in zpl_template from
-- values (a plain {column_name = value} table, the shape view.run_sql
-- already returns). A token with no matching column is left as-is
-- (rather than silently blanked), so a typo'd token name is visible on
-- the printed label instead of just disappearing.
function substitute_tokens(zpl_template, values)
    return string.gsub(zpl_template, "{{([%w_]+)}}", function(name)
        if values[name] == nil then
            return "{{" .. name .. "}}"
        end
        return escape_zpl(values[name])
    end)
end

function label.render(db_path, entity_type, entity_id)
    template = find_template(db_path, entity_type)
    if template == nil then
        return nil, "no label template for " .. tostring(entity_type)
    end

    -- Defense in depth -- entity.validate already rejected anything
    -- but a plain SELECT when this row was saved, but storage is never
    -- trusted alone (matches view.run_sql's own re-check on every
    -- call).
    if view.is_select_only(template.sql) == false then
        return nil, "label template's sql is not a plain SELECT"
    end

    rows, err = view.run_sql(db_path, template.sql, "integer", entity_id)
    if err != nil then
        return nil, err
    end
    if rows == nil or rows[1] == nil then
        return nil, "no matching " .. tostring(entity_type) .. " row for id " .. tostring(entity_id)
    end

    return substitute_tokens(template.zpl, rows[1])
end

return label
