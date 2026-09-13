#!/usr/bin/env -S nu --no-config-file

use std/assert
use ../bin/publication.nu *
use support.nu *

def artifact [version: string = '2026.09.01-2', seed: string = 'original'] {
    {
        image: '127.0.0.1:5000/test'
        source: 'https://github.com/methodicgames/containers'
        variant: 'dev'
        architecture: 'amd64'
        os: 'linux'
        version: $version
        revision: ('a' | fill --width 40 --character a)
        digest: $"sha256:($seed | hash sha256)"
    }
}

def fault [file: path, point: string] {
    let state = (open $file)
    if $state.failure == $point {
        $state | update failure '' | save --force $file
        error make {msg: $"injected failure at ($point)"}
    }
}

def publication-fixture [candidate: record, releases: record = {}, failure: string = ''] {
    let directory = (test-directory 'publication-tests')
    let file = ($directory | path join 'state.json')
    {
        tags: $releases
        creates: 0
        promotions: []
        smokes: []
        receipts: []
        failure: $failure
    }
    | to json | save $file

    {
        file: $file
        backend: {
            lookup: {|tag|
                fault $file 'lookup'
                open $file | get tags | get -o $tag
            }
            create: {|tag|
                fault $file 'create:before'
                mut state = (open $file)
                $state.creates = $state.creates + 1
                $state.tags = ($state.tags | upsert $tag $candidate)
                $state | to json | save --force $file
                fault $file 'create:after'
                $candidate
            }
            smoke: {|artifact|
                fault $file 'smoke'
                mut state = (open $file)
                $state.smokes = ($state.smokes | append $artifact.digest)
                $state | to json | save --force $file
            }
            promote: {|tag, artifact|
                fault $file $"($tag):before"
                mut state = (open $file)
                $state.tags = ($state.tags | upsert $tag $artifact)
                $state.promotions = ($state.promotions | append $tag)
                $state | to json | save --force $file
                fault $file $"($tag):after"
            }
            verify: {|tag, digest|
                fault $file $"verify:($tag)"
                assert equal (open $file | get tags | get $tag | get digest) $digest
            }
            receipt: {|receipt|
                mut state = (open $file)
                $state.receipts = ($state.receipts | append $receipt)
                $state | to json | save --force $file
            }
        }
    }
}

def initial-and-retry [] {
    let candidate = (artifact)
    let initial = (publication-fixture $candidate)
    let first_receipt = (publish-release $candidate $initial.backend)

    assert equal $first_receipt.status 'complete'
    assert equal (open $initial.file | get creates) 1
    assert equal (open $initial.file | get promotions) ['dev-2026.09.01' 'dev']

    # Rebuilding would produce different bytes. A retry must retain the first digest.
    let rebuilt = (artifact '2026.09.01-2' 'rebuilt')
    let retry = (publication-fixture $rebuilt (open $initial.file | get tags))
    let retry_receipt = (publish-release $rebuilt $retry.backend)

    assert equal $retry_receipt.digest $candidate.digest
    assert equal (open $retry.file | get creates) 0
    assert equal (open $retry.file | get promotions) []
    assert equal (open $retry.file | get smokes) [$candidate.digest]
}

def interrupted-publication [] {
    let candidate = (artifact)

    let failure_points = [
        'lookup'
        'create:before'
        'create:after'
        'smoke'
        'verify:dev-2026.09.01-2'
        'dev-2026.09.01:before'
        'dev-2026.09.01:after'
        'verify:dev-2026.09.01'
        'dev:before'
        'dev:after'
        'verify:dev'
    ]

    for point in $failure_points {
        let recovery = (publication-fixture $candidate {} $point)
        rejects { publish-release $candidate $recovery.backend } 'injected failure'

        let receipt = (publish-release $candidate $recovery.backend)
        let state = (open $recovery.file)
        assert equal $receipt.status 'complete'
        assert equal $state.creates 1
        assert equal ($state.tags | columns | length) 3
        for entry in ($state.tags | values) {
            assert equal $entry.digest $candidate.digest
        }
        assert equal $state.promotions ['dev-2026.09.01' 'dev']
    }
}

def alias-ordering [] {
    let candidate = (artifact)
    let newer = (artifact '2026.09.01-10' 'newer')
    let future = (artifact '2026.10.01-1' 'future')
    let seeded = {
        'dev-2026.09.01': $newer
        dev: $future
        'dev-2026.09.01-10': $newer
        'dev-2026.10.01-1': $future
    }
    let late = (publication-fixture $candidate $seeded)
    let late_receipt = (publish-release $candidate $late.backend)

    assert equal ($late_receipt.aliases | get action) ['retained' 'retained']
    assert equal (open $late.file | get promotions) []

    let old = (artifact '2026.09.01-1' 'older')
    assert equal (alias-action $old $candidate --dated) 'promote'
    assert equal (alias-action $candidate $newer --dated) 'promote'
    assert equal (alias-action $future $candidate) 'retained'

    # Repair this date without rolling back the floating alias from a newer date.
    let repair = (publication-fixture $candidate {dev: $future, 'dev-2026.10.01-1': $future})
    publish-release $candidate $repair.backend | ignore
    assert equal (open $repair.file | get promotions) ['dev-2026.09.01']
}

def artifact-conflicts [] {
    let candidate = (artifact)

    for field in ['revision' 'version' 'source' 'variant' 'architecture' 'os'] {
        let bad = ($candidate | update $field 'conflict')
        let conflict = (publication-fixture $candidate {'dev-2026.09.01-2': $bad})
        rejects { publish-release $candidate $conflict.backend } ''

        assert equal (open $conflict.file | get creates) 0
        assert equal (open $conflict.file | get promotions) []
    }
}

def alias-conflicts [] {
    let candidate = (artifact)
    let rebuilt = (artifact '2026.09.01-2' 'rebuilt')
    let future = (artifact '2026.10.01-1' 'future')

    rejects { alias-action $rebuilt $candidate } 'conflicting manifest digests'
    rejects { alias-action $future $candidate --dated } 'different snapshot'
    let bad_alias = (publication-fixture $candidate {'dev-2026.09.01-2': $candidate, dev: $rebuilt})
    rejects { publish-release $candidate $bad_alias.backend } 'conflicting manifest digests'
    assert equal (open $bad_alias.file | get promotions) []

    let orphan = (publication-fixture $candidate {dev: $future})
    rejects { publish-release $candidate $orphan.backend } 'does not match its immutable release'
    assert equal (open $orphan.file | get promotions) []
}

def main [] {
    run-tests 'publication' {
        'initial publication and retry': { initial-and-retry }
        'recovery after each interruption': { interrupted-publication }
        'numeric ordering and snapshot aliases': { alias-ordering }
        'conflicting artifact metadata': { artifact-conflicts }
        'conflicting and orphaned aliases': { alias-conflicts }
    }
}
