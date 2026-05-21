data "aws_lb" "patient" {
  name = var.patient_alb_name
}

data "aws_lb" "staff" {
  name = var.staff_alb_name
}
