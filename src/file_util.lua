-- Reading a whole file into a string was copy-pasted, identically
-- byte-for-byte, into extension.lua, view.lua, and template.lua --
-- three separate `read_file` locals with no shared home (Luam's own
-- `paths` module only has path-joining/dir-existence helpers, nothing
-- that reads file contents). One shared definition instead.

file_util = {}

function file_util.read(path)
    file = io.open(path, "r")
    if file == nil then
        return nil
    end
    source = io.read(file, "*all")
    io.close(file)
    return source
end

return file_util
