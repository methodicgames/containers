#!/usr/bin/env -S nu --no-config-file
# SPDX-FileCopyrightText: 2026 Methodic Games LLC
# SPDX-License-Identifier: 0BSD

use std/assert
use support.nu *

const repository = 'methodicgames/containers'

# A disposable repository and bare origin with isolated Git configuration and
# a throwaway SSH signing key. Callers load its environment before using Git.
def release-fixture [] {
    let automation = ('bin/containers.nu' | path expand)
    let directory = (test-directory 'release-tests')
    let origin = ($directory | path join 'origin.git')
    let source = ($directory | path join 'repository')
    let key = ($directory | path join 'signing-key')
    let signers = ($directory | path join 'allowed-signers')
    let config = ($directory | path join 'gitconfig')

    ^ssh-keygen -q -t ed25519 -N '' -C release-test -f $key
    let public_key = (open --raw $"($key).pub" | str trim)
    $"release@example.invalid namespaces=\"git\" ($public_key)\n" | save $signers

    let git_env = {GIT_CONFIG_GLOBAL: $config, GIT_CONFIG_NOSYSTEM: '1'}
    load-env $git_env
    ^git config --global user.name 'Release Test'
    ^git config --global user.email 'release@example.invalid'
    ^git config --global init.defaultBranch main
    ^git config --global commit.gpgSign false
    ^git config --global gpg.format ssh
    ^git config --global user.signingKey $key
    ^git config --global gpg.ssh.allowedSignersFile $signers

    ^git init --quiet --bare $origin
    ^git init --quiet $source
    cd $source
    ^git remote add origin $origin
    mkdir src/archlinux
    "20000101\n" | save src/archlinux/VERSION
    ^git add -- src/archlinux/VERSION
    ^git commit --quiet --message 'Release fixture'
    ^git push --quiet origin main

    {
        automation: $automation
        directory: $directory
        source: $source
        env: ($git_env | merge {
            GITHUB_API_URL: $"file://($directory | path join 'api')"
            GITHUB_OUTPUT: ($directory | path join 'github-output')
            GITHUB_REPOSITORY: $repository
            TAG_API_TOKEN: 'test-token'
        })
    }
}

def run-automation [fixture: record, ...arguments: string] {
    ^nu --no-config-file $fixture.automation ...$arguments | complete
}

def succeeds [result: record] {
    assert equal $result.exit_code 0 $"unexpected failure: ($result.stderr)"
}

def fails [result: record, message: string] {
    assert ($result.exit_code != 0) $"expected failure: ($message)"
    assert ($result.stderr | str contains $message) $"unexpected failure: ($result.stderr)"
}

def signed-tag [tag: string] {
    ^git tag --sign --annotate $tag --message $"Release ($tag)"
}

def local-commit [] {
    'change' | save --force change.txt
    ^git add -- change.txt
    ^git commit --quiet --message 'Local change'
}

# Serve the GitHub tag-verification response that validate-release requests.
def tag-verification [fixture: record, tag: string, verified: bool] {
    let object = (^git rev-parse $"refs/tags/($tag)" | str trim)
    let file = (
        [$fixture.directory api repos $repository git tags $object] | path join
    )
    mkdir ($file | path dirname)
    let reason = if $verified { 'valid' } else { 'unsigned' }
    {verification: {verified: $verified, reason: $reason}} | to json | save $file
}

def release-output [fixture: record] {
    if not ($fixture.env.GITHUB_OUTPUT | path exists) {
        return {}
    }
    open --raw $fixture.env.GITHUB_OUTPUT
    | lines
    | parse '{key}={value}'
    | reduce --fold {} {|entry, output| $output | insert $entry.key $entry.value }
}

