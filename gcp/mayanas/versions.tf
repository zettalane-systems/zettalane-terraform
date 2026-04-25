# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

terraform {
  required_version = ">= 0.14"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
    template = {
      source  = "hashicorp/template"
      version = ">= 2.2"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}