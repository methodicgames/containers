#!/usr/bin/env -S nu --no-config-file

use std/assert
use ../bin/versions.nu *
use support.nu *

def snapshot-dates [] {
    assert equal (parse-snapshot '20260901') {
        snapshot: '20260901'
        date: '2026.09.01'
        path: '2026/09/01'
    }
    rejects { parse-snapshot '2026-09-01' } 'expected YYYYMMDD'
    rejects { parse-snapshot '20260230' } ''
}

def release-parsing [] {
    # Parsing works without VERSION or any other repository state.
    let directory = (test-directory 'version-tests')
    cd $directory

    let release = (parse-release-tag 'archlinux/dev-2026.09.01-10')
    assert equal $release.variant 'dev'
    assert equal $release.version '2026.09.01-10'
    assert equal $release.sequence 10
    check-release-snapshot $release '20260901'

    rejects { check-release-snapshot $release '20260902' } 'must match Arch snapshot'
    rejects { parse-release-tag 'archlinux/other-2026.09.01-1' } 'invalid release tag'
    rejects { parse-published-version '2026.09.01-02' } 'invalid published version'
    rejects { parse-published-version '2026.02.30-1' } ''
}

def revision-identities [] {
    for width in [40 64] {
        assert (is-git-revision ('a' | fill --width $width --character a))
    }
    for width in [39 41 63 65] {
        assert (not (is-git-revision ('a' | fill --width $width --character a)))
    }
    assert (not (is-git-revision ('z' | fill --width 40 --character z)))
}

def release-sequences [] {
    let first = 'archlinux/dev-2026.09.01-1'
    let second = 'archlinux/dev-2026.09.01-2'
    assert equal (validate-release-sequence dev '2026.09.01' [$second $first]) [1 2]
    assert equal (validate-release-sequence dev '2026.09.01' []) []

    rejects {
        validate-release-sequence dev '2026.09.01' [$second]
    } 'skips 1'
    rejects {
        validate-release-sequence base '2026.09.01' [$first]
    } 'does not belong'
    rejects {
        validate-release-sequence dev '2026.09.02' [$first]
    } 'does not belong'
}

def alias-descriptors [] {
    assert equal (release-aliases dev '2026.09.01-10') [
        {tag: 'dev-2026.09.01', dated: true}
        {tag: 'dev', dated: false}
    ]
}

def main [] {
    run-tests 'versions' {
        'snapshot date parsing': { snapshot-dates }
        'release parsing and snapshot validation': { release-parsing }
        'full Git revision identities': { revision-identities }
        'gap-free release sequences': { release-sequences }
        'explicit alias scopes': { alias-descriptors }
    }
}
