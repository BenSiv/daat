# Demo deployment

A container image that runs daat with only the demo lab: the invented
laboratory in `tst/eval/demo-lab` (`doc/agent-eval.md`). It's meant for
working on the agent against a live model, with data anyone can see.
It contains no content from any real deployment.

The image is generic. Hosting it (a VM, TLS, DNS, model credentials) is
up to whoever deploys it. `deploy.sh` targets Google Cloud: Cloud Build
plus a Compute Engine VM.

## Files

| File | What |
|------|------|
| `Dockerfile` | Builds luam (from GitHub) and daat (from this checkout) into the runtime image. It also carries the sources the demo-lab loader needs. |
| `apache.conf`, `theme.lua` | Apache vhost (CGI at `/`, port 8000) and the site name. |
| `seed-demo-lab.sh` | First-boot seed. It runs `tst/eval/load.lua` into `/data`, then archives the loader's `eval` account, whose password is public. |
| `cloudbuild.yaml`, `deploy.sh` | Build and push the image with Cloud Build, then reset the VM so it runs the image. |

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

## Building and deploying

```sh
PROJECT_ID=<project> NAME=<vm name> ./dev/demo/deploy.sh --build-only   # build and push
PROJECT_ID=<project> NAME=<vm name> ./dev/demo/deploy.sh                # build, push, reset the VM
```

This builds whatever is checked out, including uncommitted changes (the
image tag then ends in `-dirty`). It pushes to
`<REGION>-docker.pkg.dev/<PROJECT_ID>/<ARTIFACT_REPO>/<NAME>`, which
must already exist.

To start over with a fresh demo lab, remove the host's seed marker
(the VM setup uses `/data/.seeded`) and boot again.
