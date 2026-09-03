#!/usr/bin/env bash
# Computes which teams/<team>/team.yaml files changed between two refs, split
# into "changed" (added or modified - needs plan/apply) and "removed" (needs
# an offboarding plan-destroy). Used by CI, but runs the same way locally.
#
# Usage: detect-changed-teams.sh <base-ref> [head-ref]
#   detect-changed-teams.sh origin/main HEAD
#   detect-changed-teams.sh $(git merge-base origin/main HEAD)
#
# Output (also written to $GITHUB_OUTPUT if set, for use in a matrix step):
#   changed_teams=["acme-payments","acme-analytics"]
#   removed_teams=["acme-old-team"]

set -euo pipefail

BASE_REF="${1:?Usage: detect-changed-teams.sh <base-ref> [head-ref]}"
HEAD_REF="${2:-HEAD}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

changed=()
removed=()

while IFS=$'\t' read -r status path; do
  [ -n "$path" ] || continue
  case "$path" in
    teams/*/team.yaml) ;;
    *) continue ;;
  esac
  team="$(echo "$path" | cut -d'/' -f2)"

  case "$status" in
    A | M) changed+=("$team") ;;
    D) removed+=("$team") ;;
    R*)
      # git reports renames as "R<score>\told\tnew" - treat the new path as
      # changed. A rename out of teams/ entirely would show as a plain D on
      # the old path in a separate line, which the D case above catches.
      changed+=("$team")
      ;;
  esac
done < <(git diff --name-status "$BASE_REF" "$HEAD_REF" -- 'teams/*/team.yaml')

to_json_array() {
  if [ "$#" -eq 0 ]; then
    echo "[]"
    return
  fi
  printf '%s\n' "$@" | jq -R . | jq -s -c 'unique'
}

changed_json="$(to_json_array "${changed[@]+"${changed[@]}"}")"
removed_json="$(to_json_array "${removed[@]+"${removed[@]}"}")"

echo "changed_teams=$changed_json"
echo "removed_teams=$removed_json"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "changed_teams=$changed_json"
    echo "removed_teams=$removed_json"
  } >>"$GITHUB_OUTPUT"
fi
