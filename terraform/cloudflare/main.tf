terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }

  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-cloudflare-dns"
    }
  }
}

provider "cloudflare" {}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for mzclinic.cloud"
  type        = string
}

# ── 서비스 레코드 ──────────────────────────────────────────────────────────────

resource "cloudflare_record" "patient" {
  zone_id = var.cloudflare_zone_id
  name    = "patient"
  type    = "CNAME"
  content = "aws-patient-alb-1753693648.ap-south-2.elb.amazonaws.com"
  ttl     = 60
  proxied = false
}

resource "cloudflare_record" "staff" {
  zone_id = var.cloudflare_zone_id
  name    = "staff"
  type    = "CNAME"
  content = "aws-staff-alb-622767637.ap-south-2.elb.amazonaws.com"
  ttl     = 60
  proxied = false
}

resource "cloudflare_record" "wazuh" {
  zone_id = var.cloudflare_zone_id
  name    = "wazuh"
  type    = "CNAME"
  content = "aws-staff-alb-622767637.ap-south-2.elb.amazonaws.com"
  ttl     = 60
  proxied = false
}

# Grafana 서비스 레코드 26-06-03 김강환
resource "cloudflare_record" "grafana" {
  zone_id = var.cloudflare_zone_id
  name    = "grafana"
  type    = "CNAME"
  content = "aws-staff-alb-622767637.ap-south-2.elb.amazonaws.com"
  ttl     = 60
  proxied = false
}

# ── DR 레코드 ─────────────────────────────────────────────────────────────────

resource "cloudflare_record" "dr" {
  zone_id = var.cloudflare_zone_id
  name    = "dr"
  type    = "A"
  content = "8.232.62.13"
  ttl     = 60
  proxied = false
}

# ── DKIM 레코드 (SES) ─────────────────────────────────────────────────────────

resource "cloudflare_record" "dkim_1" {
  zone_id = var.cloudflare_zone_id
  name    = "5h32ebwuwkh3b5dldc5h43bpr2jkz2pm._domainkey"
  type    = "CNAME"
  content = "5h32ebwuwkh3b5dldc5h43bpr2jkz2pm.dkim.amazonses.com"
  ttl     = 1800
  proxied = false
}

resource "cloudflare_record" "dkim_2" {
  zone_id = var.cloudflare_zone_id
  name    = "bsi4dbr5wk4rl6wzijljfch6rm4zwqmn._domainkey"
  type    = "CNAME"
  content = "bsi4dbr5wk4rl6wzijljfch6rm4zwqmn.dkim.amazonses.com"
  ttl     = 1800
  proxied = false
}

resource "cloudflare_record" "dkim_3" {
  zone_id = var.cloudflare_zone_id
  name    = "uxxf6vtbv6jb3bumfndfi6o2xl3xoe6z._domainkey"
  type    = "CNAME"
  content = "uxxf6vtbv6jb3bumfndfi6o2xl3xoe6z.dkim.amazonses.com"
  ttl     = 1800
  proxied = false
}



# ── ACM 검증 레코드 ───────────────────────────────────────────────────────────

resource "cloudflare_record" "acm_patient" {
  zone_id = var.cloudflare_zone_id
  name    = "_4bc3c3471e77e06d31865fe6cbd0485b.patient"
  type    = "CNAME"
  content = "_690e85673eed6ad22e768019941816d1.jkddzztszm.acm-validations.aws"
  ttl     = 60
  proxied = false
}

resource "cloudflare_record" "acm_staff" {
  zone_id = var.cloudflare_zone_id
  name    = "_f501e105c61809d876e042ec70e0f1a9.staff"
  type    = "CNAME"
  content = "_34e3a1c87f305b7426eba143bcc46133.jkddzztszm.acm-validations.aws"
  ttl     = 60
  proxied = false
}

resource "cloudflare_record" "acm_wazuh" {
  zone_id = var.cloudflare_zone_id
  name    = "_c43a682cfeb7903dc19fc042ad2d25d2.wazuh"
  type    = "CNAME"
  content = "_4ce7a1a9339b037903303f2603cc10d8.jkddzztszm.acm-validations.aws"
  ttl     = 60
  proxied = false
}


# ACM grafana.mzclinic.cloud 인증서 검증 레코드 26-06-03 김강환
resource "cloudflare_record" "acm_grafana" {
  zone_id = var.cloudflare_zone_id
  name    = "_e9756ad397620ca25c721c0f319469a3.grafana"
  type    = "CNAME"
  content = "_64f7da68ff773f1aa6060c3be756d0de.jkddzztszm.acm-validations.aws"
  ttl     = 60
  proxied = false
}
