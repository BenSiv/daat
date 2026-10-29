terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State bucket and prefix are deployment-specific, so they're passed at
  # init time: terraform init -backend-config=<file> (see ../README.md).
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}
