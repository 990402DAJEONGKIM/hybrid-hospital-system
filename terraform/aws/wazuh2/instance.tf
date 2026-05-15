data "aws_iam_instance_profile" "wazuh_profile" {
  name = "aws-wazuh-instance-profile"
}

data "aws_key_pair" "aws-wazuh-key" {
  key_name = "aws-wazuh-key"
}

# EC2
resource "aws_instance" "aws-wazuh-02" {
  ami                    = data.aws_ami.ubuntu_22_04.id
  instance_type          = "t3.xlarge"
  subnet_id              = data.aws_subnet.aws-app-sub-2a.id
  vpc_security_group_ids = [data.aws_security_group.aws-wazuh-sg.id]
  key_name               = data.aws_key_pair.aws-wazuh-key.key_name
  iam_instance_profile   = data.aws_iam_instance_profile.wazuh_profile.name

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  tags = {
    Name  = "aws-wazuh-02"
    Owner = "st2"
  }
}

# hosts.ini
resource "aws_s3_object" "ansible_hosts" {
  bucket  = "wazuh-ansible-ssm"
  key = "wazuh2/hosts.ini"
  content = <<-EOT
    [wazuh]
    ${aws_instance.aws-wazuh-02.id}

    [wazuh:vars]
    ansible_connection=community.aws.aws_ssm
    ansible_aws_ssm_region=${var.aws_region}
    ansible_aws_ssm_bucket_name=wazuh-ansible-ssm
    ansible_aws_ssm_plugin_path=/usr/local/bin/session-manager-plugin
    ansible_aws_ssm_timeout=3600
    wazuh_node_name=wazuh-02
    wazuh_node_type=worker
    wazuh_master_ip=${var.wazuh_master_ip}
    wazuh_cluster_key=${var.wazuh_cluster_key}
    wazuh_cluster_disabled=no
    slack_webhook_url=${var.slack_webhook_url}
  EOT
}