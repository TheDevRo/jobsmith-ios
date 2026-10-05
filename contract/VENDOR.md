# Vendored contract

This app and the desktop/Docker app ([TheDevRo/Jobsmith](https://github.com/TheDevRo/Jobsmith))
read and write the same sync folder and inject the same Apply scripts, so a few
files have to agree across both repos. Jobsmith is the source of truth. This
repo keeps copies so it builds and tests on its own.

Copied from `TheDevRo/Jobsmith` @ `14c7046`:

| Here | Upstream | Used by |
| --- | --- | --- |
| `contract/sync-test-vectors/` | `backend/sync/test-vectors/` | `KitTests/SyncConformanceTests.swift` |
| `contract/ai_providers.json` | `backend/ai_providers.json` | `KitTests/SetupAssistantTests.swift` |
| `App/Apply/JS/{snapshot,fill,workday_auth}.js` | `extension/src/common/` | the Apply browser, `KitTests` |
| `KitTests/Fixtures/triage_golden.json` | `tests/fixtures/triage_golden.json` | `QuickMatchTests.swift` |
| `KitTests/Fixtures/nli_line_premises.json` | `tests/fixtures/nli_line_premises.json` (written by `tests/test_nli_beta.py`) | `LocalNLITests.swift` |

`scripts/check_contract.sh` fails when any copy drifts from Jobsmith `main`. CI
runs it on every push and once a day, so an upstream change shows up here even
when nobody touches this repo.

**Do not change these files here first.** Change them in Jobsmith, then copy
them over and bump the pin above:

```sh
UP=~/Jobsmith
rm -rf contract/sync-test-vectors && cp -R "$UP"/backend/sync/test-vectors contract/sync-test-vectors
cp "$UP"/backend/ai_providers.json contract/
for f in snapshot fill workday_auth; do cp "$UP"/extension/src/common/$f.js App/Apply/JS/; done
cp "$UP"/tests/fixtures/{triage_golden,nli_line_premises}.json KitTests/Fixtures/
JOBSMITH_DIR="$UP" scripts/check_contract.sh
```

The JS copies keep their own header comments, so after copying restore the
"this is a copy" header at the top of each file. The check ignores comments.

The other direction (Swift output that the Python engine must accept, and the
Swift score parser matching the Python one) is tested in Jobsmith's CI, which
checks out this repo. See `tests/test_sync_crosslang.py` and
`tests/test_crosslang_ai.py` there.
