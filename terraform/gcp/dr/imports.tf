import {
  to = google_secret_manager_secret.cf_api_token
  id = "projects/gcp-project-496802/secrets/cloudflare-api-token"
}

import {
  to = google_secret_manager_secret.cf_zone_id
  id = "projects/gcp-project-496802/secrets/cloudflare-zone-id"
}

import {
  to = google_compute_url_map.dr_app
  id = "projects/gcp-project-496802/global/urlMaps/gcp-dr-reservation-urlmap"
}

import {
  to = google_compute_managed_ssl_certificate.dr_app
  id = "projects/gcp-project-496802/global/sslCertificates/gcp-dr-ssl-cert"
}

import {
  to = google_compute_target_https_proxy.dr_app
  id = "projects/gcp-project-496802/global/targetHttpsProxies/gcp-dr-reservation-https-proxy"
}

import {
  to = google_compute_global_forwarding_rule.dr_app_https
  id = "projects/gcp-project-496802/global/forwardingRules/gcp-dr-reservation-https"
}

import {
  to = google_compute_url_map.dr_app_http_redirect
  id = "projects/gcp-project-496802/global/urlMaps/gcp-dr-reservation-http-redirect"
}

import {
  to = google_compute_target_http_proxy.dr_app_redirect
  id = "projects/gcp-project-496802/global/targetHttpsProxies/gcp-dr-reservation-http-redirect-proxy"
}

import {
  to = google_compute_backend_service.dr_app
  id = "projects/gcp-project-496802/global/backendServices/gcp-dr-reservation-backend"
}

import {
  to = google_compute_instance_group_manager.dr_app
  id = "projects/gcp-project-496802/zones/asia-northeast3-a/instanceGroupManagers/gcp-dr-reservation-mig"
}

import {
  to = google_compute_target_http_proxy.dr_app_redirect
  id = "projects/gcp-project-496802/global/targetHttpProxies/gcp-dr-reservation-http-redirect-proxy"
}