# syntax=docker/dockerfile:1.4
# Demo deployment image: daat built from this checkout (not a fresh
# GitHub clone), so whatever branch you build is what gets deployed.
# Build from the repo root:
#
#   docker build -f dev/demo/Dockerfile .
#
# No deployment-specific content is baked in: the host writes
# platform.lua into /data, and the store is seeded with the public demo
# lab (tst/eval/demo-lab, doc/agent-eval.md) on first boot. See
# dev/demo/README.md.

FROM debian:12-slim AS luam-builder
# luam's build_libs.sh fails when any of its C modules fails, so every
# module's dev headers are needed here, mariadb included.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git build-essential libreadline-dev libsqlite3-dev libcrypt-dev libssl-dev libmariadb-dev ca-certificates wget perl \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/BenSiv/luam.git /luam
WORKDIR /luam
RUN ./bld/build_lang.sh && ./bld/build_libs.sh

FROM luam-builder AS daat-builder
COPY . /daat
WORKDIR /daat
RUN LUAM_DIR=/luam ./bld/build.sh

FROM debian:12-slim
# apache2: CGI hosting (mod_cgid). cmark-gfm: Markdown rendering (not
# plain cmark: no tables). gnuplot-nox: ```plot``` fences. poppler-utils:
# pdftotext for chat PDF attachments. libmariadb3: the binary links it
# even when the deployment runs on SQLite. No gcloud: on GCE the Vertex
# provider takes its token from the metadata server.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libreadline8 libsqlite3-0 libssl3 libmariadb3 ca-certificates curl apache2 cmark-gfm gnuplot-nox poppler-utils sqlite3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=daat-builder /daat/bin/daat /app/bin/daat
COPY --from=daat-builder /daat/vnd /app/vnd
ENV PLATFORM_VENDOR_DIR=/app/vnd

# The demo-lab loader (tst/eval/load.lua) runs under luam against daat's
# own sources rather than through the binary, so both ship in the image
# for the first-boot seed (seed-demo-lab.sh).
COPY --from=luam-builder /luam/bin /luam/bin
COPY --from=luam-builder /luam/lib /luam/lib
COPY --from=daat-builder /daat/src /app/src
COPY --from=daat-builder /daat/tst/eval /app/tst/eval
COPY dev/demo/seed-demo-lab.sh /app/seed-demo-lab.sh
COPY dev/demo/theme.lua /app/seed/theme.lua

RUN a2enmod cgid
COPY dev/demo/apache.conf /etc/apache2/sites-available/daat.conf
RUN a2dissite 000-default && a2ensite daat

EXPOSE 8000
CMD ["apache2ctl", "-D", "FOREGROUND"]
