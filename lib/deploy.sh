# Provenance shared by the deploy scripts (nixos/deploy, pikvm/deploy,
# windows/deploy, lgtv/deploy, openwrt/deploy): which tree is being deployed and by whom, written as lines
# of the same shape by every deploy and found under {unit="deploy"} in Loki.
# A later investigation can then tell a deploy, a dirty one included, from a
# manual change on the machine. Sourced from the repository root.
#
# NixOS machines announce each new system in the Discord ops channel
# themselves (update-notify in nixos/modules/common.nix); deploy_notify
# posts the same announcement for the machines that are not NixOS.
#
# Dirtiness follows nix's definition: modified tracked files, not untracked
# ones, which is also what strips the revision from a built NixOS system.

deploy_commit="$(git rev-parse HEAD)"
deploy_rev=${deploy_commit:0:12}
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

# deploy_loki <host> <line>: sends a provenance line to Loki directly, for
# a machine that ships no logs of its own, labeled as the machines' journal
# lines are, under {unit="deploy"}. Best effort: Loki being away never fails
# a deploy.
deploy_loki() {
  local host=$1 line=$2
  jq -cn --arg host "$host" --arg line "$line" --arg ts "$(date +%s%N)" \
    '{streams: [{stream: {host: $host, unit: "deploy", job: "deploy"}, values: [[$ts, $line]]}]}' |
    curl -sfS -m 10 -H 'Content-Type: application/json' --data-binary @- \
      https://loki.taild07ab.ts.net/loki/api/v1/push ||
    echo "deploy: could not log $host's deploy to Loki" >&2
}

# deploy_notify <host> <what>: announces in the Discord ops channel that
# <what> was applied to <host>, in update-notify's shape: the host as the
# title, then the commit. Best effort: Discord being away never fails a
# deploy. The webhook comes from lib/secrets.yaml, which decrypts without the
# gate.
deploy_notify() {
  local host=$1 what=$2 desc url
  desc="Applied $what · [${deploy_commit:0:7}](https://github.com/mdlayher/homelab/commit/$deploy_commit)"
  if [[ $deploy_dirty == yes ]]; then
    desc="$desc + uncommitted changes"
  fi
  if ! url="$(sops -d --extract '["discord_ops_webhook_url"]' lib/secrets.yaml 2>/dev/null)"; then
    echo "deploy: cannot read the ops webhook from lib/secrets.yaml; not announced" >&2
    return 0
  fi
  jq -cn --arg title "$host" --arg desc "$desc" '{embeds: [{title: $title, description: $desc}]}' |
    curl -sfS -m 10 -H 'Content-Type: application/json' --data-binary @- "$url" >/dev/null ||
    echo "deploy: could not announce $host's deploy in Discord" >&2
}
