# ══════════════════════════════════════════════════════════════════════════════
# HTTPS 연동 (ISMS-P 2.7.1)
# NS가 Cloudflare로 전파된 후 apply하세요.
#
# [적용 순서]
# 1. 아래 블록을 main.tf 하단에 붙여넣기
# 2. main.tf의 google_compute_global_forwarding_rule.dr_app에서
#    target = google_compute_target_http_proxy.dr_app.id
#    → target = google_compute_target_http_proxy.dr_app_redirect.id 로 교체
# 3. variables.tf 하단에 cookie_secure 변수 추가 (별도 안내)
# 4. startup-dr-app.sh.tftpl에서 COOKIE_SECURE=false → ${cookie_secure} 교체
# 5. main.tf instance template templatefile 호출부에 cookie_secure = var.cookie_secure 추가
# 6. TFC apply → 인증서 발급 최대 20분 대기
# 7. HTTPS 확인 후 TFC 변수 cookie_secure = true로 변경 후 재apply
# ══════════════════════════════════════════════════════════════════════════════

# Managed SSL Certificate (dr.mzclinic.cloud)
# 인증서 발급까지 최대 20분 소요 — LB가 도메인으로 실제 응답해야 발급됨
resource "google_compute_managed_ssl_certificate" "dr_app" {
  name = "gcp-dr-ssl-cert"

  managed {
    domains = ["dr.mzclinic.cloud"]
  }
}

# HTTPS Target Proxy
resource "google_compute_target_https_proxy" "dr_app" {
  name             = "gcp-dr-reservation-https-proxy"
  url_map          = google_compute_url_map.dr_app.id
  ssl_certificates = [google_compute_managed_ssl_certificate.dr_app.id]
}

# HTTPS Forwarding Rule (443)
resource "google_compute_global_forwarding_rule" "dr_app_https" {
  name                  = "gcp-dr-reservation-https"
  ip_address            = google_compute_global_address.dr_lb.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.dr_app.id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# HTTP → HTTPS 리다이렉트용 URL Map
resource "google_compute_url_map" "dr_app_http_redirect" {
  name = "gcp-dr-reservation-http-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

# HTTP 리다이렉트 전용 Proxy
# main.tf의 google_compute_global_forwarding_rule.dr_app target을
# 이 리소스로 교체하세요:
#   target = google_compute_target_http_proxy.dr_app_redirect.id
resource "google_compute_target_http_proxy" "dr_app_redirect" {
  name    = "gcp-dr-reservation-http-redirect-proxy"
  url_map = google_compute_url_map.dr_app_http_redirect.id
}
