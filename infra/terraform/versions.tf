terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    # Only used when var.use_test_broker = true (throwaway CA + server certificate for the test broker)
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    # Zips the scale-in heartbeat Lambda (heartbeat.tf)
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

# Region is pinned to ap-southeast-2 by default because Emergency_Request_Service hard-codes
# region "ap-southeast-2" for its CloudWatch client (emergency_service.js:16). The IncomingRequests
# metric is therefore always written there, and the scaling alarms must live in the same region.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
