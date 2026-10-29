#!/bin/bash
# Rendered by Terraform (dev/demo/terraform/main.tf); runs as root on every boot.
set -euo pipefail

log() { echo "daat-startup: $*"; }

DATA=/opt/daat/data
SENTINEL="$DATA/.seeded"
IMAGE="${image}"

log "1. Docker and the Ops Agent"
if ! command -v docker > /dev/null; then
  apt-get update -y
  apt-get install -y --no-install-recommends docker.io
  systemctl enable --now docker
fi
if ! systemctl is-active --quiet google-cloud-ops-agent; then
  curl -fsSL https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh | bash -s -- --also-install
fi
# The container logs to journald (--log-driver below), so this one
# receiver carries Apache's logs and this script's into Cloud Logging.
cat > /etc/google-cloud-ops-agent/config.yaml <<'OPS'
logging:
  receivers:
    journald:
      type: systemd_journald
  service:
    pipelines:
      journald:
        receivers: [journald]
OPS
systemctl restart google-cloud-ops-agent

log "2. platform.lua"
mkdir -p "$DATA"
cat > "$DATA/platform.lua" <<'PLATFORM'
${platform_lua}
PLATFORM

log "3. Pulling $IMAGE"
gcloud auth configure-docker "$(echo "$IMAGE" | cut -d/ -f1)" --quiet
# Before the first build (dev/demo/README.md) the image doesn't exist yet:
# keep trying, so the VM comes up on its own once deploy.sh has pushed it.
until docker pull "$IMAGE"; do
  log "3. $IMAGE not pullable yet, retrying in 60s"
  sleep 60
done

log "4. Starting the container"
chown -R 33:33 "$DATA"
docker rm -f daat 2> /dev/null || true
docker run -d --name daat --restart always \
  --log-driver journald \
  -p 8000:8000 \
  -v "$DATA:/data" \
  "$IMAGE"
docker image prune -a -f
docker exec -u www-data daat cp /app/seed/theme.lua /data/theme.lua

log "5. Demo lab"
if [[ ! -f "$SENTINEL" ]]; then
  # Nothing but the seed itself can be in the store yet, so a seed
  # that failed partway is simply started over.
  rm -rf "$DATA/.store" "$DATA/schemas" "$DATA/facts.json"
  ADMIN_PASSWORD=$(gcloud secrets versions access latest --secret "${admin_password_secret}")
  if docker exec -u www-data -w /data daat /app/seed-demo-lab.sh "${demo_lab_seed}" \
      && docker exec -u www-data -w /data daat /app/bin/daat user add admin "$ADMIN_PASSWORD" isa; then
    touch "$SENTINEL"
    log "5. Seeded"
  else
    log "5. Seeding failed; it is retried on the next boot"
  fi
  unset ADMIN_PASSWORD
else
  log "5. Already seeded"
fi

log "6. Timers"
cat > /etc/systemd/system/daat-jobs.service <<'UNIT'
[Unit]
Description=daat background queues (agent turns, extensions, embeddings, curation)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker exec -u www-data -w /data daat /app/bin/daat agent run-pending-background
ExecStart=/usr/bin/docker exec -u www-data -w /data daat /app/bin/daat extension run-pending
ExecStart=/usr/bin/docker exec -u www-data -w /data daat /app/bin/daat document embed-pending
ExecStart=/usr/bin/docker exec -u www-data -w /data daat /app/bin/daat knowledge curate-pending 3
UNIT
cat > /etc/systemd/system/daat-jobs.timer <<'UNIT'
[Unit]
Description=Drain daat's background queues

[Timer]
OnBootSec=${jobs_interval}
OnUnitActiveSec=${jobs_interval}

[Install]
WantedBy=timers.target
UNIT
cat > /etc/systemd/system/daat-retention.service <<'UNIT'
[Unit]
Description=daat retention rules (store prune)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker exec -u www-data -w /data daat /app/bin/daat store prune
UNIT
cat > /etc/systemd/system/daat-retention.timer <<'UNIT'
[Unit]
Description=Apply daat's retention rules hourly

[Timer]
OnBootSec=1h
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now daat-jobs.timer daat-retention.timer

log "Done (${name})"
