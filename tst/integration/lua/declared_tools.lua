-- tst/integration/lua/declared_tools.lua
-- Prints the name of every tool agent.tool_declarations offers the chat
-- model, one per line, for the store in the current directory. Used by
-- the bats tests to check what the model is shown, not only what runs.

config = require("config")
agent = require("agent")

db_path = config.db_path(".")
for _, declaration in ipairs(agent.tool_declarations(db_path)) do
    print(declaration.name)
end
