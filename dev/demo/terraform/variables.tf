variable "project_id" {
  description = "GCP project the demo runs in. Vertex AI calls are made and billed here too."
  type        = string
}

variable "region" {
  description = "Region for the VM, the image registry and the admin-password secret."
  type        = string
  default     = "europe-west3"
}

variable "zone" {
  description = "Zone for the VM."
  type        = string
  default     = "europe-west3-b"
}

variable "name" {
  description = "Prefix for every resource name, and the value of their `app` label (filter billing by it)."
  type        = string
  default     = "daat-demo"
}

variable "network" {
  description = "Existing VPC network the VM joins."
  type        = string
  default     = "default"
}

variable "artifact_repo" {
  description = "Artifact Registry repository this configuration creates for the demo image (dev/demo/deploy.sh pushes to it)."
  type        = string
  default     = "daat"
}

variable "domain" {
  description = "Hostname the demo is served under, e.g. daat-demo.example.com. Must sit in dns_zone_name."
  type        = string
}

variable "dns_zone_name" {
  description = "Existing Cloud DNS managed zone (in project_id) that domain's A record is added to."
  type        = string
}

variable "machine_type" {
  description = "VM machine type. The store is SQLite on the boot disk, so this is the whole deployment."
  type        = string
  default     = "e2-medium"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size. Holds the OS, the image and the store."
  type        = number
  default     = 30
}

variable "vertex_project" {
  description = "Project Vertex AI is called in (platform.lua's vertex_project). Empty means project_id."
  type        = string
  default     = ""
}

variable "vertex_region" {
  description = "platform.lua's vertex_region."
  type        = string
  default     = "global"
}

variable "agent_model" {
  description = "platform.lua's agent_model. Empty leaves daat's own default."
  type        = string
  default     = ""
}

variable "demo_lab_seed" {
  description = "Generator seed for the demo lab loaded on first boot (tst/eval/demo-lab). Changing it doesn't reseed an existing store."
  type        = number
  default     = 20261020
}

variable "jobs_interval" {
  description = "How often the VM drains daat's background queues (agent turns, extensions, embeddings, curation)."
  type        = string
  default     = "2min"
}

variable "backend_timeout_sec" {
  description = "How long the load balancer waits for a response. A chat turn can be several sequential model calls."
  type        = number
  default     = 180
}

variable "allowed_cidr_ranges" {
  description = "Source ranges Cloud Armor admits. The default admits everyone."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
