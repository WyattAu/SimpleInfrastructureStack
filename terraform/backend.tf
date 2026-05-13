# ===================================================================
# Terraform State Backend Configuration
# ===================================================================
# Local backend (default): state stored in terraform.tfstate, backed up
# via Restic. Suitable for single-operator homelab with weekly backups.
#
# To switch to a remote backend, uncomment one of the blocks below and
# run: terraform init -migrate-state
#
# IMPORTANT: Back up terraform.tfstate before migrating. The migration
# is one-way for most backends.
# ===================================================================

# --- Option 1: Terraform Cloud (free tier, up to 5 users) ---
# Requires: terraform login + TFC organization/workspace created
# Docs: https://developer.hashicorp.com/terraform/cloud-docs
#
# terraform {
#   cloud {
#     organization = "wyattau-infra"
#
#     workspaces {
#       name = "simple-infrastructure"
#     }
#   }
# }

# --- Option 2: S3-compatible backend (MinIO, Wasabi, Cloudflare R2) ---
# Requires: S3 bucket + IAM credentials
# Docs: https://developer.hashicorp.com/terraform/language/settings/backends/s3
#
# terraform {
#   backend "s3" {
#     bucket                      = "terraform-state"
#     key                         = "simpleinfrastructure/terraform.tfstate"
#     region                      = "auto"           # R2 uses "auto"
#     endpoint                    = "https://<ACCOUNT_ID>.r2.cloudflarestorage.com"
#     access_key                  = "R2_ACCESS_KEY"  # Use TF_VAR or IAM role
#     secret_key                  = "R2_SECRET_KEY"  # Use TF_VAR or IAM role
#     skip_credentials_validation = true
#     skip_metadata_api_check     = true
#     skip_region_validation      = true
#     force_path_style            = true
#
#     # State locking via DynamoDB (optional, not available on R2)
#     # dynamodb_table = "terraform-locks"
#     # region         = "us-east-1"
#   }
# }

# --- Option 3: Git backend (state stored in a separate private repo) ---
# Requires: private git repo with write access
# Docs: https://developer.hashicorp.com/terraform/language/settings/backends/http
#
# terraform {
#   backend "http" {
#     address        = "https://git.example.com/api/v4/projects/ID/terraform/state/simple-infrastructure"
#     lock_address   = "https://git.example.com/api/v4/projects/ID/terraform/state/simple-infrastructure/lock"
#     unlock_address = "https://git.example.com/api/v4/projects/ID/terraform/state/simple-infrastructure/unlock"
#   }
# }
