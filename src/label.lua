-- Renders ZPL labels from ledgered label_template rows via view.run_sql (see doc/schema.md).

const db = require("database")
const view = require("view")

const label = {}

-- Strip ZPL command prefixes (^ and ~) since ZPL has no string quoting.
function escape_zpl(value)
    text = tostring(value)
    text = string.gsub(text, "%^", "")
    text = string.gsub(text, "~", "")
    return text
end

function find_template(db_path, entity_type)
    if db.table_exists(db_path, "label_template") == false then
        return nil
    end
    -- "sql" is a reserved identifier in MariaDB.
    rows = db.query(db_path, string.format(
        "SELECT %s, zpl FROM label_template WHERE for_entity_type = %s AND archived_at IS NULL LIMIT 1;",
        db.quote_ident("sql"), db.quote(entity_type)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

function label.has_template(db_path, entity_type)
    return find_template(db_path, entity_type) != nil
end

-- Unknown {{column}} tokens stay literal so typos surface on the label.
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