def next-release-tag [] {
    let fixture = (release-fixture)
    load-env $fixture.env
    cd $fixture.source

    signed-tag 'archlinux/dev-2000.01.01-1'
    ^git push --quiet origin 'refs/tags/archlinux/dev-2000.01.01-1'

    let result = (run-automation $fixture release 'archlinux/dev-2000.01.01-2')
    succeeds $result
    let tag = 'refs/tags/archlinux/dev-2000.01.01-2'
    assert equal (^git cat-file -t $tag | str trim) 'tag'
    succeeds (^git verify-tag 'archlinux/dev-2000.01.01-2' | complete)
    assert ($result.stdout | str contains $"git push origin ($tag)")
    assert (^git ls-remote --tags origin $tag | str trim | is-empty)

    # Each variant has its own sequence for the snapshot.
    succeeds (run-automation $fixture release 'archlinux/base-2000.01.01-1')
}

def release-sequence-rejections [] {
    let fixture = (release-fixture)
    load-env $fixture.env
    cd $fixture.source

    signed-tag 'archlinux/dev-2000.01.01-1'
    fails (run-automation $fixture release 'archlinux/dev-2000.01.01-1') 'already exists locally'

    # Only published tags count toward the next sequence.
    ^git tag --delete 'archlinux/dev-2000.01.01-1' | ignore
    fails (run-automation $fixture release 'archlinux/dev-2000.01.01-2') 'must be archlinux/dev-2000.01.01-1'
    fails (run-automation $fixture release 'archlinux/dev-2000.01.02-1') 'must match Arch snapshot date'
    assert (^git tag --list | str trim | is-empty)
}

def release-repository-state [] {
    let fixture = (release-fixture)
    load-env $fixture.env
    cd $fixture.source
    let tag = 'archlinux/dev-2000.01.01-1'

    'draft' | save untracked.txt
    fails (run-automation $fixture release $tag) 'clean worktree'
    rm untracked.txt

    ^git switch --quiet --create other
    fails (run-automation $fixture release $tag) 'main branch'
    ^git switch --quiet main

    local-commit
    fails (run-automation $fixture release $tag) 'exactly match origin/main'
    assert (^git tag --list | str trim | is-empty)
}

def verified-release [] {
    let fixture = (release-fixture)
    load-env $fixture.env
    cd $fixture.source
    let tag = 'archlinux/dev-2000.01.01-1'

    signed-tag $tag
    tag-verification $fixture $tag true
    succeeds (run-automation $fixture validate-release $tag)
    assert equal (release-output $fixture) {
        date: '2000.01.01'
        revision: (^git rev-parse HEAD | str trim)
        variant: 'dev'
        version: '2000.01.01-1'
    }
}

def release-tag-rejections [] {
    let fixture = (release-fixture)
    load-env $fixture.env
    cd $fixture.source

    fails (run-automation $fixture validate-release 'archlinux/dev-2000.01.01-1') 'is not present'

    ^git tag 'archlinux/dev-2000.01.01-1'
    fails (run-automation $fixture validate-release 'archlinux/dev-2000.01.01-1') 'must be annotated'

    signed-tag 'archlinux/base-2000.01.01-2'
    fails (run-automation $fixture validate-release 'archlinux/base-2000.01.01-2') 'skips 1'

    local-commit
    signed-tag 'archlinux/base-2000.01.01-1'
    tag-verification $fixture 'archlinux/base-2000.01.01-1' true
    fails (run-automation $fixture validate-release 'archlinux/base-2000.01.01-1') 'does not target a commit on origin/main'
    assert equal (release-output $fixture) {}
}

def signature-rejections [] {
    let fixture = (release-fixture)
    load-env $fixture.env
    cd $fixture.source
    let tag = 'archlinux/dev-2000.01.01-1'

    signed-tag $tag
    let unavailable = (run-automation $fixture validate-release $tag)
    assert ($unavailable.exit_code != 0) 'expected failure without a verification response'

    tag-verification $fixture $tag false
    fails (run-automation $fixture validate-release $tag) 'did not verify the release-tag signature'
    assert equal (release-output $fixture) {}
}

def main [] {
    run-tests 'release' {
        'next signed release tag': { next-release-tag }
        'release sequence rejections': { release-sequence-rejections }
        'release repository state': { release-repository-state }
        'verified release metadata': { verified-release }
        'release tag rejections': { release-tag-rejections }
        'signature rejections': { signature-rejections }
    }
}
