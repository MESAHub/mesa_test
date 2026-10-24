# MESATest
Command line tool for running the MESA test suite and uploading results to MESATestHub

I'll flesh this out later, but ideally you should install via

    gem install mesa_test
    
Then learn about the available commands via

    mesa_test help
    
For an individual command, call `help` with an argument:

    mesa_test help install

## Authenticating

Generate an API key for your computer on its page on
[MESATestHub](https://testhub.mesastar.org), then run `mesa_test setup` and
paste it when asked (or export `MESATESTHUB_API_KEY`). Email and password
still work if you'd rather not use a key.

## Letting MESATestHub choose what to test

    mesa_test install_and_test best

asks MESATestHub for the commit that most needs testing, builds it, and then
runs tests one at a time in the order (and modes, e.g. full inlists for
`[ci optional]` commits) it asks for, submitting each as it finishes. To just
see what it would pick:

    mesa_test request_work

On a cluster, where the build and the tests are separate jobs:

    mesa_test install best || exit   # exits 3 if nothing needs testing
    mesa_test submit --empty         # report the build
    # ...then array jobs, one per test:
    mesa_test test $N

`install` records the run modes it chose (FPE checks, optional inlists,
convergence) in the work directory's `testhub.yml`, so the `test` jobs pick
them up without extra flags.

## Running tests in parallel

By default tests run one after another, using your shell's
`OMP_NUM_THREADS`. To run several at once:

    mesa_test install_and_test main --build-threads 12 --jobs 4

- `--build-threads N`: cores for compiling MESA (default: all of them).
- `--jobs N`: how many tests run at the same time.
- `--test-threads N`: `OMP_NUM_THREADS` for each test. Leave it off and
  your `OMP_NUM_THREADS` (or, if unset, all cores) is split evenly across
  the jobs, so a value you set for serial runs keeps meaning "this many
  cores in total".

`mesa_test test` (with no test name) takes `--jobs` and `--test-threads`
too, and `install_and_test best` hands each of its `--jobs` workers its own
test. Each test's output goes to `each_test_run.log` in its directory, and
mesa_test prints a line as each finishes. Ctrl-C stops all running tests.

## Run modes

`--skip-optional` / `--no-skip-optional`, `--fpe` / `--no-fpe`, and
`--converge` / `--no-converge` control MESA's `MESA_SKIP_OPTIONAL`,
`MESA_FPE_CHECKS_ON`, and `MESA_TEST_SUITE_RESOLUTION_FACTOR`.

- **With `best`:** they say what this computer is willing to run when a
  commit asks for it. Defaults come from `capabilities` in your config
  (set by `mesa_test setup`).
- **Otherwise:** they set the mode directly. Anything you leave unset
  comes from what `install` recorded, then from your shell.
- **FPE checks** are compiled in, so they are fixed when MESA is installed.
- **Convergence factor:** `--resolution-factor 0.5` runs at a specific
  factor (and implies `--converge`). A commit can ask for one with
  `[ci converge 0.5]`; with `best`, that request wins over your own
  setting, and mesa_test says so when they differ.
