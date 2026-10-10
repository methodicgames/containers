#!/usr/bin/env -S nu --no-config-file
# SPDX-FileCopyrightText: 2026 Methodic Games LLC
# SPDX-License-Identifier: 0BSD

use std/assert
use support.nu *

# A disposable repository and bare origin with isolated Git configuration,
# a throwaway trusted SSH signing key, and an untrusted one. Callers load its
# environment before using Git.
def release-fixture [] {
    let automation = ('bin/containers.nu' | path expand)
    let directory = (test-directory 'release-tests')
    let origin = ($directory | path join 'origin.git')
    let source = ($directory | path join 'repository')
    let key = ($directory | path join 'signing-key')
    let untrusted_key = ($directory | path join 'untrusted-key')
    let signers = ($directory | path join 'allowed-signers')
    let config = ($directory | path join 'gitconfig')

    ^ssh-keygen -q -t ed25519 -N '' -C release-test -f $key
    ^ssh-keygen -q -t ed25519 -N '' -C untrusted-test -f $untrusted_key
    let public_key = (open --raw $"($key).pub" | str trim)
    let signer = $"release@example.invalid namespaces=\"git\" ($public_key)\n"
    $signer | save $signers

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
    $signer | save .git-signers
    # Signature checks keep operational state beneath the ignored .tmp/.
    "/.tmp/\n" | save .gitignore
    ^git add -- src/archlinux/VERSION .git-signers .gitignore
    ^git commit --quiet --message 'Release fixture'
    ^git push --quiet origin main

    {
        automation: $automation
        directory: $directory
        source: $source
        untrusted_key: $untrusted_key
        env: ($git_env | merge {
            GITHUB_OUTPUT: ($directory | path join 'github-output')
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

def signed-tag [tag: string, --key: string] {
    let options = if $key == null { [] } else { ['-c', $"user.signingKey=($key)"] }
    ^git ...$options tag --sign --annotate $tag --message $"Release ($tag)"
}

def local-commit [] {
    'change' | save --force change.txt
    ^git add -- change.txt
    ^git commit --quiet --message 'Local change'
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
    fails (run-automation $fixture validate-release 'archlinux/base-2000.01.01-1') 'does not target a commit on origin/main'
    assert equal (release-output $fixture) {}
}

def signature-rejections [] {
    let fixture = (release-fixture)
    load-env $fixture.env
    cd $fixture.source
    let tag = 'archlinux/dev-2000.01.01-1'

    ^git tag --annotate $tag --message 'Unsigned release'
    fails (run-automation $fixture validate-release $tag) 'must have an SSH signature'

    ^git tag --delete $tag | ignore
    signed-tag $tag --key $fixture.untrusted_key
    fails (run-automation $fixture validate-release $tag) 'is not signed by a key in refs/remotes/origin/main:.git-signers'

    # Removing a signer from main revokes it for tags on earlier commits.
    ^git tag --delete $tag | ignore
    signed-tag $tag
    '' | save --force .git-signers
    ^git commit --quiet --all --message 'Revoke release signer'
    ^git push --quiet origin main
    fails (run-automation $fixture validate-release $tag) 'is not signed by a key in refs/remotes/origin/main:.git-signers'
    assert equal (release-output $fixture) {}
}

# Builds read the release from the environment; publication takes it as an
# argument.
def release-source-invocation [command: string, tag: string] {
    if $command == 'build' {
        {arguments: [build dev], env: {RELEASE_TAG: $tag}}
    } else {
        {arguments: [publish $tag], env: {}}
    }
}

def rejects-release-source [
    fixture: record
    command: string
    tag: string
    revision: string
    message: string
] {
    let invocation = (release-source-invocation $command $tag)
    with-env ($invocation.env | merge {REVISION: $revision}) {
        fails (run-automation $fixture ...$invocation.arguments) $message
    }
}

# Both commands must reject the source before building or contacting a registry.
def release-build-source [] {
    let fixture = (release-fixture)
    load-env $fixture.env
    cd $fixture.source
    let head = (^git rev-parse HEAD | str trim)
    let tag = 'archlinux/dev-2000.01.01-1'

    for command in [build publish] {
        'draft' | save untracked.txt
        rejects-release-source $fixture $command $tag $head 'require a clean worktree'
        rm untracked.txt

        local-commit
        rejects-release-source $fixture $command $tag $head 'require REVISION to be the checked-out commit'
        ^git reset --quiet --hard $head

        rejects-release-source $fixture $command $tag $head 'is not present'

        ^git tag $tag
        rejects-release-source $fixture $command $tag $head 'must be annotated'
        ^git tag --delete $tag | ignore

        # The tag must identify the commit whose source the image records.
        signed-tag $tag
        local-commit
        let moved = (^git rev-parse HEAD | str trim)
        rejects-release-source $fixture $command $tag $moved 'does not target REVISION'
        ^git reset --quiet --hard $head
        ^git tag --delete $tag | ignore

        signed-tag $tag --key $fixture.untrusted_key
        rejects-release-source $fixture $command $tag $head 'is not signed by a key in refs/remotes/origin/main:.git-signers'
        ^git tag --delete $tag | ignore

        # Builds and publication apply the same pushed-tag checks as the workflow.
        let gap = 'archlinux/dev-2000.01.01-2'
        signed-tag $gap
        rejects-release-source $fixture $command $gap $head 'skips 1'
        ^git tag --delete $gap | ignore

        local-commit
        signed-tag $tag
        let unpublished = (^git rev-parse HEAD | str trim)
        rejects-release-source $fixture $command $tag $unpublished 'does not target a commit on origin/main'
        ^git reset --quiet --hard $head
        ^git tag --delete $tag | ignore
    }
}

def untrusted-release-key [] {
    let fixture = (release-fixture)
    load-env $fixture.env
    cd $fixture.source
    ^git config --global user.signingKey $fixture.untrusted_key

    fails (run-automation $fixture release 'archlinux/dev-2000.01.01-1') 'is not signed by a key in HEAD:.git-signers'
    assert (^git tag --list | str trim | is-empty)
}

def main [] {
    run-tests 'release' {
        'next signed release tag': { next-release-tag }
        'release sequence rejections': { release-sequence-rejections }
        'release repository state': { release-repository-state }
        'verified release metadata': { verified-release }
        'release tag rejections': { release-tag-rejections }
        'signature rejections': { signature-rejections }
        'release build source': { release-build-source }
        'untrusted release key': { untrusted-release-key }
    }
}
