terraform {
  required_version = ">= 1.8.0"

  required_providers {
    vsphere = {
      source  = "vmware/vsphere"
      version = ">= 2.8.0, < 3.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

