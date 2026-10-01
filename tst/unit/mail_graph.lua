-- tst/unit/mail_graph.lua
-- Unit tests for src/provider/mail_graph.lua with external_tool.capture
-- stubbed out -- no network. The stub reads the curl -K config files the
-- provider writes (they still exist while capture runs), so these check
-- the real token request and sendMail call, and that neither the client
-- secret nor the bearer token ever reaches a command line.

config = require("config")
external_tool = require("external_tool")
mail_graph = require("provider.mail_graph")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function contains(haystack, needle)
    return string.find(tostring(haystack), needle, 1, true) != nil
end

function read_file(path)
    file = io.open(path, "rb")
    if file == nil then
        return nil
    end
    content = io.read(file, "*all")
    io.close(file)
    return content
end

CONF = {graph_tenant_id = "celleste-bio.com", graph_client_id = "11111111-2222-3333-4444-555555555555"}
config.platform_config = function() return CONF end

SECRET = "s3cret-value"
real_getenv = os.getenv
os.getenv = function(name)
    if name == "PLATFORM_GRAPH_CLIENT_SECRET" then
        return SECRET
    end
    return real_getenv(name)
end

-- Each call records {cmd, config, message}; responses come from
-- TOKEN_RESPONSE / SEND_RESPONSE, chosen by the config's url line.
CALLS = {}
TOKEN_RESPONSE = "{\"access_token\":\"tok-abc\",\"token_type\":\"Bearer\"}\nhttp_status=200"
SEND_RESPONSE = "\nhttp_status=202"
external_tool.capture = function(cmd)
    config_path = string.match(cmd, "%-K '([^']+)'")
    message_path = string.match(cmd, "^base64 %-w0 '([^']+)'")
    call = {cmd = cmd, config = read_file(config_path), message = nil}
    if message_path != nil then
        call.message = read_file(message_path)
    end
    table.insert(CALLS, call)
    if contains(call.config, "/oauth2/v2.0/token") then
        return TOKEN_RESPONSE
    end
    return SEND_RESPONSE
end

function reset()
    CALLS = {}
    TOKEN_RESPONSE = "{\"access_token\":\"tok-abc\",\"token_type\":\"Bearer\"}\nhttp_status=200"
    SEND_RESPONSE = "\nhttp_status=202"
    SECRET = "s3cret-value"
    CONF = {graph_tenant_id = "celleste-bio.com", graph_client_id = "11111111-2222-3333-4444-555555555555"}
end

MESSAGE = {from_address = "noreply@example.com", raw = "From: \"LIMS\" <noreply@example.com>\r\nTo: <a@example.com>\r\nSubject: Hi\r\n\r\nBody"}

function test_send_gets_a_token_then_posts_the_raw_message()
    print("Testing send fetches a client-credentials token, then posts message.raw to the sender's sendMail")
    reset()
    ok, err = mail_graph.send(MESSAGE)
    check(ok == true, "expected success, got: " .. tostring(err))
    check(#CALLS == 2, "expected 2 curl calls (token, send), got " .. tostring(#CALLS))
    token_call, send_call = CALLS[1], CALLS[2]
    check(contains(token_call.config, "https://login.microsoftonline.com/celleste-bio.com/oauth2/v2.0/token"), "token URL should use the tenant")
    check(contains(token_call.config, "grant_type=client_credentials"), "client-credentials grant expected")
    check(contains(token_call.config, "client_id=11111111-2222-3333-4444-555555555555"), "client id expected")
    check(contains(token_call.config, "client_secret=" .. SECRET), "client secret expected in the token config file")
    check(contains(token_call.config, "scope=https://graph.microsoft.com/.default"), "Graph .default scope expected")
    check(contains(send_call.config, "https://graph.microsoft.com/v1.0/users/noreply@example.com/sendMail"), "sendMail URL should be the sender's mailbox")
    check(contains(send_call.config, "Authorization: Bearer tok-abc"), "bearer token expected in the send config file")
    check(contains(send_call.config, "Content-Type: text/plain"), "MIME send needs Content-Type: text/plain")
    check(send_call.message == MESSAGE.raw, "the raw message should be what gets base64'd and posted")
    check(contains(send_call.cmd, "--data-binary @-"), "body should come from the base64 pipe")
end

function test_no_secret_or_token_on_the_command_line()
    print("Testing neither the client secret nor the bearer token appears in any command line")
    reset()
    mail_graph.send(MESSAGE)
    for _, call in ipairs(CALLS) do
        check(not contains(call.cmd, SECRET), "client secret leaked into a command line: " .. call.cmd)
        check(not contains(call.cmd, "tok-abc"), "bearer token leaked into a command line: " .. call.cmd)
    end
end

function test_token_error_is_reported()
    print("Testing a token endpoint error surfaces its code and description, and nothing is sent")
    reset()
    TOKEN_RESPONSE = "{\"error\":\"invalid_client\",\"error_description\":\"AADSTS7000215: Invalid client secret provided.\"}\nhttp_status=401"
    ok, err = mail_graph.send(MESSAGE)
    check(ok == nil, "expected failure")
    check(contains(err, "HTTP 401") and contains(err, "AADSTS7000215"), "expected the token error detail, got: " .. tostring(err))
    check(#CALLS == 1, "no sendMail call after a failed token request")
end

function test_send_error_is_reported()
    print("Testing a sendMail error (e.g. the app isn't allowed this mailbox) surfaces Graph's code and message")
    reset()
    SEND_RESPONSE = "{\"error\":{\"code\":\"ErrorAccessDenied\",\"message\":\"Access is denied.\"}}\nhttp_status=403"
    ok, err = mail_graph.send(MESSAGE)
    check(ok == nil, "expected failure")
    check(contains(err, "HTTP 403") and contains(err, "ErrorAccessDenied"), "expected Graph's error detail, got: " .. tostring(err))
end

function test_missing_secret_and_bad_ids_fail_before_any_call()
    print("Testing a missing secret or an unsafe tenant/client id fails before curl runs")
    reset()
    SECRET = ""
    ok, err = mail_graph.send(MESSAGE)
    check(ok == nil and contains(err, "PLATFORM_GRAPH_CLIENT_SECRET"), "expected missing-secret error, got: " .. tostring(err))
    reset()
    CONF.graph_tenant_id = "evil.com/x?y="
    ok, err = mail_graph.send(MESSAGE)
    check(ok == nil and contains(err, "graph_tenant_id"), "expected invalid-tenant error, got: " .. tostring(err))
    reset()
    CONF.graph_client_id = nil
    ok, err = mail_graph.send(MESSAGE)
    check(ok == nil and contains(err, "graph_client_id"), "expected missing-client-id error, got: " .. tostring(err))
    check(#CALLS == 0, "no curl call for a config error")
end

test_send_gets_a_token_then_posts_the_raw_message()
test_no_secret_or_token_on_the_command_line()
test_token_error_is_reported()
test_send_error_is_reported()
test_missing_secret_and_bad_ids_fail_before_any_call()

if FAILURES > 0 then
    print(tostring(FAILURES) .. " failure(s)")
    os.exit(1)
end
print("All mail_graph tests passed")
