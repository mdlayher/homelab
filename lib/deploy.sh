# Provenance shared by the deploy scripts (nixos/deploy, pikvm/deploy,
# windows/deploy): which tree is being deployed and by whom, written as lines
# of the same shape by every deploy and found under {unit="deploy"} in Loki.
# A later investigation can then tell a deploy, a dirty one included, from a
# manual change on the machine. Sourced from the repository root.
#
# Dirtiness follows nix's definition: modified tracked files, not untracked
# ones, which is also what strips the revision from a built NixOS system.

deploy_rev="$(git rev-parse --short=12 HEAD)"
deploy_branch="$(git rev-parse --abbrev-ref HEAD)"
if git diff-index --quiet HEAD --; then deploy_dirty=no; else deploy_dirty=yes; fi
deploy_by="$(id -un)@$(hostname -s)"

# deploy_line <action> <starting|finished|failed> [field=value...]
deploy_line() {
  local action=$1 phase=$2 line
  shift 2
  if [[ $phase == starting ]]; then
    line="$action starting: rev=$deploy_rev branch=$deploy_branch dirty=$deploy_dirty user=$deploy_by"
  else
    line="$action $phase: rev=$deploy_rev dirty=$deploy_dirty"
  fi
  if [[ $# -gt 0 ]]; then
    line="$line $*"
  fi
  echo "$line"
}
