provider "aws" {
  region = "ap-south-2"

  default_tags {
    tags = {
      Project     = "msp-solution-architect"
      Team        = "k2p"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}