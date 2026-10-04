# End-to-end checks against a local MESATestHub

`run.rb` runs real `mesa_test` commands against a MESATestHub dev server.
It uses a fake MESA tree instead of a real build, so a full pass takes
about a minute and needs no compilers.

```bash
# in your MESATestHub checkout
bin/rails server

# in this repo
TESTHUB_DIR=~/Repositories/MESATestHub \
MESATESTHUB_URL=http://localhost:3000 \
ruby dev/e2e/run.rb              # or name scenarios: cluster best legacy
```

How it works:

- **`fake_mesa.sh`** builds a git repo that looks enough like MESA to drive:
  - `./install` writes `build.log` and a `testhub.yml` in MESA's own format.
  - Each module's `test_suite/each_test_run` writes per-test `testhub.yml`
    files from the same environment variables MESA reads (`run_optional`,
    `fpe_checks`, `resolution_factor`).
  - Every install and test logs the environment it ran with.
- **The testhub's `dev:client_fixture:*` rake tasks** handle the server
  side (development database only):
  - `setup` seeds a throwaway user, a computer with an API key, and the
    fake commit on `main`, with chosen `[ci …]` requests.
  - `report` returns its claims, runs, and request state as JSON.
  - `teardown` removes it all.
- **This checkout's `lib/` and `bin/`** run under a scratch `HOME`, so your
  real `~/.mesa_test/config.yml` is never read or written.
  `MESATESTHUB_URL` points the client at the dev server.

Scenarios:

| name | what it exercises |
|---|---|
| `cluster` | `install best` → `submit --empty` → one `test N` per test (array jobs) in a shell with `MESA_SKIP_OPTIONAL` set. Checks: the modes recorded in `testhub.yml` win over the shell; an explicit `test` flag wins over the record, except FPE; all claims fulfilled; requests satisfied. |
| `best` | `install_and_test best` on an `[ci optional] [ci converge]` commit. Checks: each test runs once per mode and never both at once; then `request_work` exits 3. |
| `legacy` | Email + password, explicit SHA, whole suite in one go. Checks: claims up front, one `entire` submission fulfills them all, and `count` works. |

The testhub server must run from the same checkout as `TESTHUB_DIR` so
the fixture tasks and the API agree. Scratch files are deleted after a
passing scenario, and kept (with their path printed) after a failing one
or when `E2E_KEEP=1` is set.
