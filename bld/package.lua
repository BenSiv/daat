-- Declarative static build manifest for daat.
return {
    bin = "daat",
    entry = "main.lua",
    luam = "8c9bb857dd0b8c22b9f0dfad674130e0958ec240",
    with = {"sqlite3", "lfs", "bcrypt", "hmac", "crypto", "vec", "mariadb"},
    always_include = {"provider"},
}
