output "url" {
  value = "https://${var.domain}"
}

output "instance_name" {
  value = google_compute_instance.vm.name
}

output "lb_ip" {
  value = google_compute_global_address.lb.address
}

output "admin_password_secret" {
  description = "Secret Manager secret holding the `admin` account's password."
  value       = google_secret_manager_secret.admin_password.secret_id
}

output "image" {
  value = local.image
}
