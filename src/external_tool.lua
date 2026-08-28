-- Shared shape behind every "shell out to an external binary" call
-- site in this codebase (cmark-gfm, pdftotext/pandoc, curl against the
-- Claude/Vertex APIs and Google's Search API, gcloud for an access
-- token) -- previously each call site hand-rolled its own copy of
-- shell_quote plus the same tmpname/write/popen/read/remove sequence,
-- with no shared place to fix or improve it once. This is that place:
-- a small, deployment-agnostic layer between the platform's own code
-- and the third-party tools it happens to shell out to, not a plugin
-- system -- these are vetted, first-party integrations the platform
-- always ships with, just no longer duplicated five times over.
--
-- Every caller still owns its own command string and decides its own
-- error-handling contract (some return nil+err, document.render_markdown
-- still falls back to "" on failure) -- this only owns the parts that
-- were genuinely identical everywhere: quoting, temp-file lifecycle,
-- and capturing a command's stdout.

external_tool = {}

function external_tool.shell_quote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- Runs `cmd` (a fully-built shell command string -- every interpolated
-- value already shell_quote'd by the caller) and returns all of its
-- stdout, or nil, err if the popen itself failed or produced no
-- output. stderr is never captured -- a caller that wants it
-- suppressed adds " 2>/dev/null" to `cmd` itself, the same way every
-- migrated call site here already does.
function external_tool.capture(cmd)
    handle = io.popen(cmd, "r")
    output = nil
    if handle != nil then
        output = io.read(handle, "*all")
        io.close(handle)
    end
    if output == nil or output == "" then
        return nil, "no output"
    end
    return output
end

-- True if `binary` resolves on PATH. Lets a caller check up front for
-- a clean, specific "X is not installed" error instead of io.popen's
-- underlying shell silently reporting "command not found" on stderr
-- (never captured) while stdout comes back empty or garbled.
function external_tool.available(binary)
    found, _ = external_tool.capture("command -v " .. external_tool.shell_quote(binary) .. " 2>/dev/null")
    return found != nil
end

-- Writes `content` to a fresh temp file (`mode` "w" or "wb"), calls
-- `fn(tmp_path)` -- which should itself return (result, err), the same
-- convention every function here follows -- and unconditionally
-- removes the temp file afterward, on success or failure alike.
function external_tool.with_temp_file(content, mode, fn)
    tmp_path = os.tmpname()
    file = io.open(tmp_path, mode)
    if file == nil then
        return nil, "could not create a temp file"
    end
    io.write(file, content)
    io.close(file)

    result, err = fn(tmp_path)
    os.remove(tmp_path)
    return result, err
end

return external_tool
