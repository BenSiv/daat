# Demo deployment

A container image that runs daat with only the demo lab: the invented
laboratory in `tst/eval/demo-lab` (`doc/agent-eval.md`). It's meant for
working on the agent against a live model, with data anyone can see.
It contains no content from any real deployment.

The image is generic. Hosting and deploying it (a VM, TLS, DNS, model
credentials, CI) is up to whoever runs it, and lives with them, not here.

## Files

| File | What |
|------|------|
| `Dockerfile` | Builds luam (from GitHub) and daat (from this checkout) into the runtime image. It also carries the sources the demo-lab loader needs. |
| `apache.conf`, `theme.lua` | Apache vhost (CGI at `/`, port 8000) and the site name. |
| `seed-demo-lab.sh` | First-boot seed. It runs `tst/eval/load.lua` into `/data`, then archives the loader's `eval` account, whose password is public. |

## What the host provides

- **A volume at `/data`**: the deployment root. It holds `platform.lua`, written by the host before the first seed, and the store.
- **A model**: for Vertex, `agent_provider = "vertex"` plus `vertex_project` in `platform.lua`. On a GCE VM the token comes from the metadata server; see `src/provider/agent_vertex.lua`.
- **First boot**:

  ```sh
  docker exec -u www-data -w /data <container> /app/seed-demo-lab.sh [seed]
  docker exec -u www-data -w /data <container> /app/bin/daat user add admin <password> isa
  ```

- **TLS in front of port 8000**: `apache.conf` sets `HTTPS=on`, so cookies are always marked Secure.
- **Background queues on a timer**: `daat agent run-pending-background`, `extension run-pending`, `document embed-pending`, `knowledge curate-pending 3`, and hourly `store prune`.

Run every CLI command as `www-data` in `/data`, so the SQLite files stay
owned by the web server.

## Building

```sh
docker build -f dev/demo/Dockerfile .
```

It builds this checkout (luam comes from GitHub). Run `bld/test.sh`
first: the image doesn't run the tests.

To start over with a fresh demo lab, remove the host's seed marker
(the VM setup uses `/data/.seeded`) and boot again.
