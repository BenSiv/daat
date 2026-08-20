# Data durability & recovery plan

## Current state (updated 2026-07-25 -- production moved off SQLite)

Production now runs on managed Cloud SQL for MySQL, not a single SQLite file on the boot disk. This doc originally described a SQLite-era plan (Litestream/backup-cron, still relevant to a from-source/dev SQLite install); see `doc/mariadb-migration.md` Phase 4 for how and when the cutover happened, and `doc/architecture.md`'s "Storage" section for the current dual-backend picture (`src/db.lua` dispatches on `config.db_backend()`).

For a **from-source or local dev install still running SQLite** (`.store/store.db`, single file, no network binding), the original problem statement and Phases 1-3 below still apply as-is. For **production**, most of what those phases exist to provide is already covered by Cloud SQL itself:

- **Automated backups + PITR**, configured directly in Terraform (`/root/software/infra/gcp/lims/main.tf`, `google_sql_database_instance.platform.settings.backup_configuration`): daily backups (`enabled = true`, `start_time = "03:00"`), `binary_log_enabled = true` (binlogs are what make point-in-time recovery possible, not just daily-snapshot granularity), 14 retained backups (`retained_backups = 14`, count-based, not day-based). This closes the RPO gap Phase 1 below was written to solve -- Cloud SQL's own binlog-based PITR gives sub-day recovery for free, no Litestream/cron needed.
- **Managed failover primitives**: `availability_type = "ZONAL"` today (single zone, matching the single-instance `platform` GCE VM it serves) -- regional HA is a one-line Terraform change (`availability_type = "REGIONAL"`) if that tradeoff is ever revisited, not a re-architecture.
- The old SQLite file is kept, untouched, on the instance as a rollback artifact only (per mariadb-migration.md Phase 4) -- it is not the live source of truth and does not need its own backup plan going forward.

**What Cloud SQL's baseline still does NOT give you** (same shape of gap as the old SQLite plan, just smaller in scope now):

1. **No tested restore runbook** -- nobody has actually run a Cloud SQL PITR/backup restore against this instance. A backup no one has restored from is still a hypothesis. Phase 2 below (rewritten for Cloud SQL) is still open work.
2. **Single instance, single zone actually serving traffic** -- a zone outage is still real downtime until `availability_type` is changed or a replacement instance is provisioned, same as before.
3. **No verified application-level integrity check on restore** -- a restored database being reachable isn't the same as its data being correct; nothing here confirms the ledger and its projected tables still agree post-restore.

## Recommended plan (phased, cheapest/highest-value first)

### Phase 1 -- SQLite dev/from-source installs only (Cloud SQL already covers prod)

If running from source against SQLite (no `db_backend: "mariadb"` in `platform.lua`), the original plan still applies: switch to WAL mode (`PRAGMA journal_mode=WAL;`) and either run [Litestream](https://litestream.io/) or a systemd timer doing `sqlite3 store.db ".backup /tmp/backup.db"` + upload on an interval. Not relevant to production anymore -- skip straight to Phase 2 there.

### Phase 2 -- Documented, tested restore runbook (still open)

For production (Cloud SQL): pick a throwaway/staging Cloud SQL instance, actually run a PITR restore (`gcloud sql backups restore` or a clone-to-point-in-time) against it, point a `platform` container at the restored instance's connection name, and confirm:

1. The app starts and login works.
2. A spot-check of known records/ledger entries survived intact.
3. `daat ledger verify`-style integrity check (if one doesn't exist yet, a small CLI addition) walks the ledger and confirms every projected table still matches its log -- so a restored backup's integrity is machine-checked, not just "app started successfully."
4. Time the whole thing -- that duration is the real RTO, not a guess.

Write the actual steps taken down in this section once run for real.

### Not recommended (for now)

- **Multi-zone hot standby / automatic failover** -- meaningful added complexity (replication lag, split-brain handling) that a single-company internal LIMS tool likely doesn't need; `availability_type = REGIONAL` (a much smaller step, see above) plus a drilled restore runbook (Phase 2) is probably the right tradeoff point unless an explicit uptime SLA says otherwise. Revisit if that changes.

## Critical files
- `/root/software/infra/gcp/lims/main.tf` -- `google_sql_database_instance.platform`, its `backup_configuration` block, instance tier/zone
- `/root/software/infra/gcp/lims/module/platform_compute/templates/startup-platform.sh.tpl` -- where the app's DB connection is configured (seeds `platform.lua`'s `db_backend`, Cloud SQL Auth Proxy sidecar)
- `/root/projects/daat/src/db.lua` -- backend dispatch (`is_mariadb()`); where a `PRAGMA journal_mode=WAL` call would be added for the SQLite dev path
- `/root/projects/daat/doc/mariadb-migration.md` -- the full cutover history/rationale
- `/root/projects/daat/doc/architecture.md` -- "Storage" section, current dual-backend picture
