#!/usr/bin/env bash
# Verify the files this repo copies from TheDevRo/Jobsmith still match upstream
# (see contract/VENDOR.md). Exit 1 on drift.
#
#   scripts/check_contract.sh                 # compare against Jobsmith main
#   JOBSMITH_DIR=~/Jobsmith scripts/check_contract.sh   # compare against a local checkout
#   JOBSMITH_REF=v0.3.0 scripts/check_contract.sh       # compare against a tag/branch
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ref="${JOBSMITH_REF:-main}"

if [ -n "${JOBSMITH_DIR:-}" ]; then
  up="$JOBSMITH_DIR"
else
  up="$(mktemp -d)"
  trap 'rm -rf "$up"' EXIT
  git clone -q --depth 1 --branch "$ref" --filter=blob:none --sparse \
    https://github.com/TheDevRo/Jobsmith "$up"
  git -C "$up" sparse-checkout set --no-cone /backend/sync/test-vectors/ /backend/ai_providers.json /extension/src/common/ /tests/fixtures/triage_golden.json /tests/fixtures/nli_line_premises.json
fi

status=0

# Data files must be byte-identical.
if ! diff -r "$root/contract/sync-test-vectors" "$up/backend/sync/test-vectors" >/dev/null; then
  echo "DRIFT: contract/sync-test-vectors differs from backend/sync/test-vectors" >&2
  diff -rq "$root/contract/sync-test-vectors" "$up/backend/sync/test-vectors" >&2 || true
  status=1
fi
for pair in "contract/ai_providers.json:backend/ai_providers.json" \
            "KitTests/Fixtures/triage_golden.json:tests/fixtures/triage_golden.json" \
            "KitTests/Fixtures/nli_line_premises.json:tests/fixtures/nli_line_premises.json"; do
  here="${pair%%:*}" there="${pair#*:}"
  if ! cmp -s "$root/$here" "$up/$there"; then
    echo "DRIFT: $here differs from Jobsmith $there" >&2
    status=1
  fi
done

# Injected Apply JS: code must match, comments and blank lines may differ
# (each copy's header describes its own host).
strip() { sed 's|//.*$||' "$1" | sed 's/[[:space:]]*$//' | grep -v '^[[:space:]]*$'; }
for f in snapshot fill workday_auth; do
  ios="$root/App/Apply/JS/$f.js"
  ext="$up/extension/src/common/$f.js"
  if [ ! -f "$ios" ] || [ ! -f "$ext" ]; then
    echo "MISSING: $f.js not present on both sides" >&2
    status=1
    continue
  fi
  if ! diff -q <(strip "$ios") <(strip "$ext") >/dev/null; then
    echo "DRIFT: App/Apply/JS/$f.js code differs from extension/src/common/$f.js" >&2
    diff <(strip "$ios") <(strip "$ext") | head -40 >&2 || true
    status=1
  fi
done

[ "$status" -eq 0 ] && echo "Contract matches Jobsmith@$ref."
exit "$status"
