# ===================================================================
# Phase C: Forgejo Provider
# ===================================================================

provider "gitea" {
  base_url = var.forgejo_base_url
  token    = var.forgejo_token
  # Insecure skip verify for self-signed TLS (remove if using Let's Encrypt)
  # insecure_ssl = true
}

# ===================================================================
# Organizations
# ===================================================================

resource "gitea_org" "questhive" {
  name        = "QuestHive"
  description = "QuestHive project"
  visibility  = "public"
}

resource "gitea_org" "blocmarket" {
  name        = "BlocMarket"
  description = "BlocMarket project"
  visibility  = "private"
}

resource "gitea_org" "rankhub" {
  name        = "Rankhub"
  description = "Rankhub project"
  visibility  = "private"
}

resource "gitea_org" "aether" {
  name        = "Aether"
  description = "Aether project"
  visibility  = "private"
}

resource "gitea_org" "deontic" {
  name        = "Deontic"
  description = "Deontic project"
  visibility  = "private"
}

resource "gitea_org" "suture" {
  name        = "suture"
  description = "Suture project"
  visibility  = "private"
}

# ===================================================================
# Teams (within organizations)
# ===================================================================

resource "gitea_team" "questhive_owners" {
  name         = "Owners"
  organization = gitea_org.questhive.id
  permission   = "owner"
}

resource "gitea_team" "blocmarket_owners" {
  name         = "Owners"
  organization = gitea_org.blocmarket.id
  permission   = "owner"
}

resource "gitea_team" "rankhub_owners" {
  name         = "Owners"
  organization = gitea_org.rankhub.id
  permission   = "owner"
}

resource "gitea_team" "aether_owners" {
  name         = "Owners"
  organization = gitea_org.aether.id
  permission   = "owner"
}

resource "gitea_team" "deontic_owners" {
  name         = "Owners"
  organization = gitea_org.deontic.id
  permission   = "owner"
}

resource "gitea_team" "suture_owners" {
  name         = "Owners"
  organization = gitea_org.suture.id
  permission   = "owner"
}

# ===================================================================
# Team Memberships
# ===================================================================
# Note: The gitea provider uses user IDs. We use data sources to look up
# existing users by username. The admin user (wyatt_admin) owns everything.

# Import existing users by username
data "gitea_user" "wyatt_admin" {
  username = "wyatt_admin"
}

data "gitea_user" "wyatt" {
  username = "wyatt"
}

data "gitea_user" "joshkad" {
  username = "joshkad"
}

data "gitea_user" "ayo" {
  username = "ayo"
}

resource "gitea_team_membership" "questhive_wyatt_admin" {
  team_id  = gitea_team.questhive_owners.id
  username = data.gitea_user.wyatt_admin.username
}

resource "gitea_team_membership" "blocmarket_wyatt_admin" {
  team_id  = gitea_team.blocmarket_owners.id
  username = data.gitea_user.wyatt_admin.username
}

resource "gitea_team_membership" "blocmarket_joshkad" {
  team_id  = gitea_team.blocmarket_owners.id
  username = data.gitea_user.joshkad.username
}

resource "gitea_team_membership" "rankhub_wyatt_admin" {
  team_id  = gitea_team.rankhub_owners.id
  username = data.gitea_user.wyatt_admin.username
}

resource "gitea_team_membership" "aether_wyatt_admin" {
  team_id  = gitea_team.aether_owners.id
  username = data.gitea_user.wyatt_admin.username
}

resource "gitea_team_membership" "deontic_wyatt_admin" {
  team_id  = gitea_team.deontic_owners.id
  username = data.gitea_user.wyatt_admin.username
}

resource "gitea_team_membership" "suture_wyatt_admin" {
  team_id  = gitea_team.suture_owners.id
  username = data.gitea_user.wyatt_admin.username
}
