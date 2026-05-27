# mesa_test

A Ruby gem that provides a CLI between MESA (Modules for Experiments in Stellar Astrophysics) and the [MESATestHub](https://testhub.mesastar.org) Rails web app. Users run the MESA test suite locally and the gem submits commit + per-test-case results back to the hub.

Author: William Wolf (wolfwm@uwec.edu). License MIT. Homepage: https://github.com/MESAHub/mesa_test.

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

CLI commands (all defined in [bin/mesa_test](bin/mesa_test)): `test`, `submit`, `checkout`, `install`, `install_and_test`, `setup`, `search`, `count`. Run `mesa_test help <cmd>` for details. `search` and `count` are read-only query commands that hit the testhub's search API and emit raw JSON to stdout (suitable for `jq` pipelines).

## Submission targets

Two different servers are involved:

1. **MESATestHub** — JSON API. URI selected by `MesaTestSubmitter::DEFAULT_URI` = `https://testhub.mesastar.org`. Two auth styles, both plaintext:
   - **Submission flow** — `POST /check_computer.json`, `POST /submissions/create.json`. Auth via a `submitter` object (`email` + `password` + `computer` + `platform_version`) in the JSON request body, alongside commit/instance payload.
   - **Search flow** — `GET /test_instances/search.json`, `GET /test_instances/search_count.json`. Auth via `email` and `password` *query parameters* (HTTPS-only); the search itself rides in `query_text`. Successful responses are `{"results": [...], "failures": [...]}` where `failures` lists query clauses the server's parser rejected. Always surface `failures` to the user — a typo in a key silently drops the clause, so the CLI echoes it to STDERR. Bad creds come back as HTTP 422 with `{"error":"Invalid e-mail or password."}`.
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

There is no automated test suite. Validation is manual: flip `MODE` to `:development` or `:staging`, point at a local MESATestHub, and exercise the CLI against a real MESA checkout. Don't add fake unit tests just because they're conventional — the value here is end-to-end against an actual MESA install and testhub instance.

## Conventions worth knowing

- The library uses bare `bash_execute` / `bashticks` helpers (bottom of [lib/mesa_test.rb](lib/mesa_test.rb)) to force commands through `bash -c`, because MESA's build scripts assume bash.
- `Mesa#with_mesa_dir` temporarily mutates `ENV['MESA_DIR']` around a block and restores it — this is how the gem isolates MESA installs from the user's own `MESA_DIR`.
- Config is YAML at `~/.mesa_test/config.yml` (note the directory, not a dotfile in `$HOME` directly). `MesaTestSubmitter::new_from_config` runs the setup wizard automatically if the file is missing.
- Passwords and the logs API token are stored in plaintext in the config file. This is documented to the user in the setup wizard; don't try to "fix" it without a real plan for credential storage.
- GitHub access protocol (`:ssh` vs `:https`) is per-user config and affects how the mirror is cloned.
