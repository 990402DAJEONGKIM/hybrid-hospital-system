#instance.tf

# EC2
resource "aws_instance" "aws-wazuh-indexer" {
  ami                    = "ami-0eab39170eb2844c5"
  instance_type          = "t3.xlarge"
  subnet_id              = data.aws_subnet.aws-app-sub-2c.id
  vpc_security_group_ids = [aws_security_group.aws-wazuh-indexer-sg.id]
  iam_instance_profile   = aws_iam_instance_profile.aws-wazuh-indexer-profile.name
  private_ip             = "10.0.13.83" 
  root_block_device {
    volume_size = 100
    volume_type = "gp3"
    encrypted   = true

    tags = {
      Name  = "aws-wazuh-indexer-volume"
      Owner = "st2"
    }
  }
  tags = {
    Name  = "aws-wazuh-indexer"
    Owner = "st2"
  }


}


# ── 인덱서 데이터 전용 EBS ──────────────────────────────
# 루트볼륨과 분리. EC2가 죽어도 이 볼륨은 살아남아 데이터 보존 → 새 EC2에 재부착.
# 추가 260610 김강환
resource "aws_ebs_volume" "aws-wazuh-indexer-data-01" {
  # 인스턴스와 반드시 같은 AZ (subnet = ap-south-2c)
  availability_zone = data.aws_subnet.aws-app-sub-2c.availability_zone
  size              = 200
  type              = "gp3"
  encrypted         = true   # ISMS-P: 감사데이터 저장 시 암호화 필수 (가드레일)

  tags = {
    Name  = "aws-wazuh-indexer-data-01"
    Owner = "st2"
  }

  lifecycle {
    prevent_destroy = true   # terraform destroy 시 데이터 볼륨 보호
  }
}

# 인스턴스에 데이터 볼륨 부착 (/dev/sdb)
# skip_destroy: 인스턴스 교체/삭제 시 볼륨까지 같이 지워지지 않게
# 추가 260610 김강환
resource "aws_volume_attachment" "aws-wazuh-indexer-data-att-01" {
  device_name  = "/dev/sdc"  # sdb → sdc
  volume_id    = aws_ebs_volume.aws-wazuh-indexer-data-01.id
  instance_id  = aws_instance.aws-wazuh-indexer.id
  skip_destroy = true
}