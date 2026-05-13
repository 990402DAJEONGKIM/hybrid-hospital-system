provider "aws" {
  region = "ap-south-2"

  default_tags {
    tags = {
      Owner       = "std4"
      Project     = "msp-solution-architect"
      Team        = "k2p"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}