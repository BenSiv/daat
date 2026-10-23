# Auth: how it's built and why

daat's login, session, CSRF and account-recovery code is its own, in `src/auth.lua` and the routes in `src/cgi.lua`. This page records what each piece does, why it is built that way, what was considered instead, and what is knowingly left open. `doc/architecture.md`'s "Auth" section is the short version; this is the one to read before changing any of it.

The ground rule: daat writes the policy (who may do what, when a credential stops working), never the cryptography. Every primitive comes from a vetted library through a thin binding.

## What it protects against

- **Someone with no account**, on the internet, trying to get in: guessing passwords, forging or replaying sessions, abusing the reset form.
- **A malicious website a logged-in user visits**, trying to act as that user: forged form posts (CSRF), framing daat's pages to trick clicks (clickjacking).
- **A network attacker** between the browser and daat, e.g. on public Wi-Fi, trying to read a session cookie.
- **A leaked database**: it must not contain anything that logs in directly (passwords, API keys, reset tokens).
- **A wrong or compromised mailbox**: emailed links must not hand over an account just because an address was mistyped.
- **An account that should no longer have access**: archived, demoted, or whose password was changed because it leaked.

Out of scope: someone with shell access to the server, or the session secret file itself. Either can do anything daat can.

## Passwords

- **bcrypt, cost 12**, via `luam/lib/bcrypt` (a binding over libxcrypt's `crypt_gensalt`/`crypt_r`, `$2b$` with a random salt from libxcrypt). bcrypt is slow on purpose, so a leaked hash costs real time per guess. Cost 12 is about a quarter of a second per hash: noticeable to an attacker running billions of guesses, invisible to a person logging in. Argon2 would be the modern pick, but bcrypt is what the system crypto library ships, is still considered safe, and needs no vendored code.
- **Verification is constant-time** in the binding (no early exit on the first differing byte).
- **An unknown login still runs bcrypt once** (`auth.login`), so how long a failed login takes doesn't reveal whether the login exists. The error text is the same either way for the same reason.
- **Invited accounts have no password at all** until the setup link is used: `password_hash` holds the marker `!no-password` (`NO_PASSWORD_HASH`), which bcrypt rejects as an invalid hash. An earlier version stored the hash of a random string instead. That logged in as nothing, but it also made "has this account ever had a password?" unanswerable, and the email-link rules below depend on that answer.

## Sessions

A session is a cookie, not a server-side row:

```
session = <login>.<expiry_unix>.<hmac>
hmac    = HMAC-SHA256(session_secret, "<login>.<expiry>.<session_version>")
```

- **HMAC-SHA256 via OpenSSL** (`luam/lib/hmac`), keyed by a 32-byte random secret generated once per deployment into `.store/session_secret`. The secret never leaves the server, so nobody can produce a valid signature, and changing any part of the cookie (another login, a later expiry) breaks it. Signatures are compared in constant time.
- **Why signed cookies rather than session rows.** daat runs as CGI: a fresh process per request, with no memory between requests. A session table would mean a database write at login and a lookup on every request, plus cleanup of expired rows. A signed cookie needs one HMAC and the user lookup that happens anyway for capabilities. The usual weakness of signed cookies is that they can't be revoked, which `session_version` below addresses.
- **Capabilities are not in the cookie.** Every request re-reads the account row, so archiving someone or removing a capability takes effect on their next request, not when the cookie expires.
- **`session_version` makes revocation possible.** It is a counter on the user row that the signature covers but the cookie doesn't carry. `auth.set_password` increments it on every route (`/account`, `/admin-users`, `daat user passwd`, a reset link), so every cookie issued before the change stops verifying. That is the point of changing a password that leaked: a stolen cookie must stop working too. `/account`, and an admin changing their own password, immediately re-issue the caller's cookie so they aren't logged out of the browser they're using.
  - Deploying this change logged everyone out once, because the signed message gained a field. That was accepted over keeping a second, older signature format alive.
- **Logins can't contain `.`**, because `.` separates the cookie's fields. The cookie signs the login exactly as stored, and `verify_session_cookie` requires an exact match. MySQL's default collation compares logins case-insensitively, so without that check a cookie for `ADMIN` would load the `admin` row.
- **Cookie attributes:** `HttpOnly` (page scripts, including any injected ones, can't read it), `SameSite=Lax` (not sent on cross-site POSTs, a second layer under CSRF tokens), `Path=/`, `Max-Age` of 7 days, and `Secure` whenever the request arrived over HTTPS (see Transport).
- `verify_session_cookie` returns the active user row, or nil. Expiry, signature, session_version and archived status are all checked in one place, so no route can check some of them and forget the rest.

## CSRF

Double-submit token: at login the server sets a random `csrf` cookie (readable by page scripts, on purpose), and every state-changing request must echo it back, either as the `X-CSRF-Token` header (fetch calls) or as a `csrf_token` form field (plain HTML forms). `require_csrf` compares the two in constant time.

- Why it works: another site can make the browser send daat's cookies, but it can't read them, so it can't put the matching value in the request.
- Why double-submit instead of a server-stored token: same reason as sessions, no per-request server state. The token doesn't need signing because it's only compared with itself.
- Every POST route in `cgi.lua` calls `require_csrf`. The exceptions are `/login`, `/forgot-password`, `/reset-password` and `/verify-email` (no session exists yet) and API-key requests (see below). When adding a route, add the check; `tst/integration/auth.bats` covers the pattern.

## Emailed links: reset, setup, verify

All three are one-time links to a page, stored in `password_reset`:

| Purpose | Who gets it | What it does | Lifetime |
|---|---|---|---|
| `reset` | A non-Admin with a **verified** address, from `/forgot-password` | Sets a new password | 1 hour |
| `setup` | A non-Admin **with no password yet** (invited) | Chooses the first password, verifies the address | 7 days |
| `verify` | An account **that already has a password**, when an admin sets its address | Verifies the address; asks for the current password; can't change it | 7 days |

Shared rules, and why:

- **The token is 32 random bytes and only its HMAC is stored**, so a leaked table can't be turned into working links. HMAC rather than bcrypt because the token is already high-entropy: there's nothing for a slow hash to protect, and a deterministic hash can be looked up directly.
- **The token travels in the URL fragment** (`#token=...`), which browsers never send to the server, so it can't land in Apache or load-balancer access logs. The page's script moves it into the form, which POSTs it. Those pages also send `Referrer-Policy: no-referrer` and `Cache-Control: no-store`.
- **The link's host comes from the configured `public_url`**, never the request's `Host` header. Otherwise an attacker could request a reset with their own Host header and get a link to their server mailed to the victim.
- **A link only works while the address it was sent to is still the account's address**, and changing or clearing an address voids every outstanding link (`void_account_links`). This closes the mistyped-address hole: an admin types `maya@celebste-bio.com`, notices, fixes it, and the stranger at the typo address is cut off. Both checks exist because either alone could be undone by a future change elsewhere.
- **Using any link voids all of that account's other links.**
- **Setting a password through a link ends all sessions** (via `set_password`).
- **`/forgot-password` answers the same whether or not anything matched**, is limited to one link per account per 5 minutes, and only mails verified addresses. A send failure is logged, never shown. Otherwise the form would reveal which logins and emails exist.

**Why `verify` is separate from `setup`.** Before this split, setting an email on any account mailed a link that could set the password. Whoever read that unverified, possibly mistyped, address could take over an existing account, an Admin's included. A `verify` link now needs the account's current password, so it proves two things: the reader has the mailbox, and the reader owns the account. Only then does the address become a place reset links can go.

## Admin accounts

An Admin (`a`) can manage every other account, so its recovery must not depend on one mailbox:

- **No reset links**, checked both when the link is issued and when it's used (an account promoted after a link went out can't use it).
- **No setup links**: `daat user invite ... a` and a setup link for a password-less Admin are both refused. An Admin is created with a password (`daat user add`), or invited without `a` and promoted once it has one.
- `verify` links are allowed: they need the Admin's password anyway.
- Another Admin resets a lost Admin password on `/admin-users`, or on the server with `daat user passwd`.

## Capabilities

Short letter strings on the account, checked per route: `i` baseline (everything a normal user does), `s` setup (`/sql`, `/system`), `a` admin (users, API keys, settings, triggers, `admin_write_only` types). See `doc/glossary.md`.

`/sql` needs `s` even though it only runs `SELECT`s. It can read every table, including `user` (password hashes, emails), `api_key`, `password_reset` and other people's chat history. The chat agent's query tool is limited to registered entity tables (`view.run_agent_query`) because a model's SQL can be steered by prompt injection. The `/sql` console instead relies on who is allowed to open it.

## API keys

For scripts and other systems: `X-Api-Key: <key>` on each request, no cookie, so no CSRF check (CSRF needs a credential the browser attaches by itself; nothing attaches this header automatically). Keys are 32 random bytes, shown once, stored as bcrypt hashes, with their own capabilities and archive flag. `X-Api-Key` rather than `Authorization: Bearer` because Apache's mod_cgid doesn't pass `Authorization` to CGI scripts without extra config.

Known cost: a key is checked by running bcrypt against every active key (there's nothing to look it up by). That's fine for a handful of keys, but it means any request carrying the header, even a bogus one, costs one bcrypt per key (see Known gaps).

## Transport

- **Production terminates TLS at the Google load balancer** and forwards plain HTTP to Apache on port 8000. Apache therefore doesn't set the CGI `HTTPS` variable by itself. The lims deployment's `apache-platform.conf` sets `SetEnv HTTPS on` because every real request reached the load balancer over HTTPS (port 80 only redirects).
- With `HTTPS` set, cookies get `Secure` (never sent over plain HTTP) and responses carry `Strict-Transport-Security: max-age=31536000`. HSTS makes the browser go straight to HTTPS for a year, so even typing the bare hostname never produces a plain-HTTP request that would carry the cookie. Before this, the cookie had no `Secure` flag in production, and the first request to `http://...` (before the redirect) sent it unencrypted.
- **Why the `HTTPS` env var and not `X-Forwarded-Proto`:** a forwarded header can be supplied by the client unless the proxy strips it, while an Apache `SetEnv` can't be influenced by a request. Local development over plain HTTP still works because nothing sets the variable there.

## Response headers

`print_response` adds these to every response (`security_header_lines` in `cgi.lua`). A route can override one by setting the same header itself.

- **`Content-Security-Policy`**, which tells the browser what the page may load and run:
  - `script-src 'self' 'nonce-<per-request>'`: only daat's own script files and inline `<script>` blocks carrying this request's random nonce run. Every inline script daat writes carries it. An injected `<script>` or `onclick=` doesn't, so an escaping bug can't become running code. This is the important line. daat generated nonces before but stopped sending a CSP when the Fossil wrapper (which used to send one) was removed, so for a while the nonces protected nothing.
  - `style-src 'self' 'unsafe-inline'`: daat's markup uses inline `style=""` throughout. Inline styles can't run code, so allowing them costs little.
  - `img-src 'self' data: blob: https:`: documents can embed images from the web, and the bundled editor uses `data:` images.
  - `connect-src 'self' http://127.0.0.1:9100 https://127.0.0.1:9101`: page scripts may only call daat itself and the label printer's local Zebra Browser Print service. This also blocks the Google Analytics call the Toast UI editor makes by default (also switched off with `usageStatistics: false`).
  - `frame-ancestors 'self'`: other sites can't frame daat (clickjacking). `'self'` rather than `'none'` because daat embeds its own pages in same-origin iframes (a registration table inside a document, `/sql?embed=1`).
  - `form-action 'self'`, `object-src 'none'`, `default-src 'self'`: close the remaining ways to send form data elsewhere or load plugins. `base-uri 'self'` (not `'none'`): every page sets `<base href="/">`, which its relative links depend on, so only an injected `<base>` pointing elsewhere is blocked.
- **`X-Frame-Options: SAMEORIGIN`**: the older form of `frame-ancestors`, for browsers that predate it.
- **`X-Content-Type-Options: nosniff`**: the browser uses the declared content type instead of guessing, so a served file can't be reinterpreted as script.
- **`Referrer-Policy: same-origin`**: daat URLs (entity ids, search terms) aren't sent to other sites when someone follows a link out.
- **`Strict-Transport-Security`**: see Transport.

## SQL quoting

Values are put into SQL with `db.quote`, which doubles single quotes. That is only safe if backslash is an ordinary character. MySQL/MariaDB's default mode treats it as an escape character, so a value like `\' OR '1'='1` would end the string early. luam's MariaDB adapter turns on `NO_BACKSLASH_ESCAPES` for every connection and **refuses the connection unless it reads the flag back** (`database_adapter.get_mariadb_connection`). A request then fails instead of running with quoting that can be broken. This matters for auth because the login form passes an unauthenticated user's input straight into `db.quote`. SQLite never treats backslash specially.

## Known gaps

Deliberately not done yet, in rough priority order:

1. **No limit on login attempts.** bcrypt makes each guess slow, but there's no lockout or growing delay per login or per IP.
2. **No minimum password length.** Any non-empty password is accepted.
3. **API-key checks cost one bcrypt per active key**, even for a bogus key from an anonymous caller. The fix is a key format with a lookup part (`<label>.<secret>`) or storing an HMAC instead of bcrypt (keys are random, so bcrypt adds nothing).
4. **`/login` has no CSRF token**, so another site could log a visitor into an account of the attacker's choosing.
5. **The session secret file is created with the default umask** (usually 0644). Only the container can read it, but it should be 0600.
6. **No "log out everywhere" button.** Changing the password does the same thing.
7. **bcrypt only uses the first 72 bytes** of a password.

## Changing this code

- New POST route: call `require_csrf` (unless it's API-key only), and add a test like the ones in `tst/integration/auth.bats`.
- New way to change a password: go through `auth.set_password`, so sessions end.
- New way to change an email: go through `auth.set_email`, so links are voided.
- New inline `<script>`: give it `nonce="%s"` with the page's nonce, or it won't run. Inline event handlers (`onclick=`) never run; attach listeners from a nonce'd script.
- New external resource (CDN, API called from the browser): widen the CSP in `security_header_lines` deliberately and note why here.
- Never put capabilities or anything secret in a cookie.
