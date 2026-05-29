packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = "~> 1"
    }
  }
}

variable "project_id" {
  type    = string
  default = "gcp-project-496802"
}

variable "zone" {
  type    = string
  default = "asia-northeast3-a"
}

variable "network" {
  type    = string
  default = "gcp-vpc"
}

variable "subnet" {
  type    = string
  default = "regions/asia-northeast3/subnetworks/gcp-subnet"
}

locals {
  timestamp  = formatdate("YYYYMMDDHHmmss", timestamp())
  image_name = "gcp-dr-reservation-${local.timestamp}"
}

source "googlecompute" "dr_app" {
  project_id   = var.project_id
  zone         = var.zone
  machine_type = "e2-small"
  disk_size    = 20
  disk_type    = "pd-standard"

  # 베이스 이미지
  source_image_family     = "debian-12"
  source_image_project_id = ["debian-cloud"]

  # 결과 이미지
  image_name        = local.image_name
  image_family      = "gcp-dr-reservation"
  image_description = "DR reservation app — built by GitHub Actions"

  # ISMS-P: 공인 IP 없음, IAP 터널로 SSH
  omit_external_ip  = true
  use_internal_ip   = true
  use_iap           = true
  network          = var.network
  subnetwork       = var.subnet

  # 기존 IAP SSH 방화벽 규칙(gcp-fw-allow-iap-ssh-dr) 재사용
  tags = ["dr-app"]

  ssh_username = "packer"

}

build {
  sources = ["source.googlecompute.dr_app"]

  # ── 1. 패키지 및 Python 의존성 설치 ───────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "sudo apt-get update -y",
      "sudo apt-get install -y python3 python3-pip python3-venv nginx curl",
    ]
  }

  # ── 2. 앱 코드 업로드 ─────────────────────────────────────────────────────────
  provisioner "file" {
    source      = "../app/dr-lite/backend/"
    destination = "/tmp/dr-backend"
  }

  provisioner "file" {
    source      = "../app/dr-lite/frontend/"
    destination = "/tmp/dr-frontend"
  }

  # ── 3. 앱 설치 + systemd 등록 ─────────────────────────────────────────────────
  provisioner "shell" {
    script = "scripts/install.sh"
  }

  # ── 4. 빌드 결과를 manifest로 저장 (image 이름 추출용) ──────────────────────────
  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}
