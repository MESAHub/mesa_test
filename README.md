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
