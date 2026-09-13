#!/usr/bin/env -S nu --no-config-file

use std/assert
use support.nu *

def historical-fixture [] {
    let automation = ('bin/containers.nu' | path expand)
    let directory = (test-directory 'release-smoke-tests')
    let source = ($directory | path join 'repository')
    let receipt = ($directory | path join 'receipt.json')
    mkdir $source
    ^git init --quiet --object-format=sha1 $source
    cd $source

    'set shell := ["nu", "--no-config-file", "--commands"]
smoke variant:
    nu --no-config-file smoke.nu {{variant}}
' | save justfile

    'def main [variant: string] {
    if ($env.FAIL_RELEASE_SMOKE? | default "") == "yes" {
      error make {msg: "injected historical smoke failure"}
    }
    {
      variant: $variant
      release: $env.RELEASE_TAG
      revision: $env.REVISION
      snapshot: (open --raw src/archlinux/VERSION | str trim)
      directory: (pwd)
    }
    | to json | save --force $env.SMOKE_RECEIPT
  }
' | save smoke.nu

    mkdir src/archlinux
    "20000101\n" | save src/archlinux/VERSION
    ^git add -- justfile smoke.nu src/archlinux/VERSION
    let tree = (^git write-tree | str trim)

    # Create only a disposable fixture object, without signing or invoking hooks.
    let revision = (with-env {
        GIT_AUTHOR_NAME: 'Smoke Test'
        GIT_AUTHOR_EMAIL: 'smoke@example.invalid'
        GIT_COMMITTER_NAME: 'Smoke Test'
        GIT_COMMITTER_EMAIL: 'smoke@example.invalid'
    } {
        ^git -c commit.gpgsign=false commit-tree $tree -m 'Historical smoke fixture' | str trim
    })

    'error make {msg: "current worktree smoke must not run"}' | save --force smoke.nu

    {
        automation: $automation
        source: $source
        receipt: $receipt
        revision: $revision
    }
}

def historical-source-selection [] {
    let fixture = (historical-fixture)
    cd $fixture.source

    with-env {SMOKE_RECEIPT: $fixture.receipt, FAIL_RELEASE_SMOKE: ''} {
        (
            ^nu --no-config-file $fixture.automation smoke-release
                archlinux/dev-2000.01.01-1 $fixture.revision
        )
    }

    let receipt = (open $fixture.receipt)
    assert equal $receipt.variant 'dev'
    assert equal $receipt.release 'archlinux/dev-2000.01.01-1'
    assert equal $receipt.revision $fixture.revision
    assert equal $receipt.snapshot '20000101'
    assert ($receipt.directory != $fixture.source)
}

def smoke-failure-propagation [] {
    let fixture = (historical-fixture)
    cd $fixture.source

    let failure = (with-env {SMOKE_RECEIPT: $fixture.receipt, FAIL_RELEASE_SMOKE: 'yes'} {
        (
            ^nu --no-config-file $fixture.automation smoke-release
                archlinux/dev-2000.01.01-1 $fixture.revision
            | complete
        )
    })

    assert ($failure.exit_code != 0)
    assert ($failure.stderr | str contains 'injected historical smoke failure')
}

def main [] {
    run-tests 'release smoke' {
        'historical source selection': { historical-source-selection }
        'historical smoke failure propagation': { smoke-failure-propagation }
    }
}
