# Global HTTPS load balancer: Google-managed certificate for var.domain,
# port 80 redirects to 443, Cloud Armor in front, plain HTTP to the VM
# on port 8000 (apache.conf).

resource "google_compute_global_address" "lb" {
  project = var.project_id
  name    = "${var.name}-ip"
}

resource "google_compute_managed_ssl_certificate" "lb" {
  project = var.project_id
  name    = "${var.name}-cert"

  managed {
    domains = [var.domain]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_health_check" "lb" {
  project             = var.project_id
  name                = "${var.name}-hc"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8000
    request_path = "/login"
  }
}

resource "google_compute_network_endpoint_group" "lb" {
  project               = var.project_id
  name                  = "${var.name}-neg"
  network               = data.google_compute_network.vpc.id
  subnetwork            = data.google_compute_subnetwork.vpc.id
  zone                  = var.zone
  default_port          = 8000
  network_endpoint_type = "GCE_VM_IP_PORT"
}

resource "google_compute_network_endpoint" "lb" {
  project                = var.project_id
  network_endpoint_group = google_compute_network_endpoint_group.lb.name
  zone                   = var.zone
  instance               = google_compute_instance.vm.name
  ip_address             = google_compute_instance.vm.network_interface[0].network_ip
  port                   = 8000
}

resource "google_compute_security_policy" "lb" {
  project = var.project_id
  name    = "${var.name}-armor"

  # Per-IP throttle for everyone admitted by allowed_cidr_ranges; past
  # it, 429. Requests outside those ranges fall through to the default
  # deny below.
  rule {
    priority = 100
    action   = "throttle"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = var.allowed_cidr_ranges
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 100
        interval_sec = 60
      }
    }
  }

  rule {
    priority = 2147483647
    action   = "deny(403)"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

resource "google_compute_backend_service" "lb" {
  project         = var.project_id
  name            = "${var.name}-backend"
  protocol        = "HTTP"
  port_name       = "http"
  timeout_sec     = var.backend_timeout_sec
  security_policy = google_compute_security_policy.lb.id
  health_checks   = [google_compute_health_check.lb.id]

  backend {
    group                 = google_compute_network_endpoint_group.lb.id
    balancing_mode        = "RATE"
    max_rate_per_endpoint = 100
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "lb" {
  project         = var.project_id
  name            = "${var.name}-urlmap"
  default_service = google_compute_backend_service.lb.id
}

resource "google_compute_url_map" "redirect" {
  project = var.project_id
  name    = "${var.name}-redirect"

  default_url_redirect {
    https_redirect         = true
    strip_query            = false
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
  }
}

resource "google_compute_target_https_proxy" "lb" {
  project          = var.project_id
  name             = "${var.name}-https-proxy"
  url_map          = google_compute_url_map.lb.id
  ssl_certificates = [google_compute_managed_ssl_certificate.lb.id]
}

resource "google_compute_target_http_proxy" "redirect" {
  project = var.project_id
  name    = "${var.name}-http-proxy"
  url_map = google_compute_url_map.redirect.id
}

resource "google_compute_global_forwarding_rule" "https" {
  project               = var.project_id
  name                  = "${var.name}-https"
  ip_address            = google_compute_global_address.lb.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.lb.id
  load_balancing_scheme = "EXTERNAL"
}

resource "google_compute_global_forwarding_rule" "http" {
  project               = var.project_id
  name                  = "${var.name}-http"
  ip_address            = google_compute_global_address.lb.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
  load_balancing_scheme = "EXTERNAL"
}
