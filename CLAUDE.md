# mesa_test

A Ruby gem that provides a CLI between MESA (Modules for Experiments in Stellar Astrophysics) and the [MESATestHub](https://testhub.mesastar.org) Rails web app. Users run the MESA test suite locally and the gem submits commit + per-test-case results back to the hub.

Author: William Wolf (wolfwm@uwec.edu). License MIT. Homepage: https://github.com/MESAHub/mesa_test.

## Keep mesa_test lean

mesa_test runs on a heterogeneous fleet of machines that update rarely, so
every behavior baked in here is a behavior that can go stale. The lesson
learned over many years: keep this client thin, like a thin controller in
MVC.

- **MESA owns how tests run and what they record.** That means `./install`,
  `./each_test_run`, and the per-test `testhub.yml`. mesa_test sets
  environment variables, runs MESA's scripts, and forwards the YAML MESA
  writes. It doesn't parse MESA's output or second-guess results. When a
  new kind of information is needed, have MESA write it into
  `testhub.yml`.
- **MESATestHub owns policy:** what to test next, what counts as a request
  met, pending vs. untested, checksum grouping. Tuning any of it must never
  need a client update.
- **New capabilities are opt-in, and the plain path keeps working.**
  `install SHA`, `test`, `submit`, and `install_and_test SHA` with no new
  flags must behave as they always have, for users who never upgrade their
  habits. A new flag may add a MESA dependency. The default path should
  not.
- **Before adding anything:** could MESA or the hub do this instead? If not,
  record the new MESA assumption in the list below.

## What mesa_test assumes about MESA

When MESA changes how tests are run or recorded, check this list to see
whether a mesa_test update is needed. Long-standing, used by every run:

- `./clean` and `./install` at the top of `$MESA_DIR`. A successful build
  leaves `build.log` containing "MESA installation was successful", and the
  install writes `$MESA_DIR/testhub.yml` with `compiler`,
  `compiler_version`, `sdk_version`, `math_backend`. Only those four keys
  are read (`Mesa#compiler_hash`).
- `<module>/test_suite/` for `star`, `binary`, `astero`, each with:
  - `./list_tests`, printing `<number> <name>` lines;
  - `./each_test_run`, which with no argument runs every test and with
    `<number>` runs one;
  - one directory per test.
- Each test writes `testhub.yml` in its directory. That file is submitted
  as-is, apart from the keys mesa_test adds to the payload.
- `MESA_DIR` selects the installation.

Opt-in features add these (leave them out and they don't apply):

| Feature | Assumes |
|---|---|
| `--skip-optional`, `--fpe`, `--converge` / `--resolution-factor`, `best` mode | MESA reads `MESA_SKIP_OPTIONAL`, `MESA_FPE_CHECKS_ON` (at compile time as well as run time), and `MESA_TEST_SUITE_RESOLUTION_FACTOR`, and records the result in each test's `testhub.yml` as `run_optional` / `fpe_checks` / `resolution_factor` |
| `--build-threads` | `./install` sizes `make -j` from `NPROCS` (all cores if unset) |
| `--test-threads`, `--jobs` | tests take their thread count from `OMP_NUM_THREADS` |
| `--jobs` | concurrent `./each_test_run <number>` calls in one `test_suite` directory don't interfere (each test works only in its own directory). True today and long relied on by GNU-parallel scripts, but a convention, not a promise MESA makes. |
| recorded run modes (`install` with mode flags, or `install best`) | `$MESA_DIR/testhub.yml` stays a YAML mapping that mesa_test can append a `mesa_test_run_modes:` block to |

Possible ways to get thinner later: keep recorded run modes in a file
mesa_test owns instead of appending to MESA's `testhub.yml`, and move
parallelism into MESA itself (e.g. `./each_test_run --jobs N`), with
`--jobs` just passing it through.

## Layout

This is an intentionally minimal gem — no Bundler scaffolding, no Rakefile, no `spec/`, no `test/`. The whole gem is two files:

- [bin/mesa_test](bin/mesa_test) — Thor CLI. Defines the `MesaTest < Thor` class and its subcommands.
- [lib/mesa_test.rb](lib/mesa_test.rb) — All library code in a single file.
- [mesa_test.gemspec](mesa_test.gemspec) — Lists `lib/mesa_test.rb` as the only library file. If you add new library files you must also list them here.

Runtime dependencies (from gemspec): `thor ~> 1.3.0`, `json ~> 2.0`, `os ~> 1.0`. Ruby `>= 2.0.0`.

## Core classes in lib/mesa_test.rb

- `MesaTestSubmitter` — Owns the user/computer config (`~/.mesa_test/config.yml`) and all HTTP submission logic. The `setup` wizard prompts for credentials, mirror/work paths, and platform info. `submit_commit`, `submit_instance`, and `submit_*_log` are the actual network calls.
- `Mesa` — Wraps a MESA checkout. Knows how to `checkout`, `clean`, `install`, and iterate test cases. Uses a **mirror + worktree** pattern: a bare-ish mirror clone lives at `mesa_mirror`, and `git worktree add` materializes a `mesa_work` directory at a given SHA so repeated checkouts don't re-download history. Requires `git-lfs`.
- `MesaTestCase` — A single test case inside one of the three modules: `:star`, `:binary`, `:astero` (see [`MesaTestCase.modules`](lib/mesa_test.rb:952)). Test results are read from a `testhub.yml` file MESA writes into the test-case directory after a run.

CLI commands (all defined in [bin/mesa_test](bin/mesa_test)): `test`, `submit`, `checkout`, `install`, `install_and_test`, `request_work`, `setup`, `search`, `count`. Run `mesa_test help <cmd>` for details. `search` and `count` are read-only query commands that hit the testhub's search API and emit raw JSON to stdout (suitable for `jq` pipelines).

## Claims and dispatch (MESATestHub "Phase D")

MESATestHub can tell a computer what to work on and track what is in flight. The server-side design lives in MESATestHub's `docs/dispatcher-and-claims.md`.

- **Dispatch:** `MesaTestSubmitter#dispatch` → `POST /api/v1/dispatch`. It recommends a commit to build, or a test to run on a built SHA, plus the run modes to use. Returns nil on 204. `mesa_test request_work` prints the recommendation.
- **Claims:** `MesaTestSubmitter#claim` → `POST /api/v1/claims`. It marks a build or test as pending rather than untested.
  - Claims are advisory. Failures are warned about and swallowed, never fatal.
  - The client never stores claim ids. The server fulfills claims by matching computer, commit, and test when the submission arrives.
  - `install`, `test`, and `install_and_test` claim by default; turn it off with `--no-claim`.
  - Whole-suite runs claim with `all_test_cases: true`, and only when `--module` is `all`.
  - Claims carry the run's environment (`MesaTestSubmitter#claim_environment`), which the hub shows on pending tests. Test claims use the build's `testhub.yml` compiler record. Build claims are made before compiling, so they send only the shell's `MESASDK_VERSION`. Both send `OMP_NUM_THREADS` and the config's `platform_version`.
- **Run modes are recorded in the work dir.**
  - `install` appends a `mesa_test_run_modes:` block (`fpe`, `skip_optional`, `resolution_factor`) to `$MESA_DIR/testhub.yml`, after the compiler keys MESA's install writes. See `Mesa#record_run_modes` / `#recorded_run_modes`.
  - It's the single source of truth for later `test` and `submit` runs on that build, e.g. cluster array jobs running `mesa_test test N` with no flags. `submit` sends them as the `claim:` block's `use_*` flags.
  - Precedence when running tests: an explicit flag on `test`, then the recorded mode, then the shell's environment.
  - FPE always follows the build, since it's compiled in. A conflicting `--fpe`/`--no-fpe` on `test` is ignored with a warning.
  - `compiler_hash` takes only the four compiler keys from the file, so the block never leaks into the commit payload.
- **Mode flags:** `--skip-optional` (MESA runs optional inlists unless `MESA_SKIP_OPTIONAL` is set, hence the name), `--fpe`, `--converge`, each with a `--no-` form; unset means "not specified".
  - With an explicit SHA they set the modes directly.
  - With `best` they say what the computer is *willing* to do, overriding config `capabilities`, and the hub's request decides the actual modes.
- **Nothing to do exits 3** (`MesaTest::NOTHING_TO_DO_EXIT`), for `install best`, `install_and_test best`, and `request_work`. It exits before touching the work dir, so scripts can do `mesa_test install best || exit`.
- **`install_and_test best` / `install best`:**
  - The server picks the commit.
  - `best` mode then submits the build on its own, and loops test-scope dispatch (pinned to the built SHA) → claim → run → `submit_instance` until it gets a 204.
  - A repeated recommendation stops the loop, so it can't spin.
  - An explicit SHA keeps the old whole-suite behavior.
- **Run modes** (`run_flag_env` / `with_env` in lib):
  - A dispatch flag only ever *adds* to the user's environment; a false flag leaves their setup alone.
  - `full_inlists` unsets `MESA_SKIP_OPTIONAL`.
  - `converge` sets `MESA_TEST_SUITE_RESOLUTION_FACTOR` (the user's value if set, else 0.8).
  - `fpe` sets `MESA_FPE_CHECKS_ON=1`. It is **compile-time** (MESA's make reads it), so it is applied to the install and every test of that build. In test-scope dispatch, `can_fpe` means "this build has FPE checks".
- **Converge factor:**
  - `--resolution-factor X` implies `--converge` (and is refused with `--no-converge`).
  - Precedence for manual runs: `--resolution-factor`, then the shell's `MESA_TEST_SUITE_RESOLUTION_FACTOR`, then 0.8.
  - A commit can name its factor (`[ci converge 0.5]`), which the hub sends as the dispatch's `converge_factor`. In `best` mode that factor wins over both the flag and the shell, with a warning when they differ (`dispatch_run_modes`).
  - The factor is recorded at install like any mode, so array jobs use it too, and `test` warns if the shell's value differs.
- **Parallel testing (opt-in):** `--jobs N` on `test` (all-tests mode) and `install_and_test`; `--test-threads N` sets each test's `OMP_NUM_THREADS` (unset with `--jobs N` > 1: the shell's `OMP_NUM_THREADS`, else the core count, is the budget for the whole run, split evenly and rounded down, at least 1, and announced; serial runs leave the shell alone); `--build-threads N` sets `NPROCS` (MESA's `./install` runs `make -j$NPROCS`, all cores if unset) plus `OMP_NUM_THREADS` for the build.
  - With none set, behavior is exactly as before: serial `./each_test_run` per module, in the shell's environment.
  - Parallel tests run via `MesaTestCase#run_isolated`: one `./each_test_run <n>` subprocess each, with its own `chdir:` and env, output in `each_test_run.log` in the test dir. `#do_one` / `visit_dir` change the process-wide cwd and ENV, so they're unsafe across threads.
  - The worker pool is `run_workers` / `parallel_each` in lib.
  - Whole-suite runs still end with one `entire` submission, so nothing changes on the hub.
  - `install_and_test best --jobs N` runs N dispatch→claim→run→submit workers, with dispatch+claim under one lock. The hub won't hand out a test this computer holds a claim on, so no test runs twice at once. A worker that gets 204 waits while others are busy (their results can open more work) and stops once all are idle.
  - Ctrl-C kills the worker threads first (so nothing half-run is submitted), then each test's process group; exit 130.
- **Capabilities:** the optional modes a computer can run live in config under `capabilities: [full_inlists, fpe, converge]`, set in the setup wizard. Override per run with the mode flags.

## Submission targets

Two different servers are involved:

1. **MESATestHub** — JSON API. URI selected by `MesaTestSubmitter::DEFAULT_URI` = `https://testhub.mesastar.org`.
   - **Auth, preferred:** a per-computer **API key** (config `api_key`, or `MESATESTHUB_API_KEY` in the environment, which wins) sent as `Authorization: Bearer mth_…` on every request, via `MesaTestSubmitter#testhub_headers`.
     - With a key, email and password are never sent. The `submitter` block carries just `computer` + `platform_version`.
     - An unknown or revoked key gets 401 `{"error":"Invalid API key."}`. The server never falls back to the password.
     - Keys are generated on the computer's page on MESATestHub.
   - **Auth, legacy:** email + password, still fully supported and used whenever no key is configured.
   - **Submission flow** — `POST /check_computer.json`, `POST /submissions/create.json`, `POST /api/v1/dispatch`, `POST /api/v1/claims`. With password auth, credentials go in a `submitter` object (`email` + `password` + `computer` + `platform_version`) in the JSON request body, alongside commit/instance payload.
   - **Search flow** — `GET /test_instances/search.json`, `GET /test_instances/search_count.json`. With password auth, credentials are `email` and `password` *query parameters* (HTTPS-only); the search itself rides in `query_text`. Successful responses are `{"results": [...], "failures": [...]}` where `failures` lists query clauses the server's parser rejected. Always surface `failures` to the user — a typo in a key silently drops the clause, so the CLI echoes it to STDERR. Bad creds come back as HTTP 422 with `{"error":"Invalid e-mail or password."}`.
2. **Logs server** — `https://mesa-logs.flatironinstitute.org/uploads`. Receives base64-encoded `build.log`, `mk.txt`, `out.txt`, `err.txt` from failing builds/tests. Auth via `X-Api-Key` header using `logs_token` from config (contact Philip Mocz for a key). URL is hardcoded in `MesaTestSubmitter#submit_logs`.

## The `MODE` switch — important before release

[bin/mesa_test:7](bin/mesa_test:7) has a top-level constant:

```ruby
MODE = :production
```

- `:production` — `require 'mesa_test'` (the installed gem) and submit to `DEFAULT_URI`.
- `:staging` — load `../lib/mesa_test` from this checkout and submit to `https://beta-testhub.herokuapp.com`.
- `:development` — load local lib and submit to `http://localhost:3000`.

Always confirm `MODE = :production` before building/pushing the gem. Switching it is the standard dev workflow but is easy to forget.

## Release process

There is no Rakefile or CI. To cut a release:

1. Bump `s.version` and `s.date` in [mesa_test.gemspec](mesa_test.gemspec).
2. Ensure `MODE = :production` in [bin/mesa_test](bin/mesa_test).
3. `gem build mesa_test.gemspec` → produces `mesa_test-X.Y.Z.gem`.
4. `gem push mesa_test-X.Y.Z.gem` to publish to RubyGems.
5. Commit and tag.

The built `.gem` is sometimes checked in alongside the gemspec (see `mesa_test-1.1.12.gem`), but this isn't strictly required.

## Testing

**End-to-end harness:** [dev/e2e/](dev/e2e/README.md) runs real CLI commands against a MESATestHub dev server, using a fake MESA tree plus the testhub's `dev:client_fixture:*` rake tasks. `MESATESTHUB_URL` points any `mesa_test` at another testhub without editing `MODE`. Run it before releasing anything that touches the network or run-mode code.

Otherwise there is no automated test suite. Validation is manual: flip `MODE` to `:development` or `:staging`, point at a local MESATestHub, and exercise the CLI against a real MESA checkout. Don't add fake unit tests just because they're conventional — the value here is end-to-end against an actual MESA install and testhub instance.

## Conventions worth knowing

- The library uses bare `bash_execute` / `bashticks` helpers (bottom of [lib/mesa_test.rb](lib/mesa_test.rb)) to force commands through `bash -c`, because MESA's build scripts assume bash.
- `Mesa#with_mesa_dir` temporarily mutates `ENV['MESA_DIR']` around a block and restores it — this is how the gem isolates MESA installs from the user's own `MESA_DIR`.
- Config is YAML at `~/.mesa_test/config.yml` (note the directory, not a dotfile in `$HOME` directly). `MesaTestSubmitter::new_from_config` runs the setup wizard automatically if the file is missing.
- Passwords, API keys, and the logs API token are stored in plaintext in the config file. This is documented to the user in the setup wizard. The per-computer API key *is* the plan for credential storage: it can only submit for one computer, can't log into the website, and can be revoked on its own. Cluster jobs can use `MESATESTHUB_API_KEY` to keep it off disk entirely.
- `Mesa#compiler_hash` symbolizes `testhub.yml`'s keys before merging over its symbol-keyed defaults. Without that, the commit payload carried duplicate `compiler`/`sdk_version`/... keys. json 2.x quietly serialized both (the server kept the last); json 3.x raises.
- GitHub access protocol (`:ssh` vs `:https`) is per-user config and affects how the mirror is cloned.
