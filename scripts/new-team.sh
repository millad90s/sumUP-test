#!/usr/bin/env bash
# Scaffolds teams/<team>/team.yaml from a template. This is the entire
# onboarding UX - a team runs this, edits the buckets list, and opens a PR.
#
# Usage: new-team.sh <team-name> <owner-email> <cost-center>
#   new-team.sh acme-fraud-detection acme-fraud-detection@company.com CC-2001

set -euo pipefail

TEAM="${1:?Usage: new-team.sh <team-name> <owner-email> <cost-center>}"
OWNER="${2:?owner email required}"
COST_CENTER="${3:?cost center required, e.g. CC-1234}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_DIR="$REPO_ROOT/teams/$TEAM"

if [ -e "$TEAM_DIR" ]; then
  echo "teams/$TEAM already exists." >&2
  exit 1
fi

mkdir -p "$TEAM_DIR"
cat >"$TEAM_DIR/team.yaml" <<EOF
team: $TEAM
owner: $OWNER
cost_center: $COST_CENTER
buckets:
  - name: data
    visibility: private
EOF

echo "Created teams/$TEAM/team.yaml"
echo "Edit the buckets list as needed, then validate and open a PR:"
echo
echo "  python3 $REPO_ROOT/tests/validate_team_configs.py"
echo "  git add teams/$TEAM/team.yaml"
echo "  git checkout -b onboard-$TEAM"
echo "  git commit -m \"onboard $TEAM\""
echo "  git push -u origin onboard-$TEAM"
