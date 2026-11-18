#!/usr/bin/env bash
# Fail on any `uses:` that does not pin an action by full commit SHA.
#
# A tag or branch can move. The review job runs claude-code-action with
# the agent's credentials, so a moved upstream tag would run someone
# else's code there. Every `uses:` must name a 40-character commit SHA,
# with the tag in a trailing comment:
#
#   uses: actions/checkout@<sha> # v4.4.0
#
# Local actions (`./…`) and `docker://` images by sha256 digest pass.
#
# One exemption: the example caller in examples/ calls this repository's
# own reusable workflow at `@v2`. That line is copied into consumer
# repositories, and they pick up a release when `v2` moves.
#
# Run from anywhere: scripts/check-pinned-actions.sh

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
cd "$root"

self='dourolabs/greenlight-actions/'
fail=0
n=0

while IFS= read -r -d '' file; do
  lineno=0
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    # `uses:` as a mapping key, optionally after a list dash.
    [[ $line =~ ^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*(.*)$ ]] || continue
    ref=${BASH_REMATCH[2]}
    ref=${ref%%#*}                       # drop a trailing comment
    ref=${ref%"${ref##*[![:space:]]}"}   # trim trailing space
    ref=${ref#[\"\']}; ref=${ref%[\"\']} # drop quotes
    n=$((n + 1))
    case $ref in
      ./*) continue ;;
      docker://*@sha256:*) continue ;;
    esac
    if [[ $file == examples/* && $ref == "$self"*@v2 ]]; then
      continue
    fi
    if [[ $ref =~ ^[^@[:space:]]+@[0-9a-f]{40}$ ]]; then
      continue
    fi
    echo "::error file=$file,line=$lineno::unpinned action: '$ref' — pin it by full commit SHA with the tag in a trailing comment"
    fail=1
  done <"$file"
done < <(find .github examples -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 | sort -z)

if [[ $n -eq 0 ]]; then
  echo "::error::found no uses: lines; the scan is broken" >&2
  exit 1
fi
if [[ $fail -ne 0 ]]; then
  exit 1
fi
echo "ok: all $n uses: lines are pinned"
