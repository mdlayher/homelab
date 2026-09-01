# Branch rules for the homelab repository. main becomes root on every
# machine nightly via system.autoUpgrade, so its protection is a security
# boundary: with no bypass actors, the rules bind admins too, and the
# signature requirement means a stolen write credential cannot land commits
# — pushes must carry a signature only the admin's forwarded agent produces.
#
# Status checks are deliberately not required: the workflow is direct
# pushes, whose commits cannot have passing checks before they exist. CI
# remains advisory; deploy-from-local-tree-first is the guard.
#
# Classic branch protection on this repository predates this ruleset and
# should be removed in the console once the ruleset is active.
resource "github_repository_ruleset" "homelab_main" {
  name        = "main"
  repository  = "homelab"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    required_signatures     = true
    required_linear_history = true
    deletion                = true
    non_fast_forward        = true
  }
}
