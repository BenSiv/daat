locals {
  labels         = { app = var.name, managed-by = "terraform" }
  vertex_project = var.vertex_project != "" ? var.vertex_project : var.project_id
  image          = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo}/${var.name}:latest"

  platform_lua = templatefile("${path.module}/templates/platform.lua.tpl", {
    vertex_project = local.vertex_project
    vertex_region  = var.vertex_region
    agent_model    = var.agent_model
    domain         = var.domain
  })

  startup_script = templatefile("${path.module}/templates/startup.sh.tpl", {
    name                  = var.name
    image                 = local.image
    platform_lua          = local.platform_lua
    admin_password_secret = google_secret_manager_secret.admin_password.secret_id
    demo_lab_seed         = var.demo_lab_seed
    jobs_interval         = var.jobs_interval
  })
}

resource "google_artifact_registry_repository" "daat" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_repo
  format        = "DOCKER"
  labels        = local.labels
}

# ---------------------------------------------------------------------------
# The VM's identity: Vertex, logs and metrics, its own image and its own
# admin password -- nothing else in the project.
# ---------------------------------------------------------------------------
resource "google_service_account" "vm" {
  project      = var.project_id
  account_id   = "${var.name}-vm"
  display_name = "${var.name} VM"
}

resource "google_project_iam_member" "vm" {
  for_each = toset([
    "roles/aiplatform.user",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# Vertex in another project needs the grant there instead.
resource "google_project_iam_member" "vm_vertex" {
  count   = local.vertex_project != var.project_id ? 1 : 0
  project = local.vertex_project
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_artifact_registry_repository_iam_member" "vm_pull" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.daat.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.vm.email}"
}

# The `admin` account's password, created on first boot. Read it with
#   gcloud secrets versions access latest --secret <name>-admin-password
resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "google_secret_manager_secret" "admin_password" {
  project   = var.project_id
  secret_id = "${var.name}-admin-password"
  labels    = local.labels

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "admin_password" {
  secret      = google_secret_manager_secret.admin_password.id
  secret_data = random_password.admin.result
}

resource "google_secret_manager_secret_iam_member" "vm_admin_password" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.admin_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}

# ---------------------------------------------------------------------------
# Network: SSH only through IAP, port 8000 only from the load balancer.
# ---------------------------------------------------------------------------
data "google_compute_network" "vpc" {
  project = var.project_id
  name    = var.network
}

data "google_compute_subnetwork" "vpc" {
  project = var.project_id
  name    = var.network
  region  = var.region
}

resource "google_compute_firewall" "ssh_iap" {
  project       = var.project_id
  name          = "${var.name}-allow-ssh-iap"
  network       = data.google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = [var.name]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "lb" {
  project       = var.project_id
  name          = "${var.name}-allow-lb"
  network       = data.google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = [var.name]

  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }
}

# ---------------------------------------------------------------------------
# The VM. The startup script runs on every boot: it pulls :latest,
# rewrites platform.lua, and seeds the demo lab once. Changing the
# script updates the metadata in place; it takes effect on the next boot
# (dev/demo/deploy.sh resets the VM).
# ---------------------------------------------------------------------------
resource "google_compute_instance" "vm" {
  project      = var.project_id
  name         = var.name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = [var.name]
  labels       = local.labels

  boot_disk {
    initialize_params {
      image  = "debian-cloud/debian-12"
      size   = var.boot_disk_size_gb
      type   = "pd-balanced"
      labels = local.labels
    }
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.vpc.self_link

    # Egress only (apt, the registry, Secret Manager, Vertex): a default
    # VPC without Cloud NAT has no other way out. Ingress stays limited
    # by the firewall rules above.
    access_config {}
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    startup-script         = local.startup_script
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  depends_on = [
    google_secret_manager_secret_version.admin_password,
    google_secret_manager_secret_iam_member.vm_admin_password,
    google_artifact_registry_repository_iam_member.vm_pull,
  ]
}

# The store lives on the boot disk, so a daily snapshot is its backup.
resource "google_compute_resource_policy" "snapshot" {
  project = var.project_id
  name    = "${var.name}-daily-snapshot"
  region  = var.region

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "03:00"
      }
    }
    retention_policy {
      max_retention_days    = 7
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
    snapshot_properties {
      labels            = local.labels
      storage_locations = [var.region]
    }
  }
}

resource "google_compute_disk_resource_policy_attachment" "snapshot" {
  project = var.project_id
  name    = google_compute_resource_policy.snapshot.name
  disk    = google_compute_instance.vm.name
  zone    = var.zone
}

# ---------------------------------------------------------------------------
# DNS in an existing zone.
# ---------------------------------------------------------------------------
data "google_dns_managed_zone" "zone" {
  project = var.project_id
  name    = var.dns_zone_name
}

resource "google_dns_record_set" "a" {
  project      = var.project_id
  managed_zone = data.google_dns_managed_zone.zone.name
  name         = "${var.domain}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.lb.address]
}

resource "google_dns_record_set" "caa" {
  project      = var.project_id
  managed_zone = data.google_dns_managed_zone.zone.name
  name         = "${var.domain}."
  type         = "CAA"
  ttl          = 300
  rrdatas      = ["0 issue \"pki.goog\""]
}
