#!/usr/bin/env bash
# Point the landing page and docs at the real repository.
#
#   ./Scripts/set-repo.sh indigolabs/laptopalarm
#
# Until this is run, docs/index.html links to github.com/OWNER/... and every
# one of those links is dead.
set -euo pipefail

if [[ $# -ne 1 || "$1" != */* ]]; then
  echo "usage: $0 <owner>/<repo>" >&2
  exit 2
fi

slug="$1"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

remaining_before=$(grep -rl "github.com/OWNER/" "$root/docs" "$root/README.md" 2>/dev/null || true)
if [[ -z "$remaining_before" ]]; then
  echo "Nothing to do — no github.com/OWNER/ placeholders left."
  exit 0
fi

while IFS= read -r f; do
  perl -pi -e "s{github\.com/OWNER/laptopalarm}{github.com/$slug}g" "$f"
  echo "  updated $(basename "$f")"
done <<< "$remaining_before"

echo "Repository set to https://github.com/$slug"
