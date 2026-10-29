# Demo deployment

A public daat deployment on Google Cloud that holds only the demo lab:
the invented laboratory in `tst/eval/demo-lab` (`doc/agent-eval.md`).
It's meant for working on the agent against a live model with data
anyone can see. It contains no content from any real deployment.

What you get:
- One VM running this checkout's image: Apache serving `bin/daat` over CGI, with a SQLite store on the boot disk and a daily snapshot.
- A global HTTPS load balancer with a managed certificate, plus Cloud Armor (per-IP throttle, optional source allowlist).
- A DNS record in an existing Cloud DNS zone.
- Vertex AI for chat and embeddings, through the VM's own service account. Nothing else in the project is granted to it.
- On first boot, the demo lab is loaded and embedded. An `admin` account is created, with its password in Secret Manager.

There's no web search and no mail. Without mail, admins set account
passwords on `/admin-users` or with `daat user add` (see below).

## Files

| File | What |
|------|------|
| `Dockerfile` | Builds luam (from GitHub) and daat (from this checkout) into the runtime image. It also carries the sources the demo-lab loader needs. |
| `apache.conf`, `theme.lua` | Apache vhost (CGI at `/`) and the site name. |
| `seed-demo-lab.sh` | First-boot seed. It runs `tst/eval/load.lua` into `/data`, then archives the loader's `eval` account, whose password is public. |
| `cloudbuild.yaml`, `deploy.sh` | Build and push the image with Cloud Build, then reset the VM so it runs the image. |
| `terraform/` | Everything on Google Cloud. `templates/` holds the VM's startup script and `platform.lua`. |

## Setting it up

You need:
- a GCP project with the Compute, Artifact Registry, Cloud Build, Secret Manager, Vertex AI and Cloud DNS APIs enabled;
- a Cloud DNS zone for the domain;
- a GCS bucket for Terraform state.

Write two files outside this repo, because they name your project:

```hcl
# backend.hcl
bucket = "<state bucket>"
prefix = "daat-demo"
```

```hcl
# demo.tfvars
project_id    = "<project>"
domain        = "daat-demo.example.com"
dns_zone_name = "<cloud dns zone name>"
```

`terraform/variables.tf` has the rest: region and zone, machine size, model, and the source allowlist.

Then:

```sh
cd dev/demo/terraform
terraform init -backend-config=/path/to/backend.hcl
terraform apply -var-file=/path/to/demo.tfvars
cd ../../..
PROJECT_ID=<project> ./dev/demo/deploy.sh --build-only
```

The VM waits for the image to appear, then starts it and seeds the
demo lab, which takes a few minutes. The managed certificate becomes
active once DNS resolves to the load balancer, which can take 15-60
minutes on a first apply.

Read the admin password with:

```sh
gcloud secrets versions access latest --project <project> --secret daat-demo-admin-password
```

## Redeploying

```sh
PROJECT_ID=<project> ./dev/demo/deploy.sh
```

This builds whatever is checked out, including uncommitted changes (the
image tag then ends in `-dirty`), and resets the VM. The store survives,
because it's on the boot disk. After editing `terraform/`, run
`terraform apply` before deploying: the startup script only runs at
boot.

## Operating it

```sh
gcloud compute ssh daat-demo --project <project> --zone <zone> --tunnel-through-iap
sudo docker exec -u www-data -w /data daat /app/bin/daat user add <login> <password> i
```

All CLI commands run that way, as `www-data` in `/data`, so the SQLite
files stay owned by the web server. The boot log is in the serial
output (`gcloud compute instances get-serial-port-output daat-demo ...
| grep daat-startup`). Apache's log is in Cloud Logging.

To start over with a fresh demo lab, remove `/opt/daat/data/.seeded`
and reboot. The next boot discards the store and seeds it again.

## Cost and sharing a project

Every resource carries the label `app=daat-demo`, so billing reports
can be filtered by it. When the demo shares a project with another
deployment, they also share that project's Vertex AI quota. A heavy
evaluation run on the demo can throttle the other deployment's chat.
