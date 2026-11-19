-- Unit tests for declarative structured config.lua & theme.lua validation,
-- typo suggestions, secret-key rejection, and source attribution.

config = require("config")
lfs = require("lfs")
unit = require("unit")

check = unit.check
tests = unit.suite()

function make_temp_dir()
    d = os.tmpname()
    os.remove(d)
    lfs.mkdir(d)
    return d
end

function write_text(path, content)
    f = assert(io.open(path, "w"))
    io.write(f, content)
    io.close(f)
end

function cleanup_dir(d)
    os.execute("rm -rf '" .. d .. "'")
end

function has_msg(list, needle)
    for _, msg in ipairs(list) do
        if string.find(msg, needle, 1, true) != nil then
            return true
        end
    end
    return false
end

function tests.absent_files_use_defaults()
    print("Testing absent config.lua and theme.lua validate cleanly with defaults")
    d = make_temp_dir()
    rep = config.validate(d)
    check(rep.ok == true, "absent config should be ok")
    check(rep.config_exists == false, "config_exists false")
    check(rep.theme_exists == false, "theme_exists false")
    check(#rep.errors == 0 and #rep.warnings == 0, "zero errors and warnings")
    check(rep.resolved.db_backend == "sqlite", "default db_backend is sqlite")
    check(rep.resolved.agent_thinking == "summary", "default agent_thinking is summary")
    check(rep.sources["database.backend"] == "default", "source is default")
    cleanup_dir(d)
end

function tests.structured_sections_resolve_and_track_sources()
    print("Testing all 7 structured sections resolve values, provider settings, and sources")
    d = make_temp_dir()
    write_text(d .. "/config.lua", """
return {
    database = {
        backend = "mariadb",
        host = "db.internal",
        port = 3307,
        user = "daat_app",
        database = "daat_prod",
    },
    agent = {
        provider = "vertex",
        model = "gemini-3.1-pro-preview",
        thinking = "full",
        max_turns = 30,
        retention = "lean",
        retention_override = {model_input_days = 7},
        vertex_project = "my-gcp-project",
        vertex_region = "global",
    },
    knowledge = {
        embedding_model = "text-embedding-005",
        embedding_skip = {"^> %*%*Source:"},
        build_aspects = true,
        search_aspects = true,
        tag_second_within = false,
        reference_aliases = {{"experiment%s*(%d)", "exp%1"}},
    },
    search = {
        provider = "google_cse",
    },
    mail = {
        provider = "smtp",
        from = "noreply@example.com",
        public_url = "https://daat.example.com",
        smtp_url = "smtp://smtp.example.com:587",
        smtp_user = "noreply@example.com",
    },
    ui = {
        nav_hidden = {"tasks"},
        adhoc_row_cap = 500,
    },
    extensions = {
        max_job_attempts = 8,
    },
}
""")
    rep = config.validate(d)
    check(rep.ok == true, "valid structured config should pass: " .. table.concat(rep.errors, "; "))
    check(#rep.warnings == 0, "valid complete config should emit 0 warnings: " .. table.concat(rep.warnings, "; "))
    check(rep.resolved.db_backend == "mariadb", "db_backend resolved")
    check(rep.resolved.mariadb_port == 3307, "mariadb_port resolved")
    check(rep.resolved.agent_provider == "vertex", "agent_provider resolved")
    check(rep.resolved.agent_max_turns == 30, "agent_max_turns resolved")
    check(rep.resolved.agent_retention == "lean", "agent_retention resolved")
    check(rep.resolved.model_input_days == 7, "retention_override applied")
    check(rep.resolved.tag_second_within == nil, "tag_second_within = false maps to nil")
    check(rep.resolved.adhoc_row_cap == 500, "ui.adhoc_row_cap resolved")
    check(rep.resolved.extension_max_job_attempts == 8, "extensions.max_job_attempts resolved")
    check(rep.settings.vertex_project == "my-gcp-project", "provider setting vertex_project captured")
    check(rep.settings.smtp_url == "smtp://smtp.example.com:587", "provider setting smtp_url captured")
    check(rep.sources["agent.max_turns"] == "config.lua", "overridden key source is config.lua")
    check(rep.sources["agent.turn_mode"] == "default", "untouched key source is default")
    cleanup_dir(d)
end

function tests.syntax_and_flat_key_and_typo_diagnostics()
    print("Testing syntax errors, misplaced flat keys, and Levenshtein typo suggestions")
    d = make_temp_dir()
    write_text(d .. "/config.lua", "return { agent = { provider = ")
    rep_syn = config.validate(d)
    check(rep_syn.ok == false, "syntax error fails validation")
    check(has_msg(rep_syn.errors, "syntax/evaluation error"), "reports syntax error")

    write_text(d .. "/config.lua", """
return {
    agent_provider = "ollama",
    databse = {},
    agent = {
        max_turn = 15,
        thinking = "loud",
    },
}
""")
    rep = config.validate(d)
    check(rep.ok == false, "invalid keys fail validation")
    check(has_msg(rep.errors, "move it under 'agent.provider'"), "guides flat key to agent.provider")
    check(has_msg(rep.errors, "did you mean section 'database'?"), "suggests section database")
    check(has_msg(rep.errors, "did you mean 'agent.max_turns'?"), "suggests agent.max_turns")
    check(has_msg(rep.errors, "'agent.thinking' must be one of {off, summary, full}"), "reports enum violation")
    cleanup_dir(d)
end

function tests.secret_keys_and_incomplete_groups_and_theme_validation()
    print("Testing secret-key detection, incomplete feature groups, and theme.lua validation")
    d = make_temp_dir()
    write_text(d .. "/config.lua", """
return {
    database = {
        backend = "mariadb",
        password = "do-not-commit-me",
    },
    mail = {
        provider = "smtp",
        smtp_password = "also-secret",
    },
}
""")
    write_text(d .. "/theme.lua", """
return {
    site_nam = "Lab",
    colors = {
        accnt = "#123456",
        bg = "not-a-color",
    },
}
""")
    rep = config.validate(d)
    check(rep.ok == false, "secrets and invalid keys fail validation")
    check(has_msg(rep.errors, "DAAT_MARIADB_PASSWORD"), "names DAAT_MARIADB_PASSWORD for database.password")
    check(has_msg(rep.errors, "DAAT_SMTP_PASSWORD"), "names DAAT_SMTP_PASSWORD for mail.smtp_password")
    check(has_msg(rep.errors, "database.user or database.database is missing"), "flags incomplete mariadb config")
    check(has_msg(rep.warnings, "mail.from or mail.public_url is missing"), "warns on incomplete mail config")
    check(has_msg(rep.errors, "did you mean 'site_name'?"), "suggests site_name in theme.lua")
    check(has_msg(rep.errors, "did you mean 'accent'?"), "suggests accent in theme.lua colors")
    check(has_msg(rep.warnings, "does not look like a hex/rgb/hsl color"), "warns on malformed theme color")
    cleanup_dir(d)
end

unit.run(tests)
