-- A deterministic, network-free mail backend for tests -- selected the
-- same way search_test.lua is (platform.lua's mail_provider = "test").
-- Appends each message as one JSON line to the file named by
-- MAIL_TEST_OUTBOX, so a bats test can read back exactly what would
-- have been sent (recipient, subject, body, and the full raw message)
-- instead of standing up a real SMTP server.

json = require("dkjson")

mail_test = {}

function mail_test.send(message)
    outbox = os.getenv("MAIL_TEST_OUTBOX")
    if outbox == nil or outbox == "" then
        return nil, "no outbox for the test mail provider (set MAIL_TEST_OUTBOX)"
    end
    file = io.open(outbox, "a")
    if file == nil then
        return nil, "cannot open MAIL_TEST_OUTBOX: " .. outbox
    end
    io.write(file, json.encode({to = message.to, from = message.from_address, subject = message.subject, body = message.body, raw = message.raw}) .. "\n")
    io.close(file)
    return true
end

return mail_test
