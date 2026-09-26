#!/bin/bash
# How many people have downloaded Yowl.
#
# There is no analytics in the app and there is not going to be, so these are
# the only numbers that exist. They all come from GitHub, which has been
# counting since the first release — nothing had to be instrumented, and the
# history is already there.
#
#   Downloads   public. Anyone can read these for any repo, no auth needed.
#   Traffic     owner only, and GitHub keeps just the last 14 days.
set -euo pipefail

REPO="${REPO:-nejcar20/yowl}"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }

bold "Downloads by release"
gh api "repos/${REPO}/releases" --paginate \
    --jq '.[] | select(.assets | length > 0)
          | .tag_name as $t
          | .assets[]
          | "  \($t)\t\(.download_count)"' \
    | sort -rV | awk -F'\t' '{printf "  %-12s %6d\n", $1, $2}'

TOTAL="$(gh api "repos/${REPO}/releases" --paginate \
    --jq '[.[].assets[].download_count] | add // 0')"
printf '  %-12s %6d\n' "TOTAL" "${TOTAL}"

bold "Stars and forks"
gh repo view "${REPO}" --json stargazerCount,forkCount \
    --jq '"  stars: \(.stargazerCount)   forks: \(.forkCount)"'

# Traffic needs push access. A fork or a clone of someone else's repo gets a
# 403 here, which is not an error worth failing the script over.
bold "Traffic, last 14 days"
if ! gh api "repos/${REPO}/traffic/views" \
        --jq '"  page views: \(.count) (\(.uniques) unique)"' 2>/dev/null; then
    echo "  unavailable — traffic needs push access to ${REPO}"
    exit 0
fi
gh api "repos/${REPO}/traffic/clones" \
    --jq '"  git clones: \(.count) (\(.uniques) unique)"'

bold "Where people came from, last 14 days"
gh api "repos/${REPO}/traffic/popular/referrers" \
    --jq '.[] | "  \(.referrer): \(.count) (\(.uniques) unique)"'

cat <<'NOTE'

What these numbers are not:
  - Not people. A download counts every time, including yours, and clone
    counts are mostly CI, mirrors and scrapers rather than humans.
  - Not usage. Nothing reports back from an installed copy, so there is no
    way to know how many armed it, or kept it.
NOTE
