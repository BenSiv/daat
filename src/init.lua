-- Initializes a deployment directory (.store/ and config-as-code folders).

const paths = require("paths")
const config = require("config")
const schema = require("schema")
const ledger = require("ledger")
const extension = require("extension")
const auth = require("auth")
const document = require("document")
const knowledge = require("knowledge")
const agent = require("agent")
const examples = require("examples")
const store_lib = require("store")

const init = {}

function describe_db_target(target)
    if type(target) == "table" then
        return target.host .. ":" .. tostring(target.port) .. "/" .. tostring(target.database)
    end
    return target
end

function has_with_examples_flag(cmd_args)
    for _, arg in ipairs(cmd_args) do
        if arg == "--with-examples" then
            return true
        end
    end
    return false
end

function report_examples_written(written)
    if #written == 0 then
        print("No example files written -- every example destination already exists.")
        return
    end
    print("Wrote " .. #written .. " example file(s):")
    for _, path in ipairs(written) do
        print("  " .. path)
    end
end

function has_help_flag(cmd_args)
    for _, arg in ipairs(cmd_args) do
        if arg == "-h" or arg == "--help" then
            return true
        end
    end
    return false
end

function init.do_init(cmd_args, root)
    if root == nil then
        root = "."
    end
    if has_help_flag(cmd_args) then
        print("Usage: daat init [--with-examples]")
        print("Initializes a Daat store in the current directory (.store/, schemas/, views/,")
        print("extensions/, templates/, dropdowns/). Pass --with-examples to also generate")
        print("working starter schemas, a saved view, an extension, a template, theme.lua,")
        print("and a documented config.lua.")
        return 0
    end
    with_examples = has_with_examples_flag(cmd_args)

    if config.is_initialized(root) then
        print("Already initialized: " .. describe_db_target(config.db_path(root)))
        if with_examples then
            report_examples_written(examples.write_all(root))
        end
        return 0
    end

    paths.create_dir_if_not_exists(config.store_dir(root))
    paths.create_dir_if_not_exists(config.schemas_dir(root))
    paths.create_dir_if_not_exists(config.extensions_dir(root))
    paths.create_dir_if_not_exists(config.views_dir(root))
    paths.create_dir_if_not_exists(config.templates_dir(root))
    paths.create_dir_if_not_exists(config.dropdowns_dir(root))

    db_path = config.db_path(root)
    -- A fresh store has nothing to migrate; this records it as current.
    store_lib.migrate(db_path)
    ledger.init_schema(db_path)
    schema.init_schema(db_path)
    extension.init_schema(db_path)
    auth.init_schema(db_path)
    document.init_schema(db_path)
    knowledge.init_schema(db_path)
    agent.init_schema(db_path)

    ok, err = auth.ensure_session_secret(root)
    if ok == nil then
        print("Warning: could not create session secret: " .. tostring(err))
    end

    if with_examples then
        report_examples_written(examples.write_all(root))
    end

    print("Initialized store at " .. config.store_dir(root))
    print("")
    print("Next steps:")
    print("  1. Create an admin account:  daat user add admin <password> isa")
    if with_examples then
        print("  2. Register & approve examples:")
        print("       daat schema sync")
        print("       daat view approve widgets-in-stock")
        print("       daat extension approve widget-quantity-range")
        print("  3. Check deployment health:  daat status")
        print("  4. Open in your browser:     daat serve")
    else
        print("  2. (Optional) Add starter examples: daat init --with-examples")
        print("  3. Check deployment health:         daat status")
        print("  4. Open in your browser:            daat serve")
    end
    return 0
end

return init
