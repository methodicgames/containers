# Resumable publication policy, independent of registry transport.

use versions.nu *

# Artifacts contain source, variant, architecture, os, revision, version, digest.
# Expected releases contain image, variant, version, revision.
export def check-artifact [artifact: record, expected: record, --exact] {
    let identity_matches = (
        $artifact.source == 'https://github.com/methodicgames/containers'
        and $artifact.variant == $expected.variant
        and $artifact.architecture == 'amd64'
        and $artifact.os == 'linux'
    )
    if not $identity_matches {
        error make {msg: 'published image has conflicting source, variant, or platform'}
    }

    if not (is-git-revision $artifact.revision) {
        error make {msg: 'published image has an invalid revision'}
    }
    if not ($artifact.digest =~ '^sha256:[0-9a-f]{64}$') {
        error make {msg: 'published image has an invalid manifest digest'}
    }

    parse-published-version $artifact.version | ignore
    if $exact and (
        $artifact.version != $expected.version
        or $artifact.revision != $expected.revision
    ) {
        error make {msg: 'release tag already identifies a different version or revision'}
    }
}

export def alias-action [current: any, candidate: record, --dated] {
    if $current == null {
        return 'promote'
    }

    check-artifact $current $candidate
    let current_version = (parse-published-version $current.version)
    let candidate_version = (parse-published-version $candidate.version)

    if $dated and $current_version.date != $candidate_version.date {
        error make {msg: 'date alias points to a different snapshot'}
    }

    if $current.version == $candidate.version {
        if $current.digest != $candidate.digest {
            error make {msg: 'equal versions have conflicting manifest digests'}
        }
        return 'unchanged'
    }

    let newer_date = $current_version.date > $candidate_version.date
    let newer_sequence = (
        $current_version.date == $candidate_version.date
        and $current_version.sequence > $candidate_version.sequence
    )
    if $newer_date or $newer_sequence {
        return 'retained'
    }

    'promote'
}

# lookup(tag) returns an artifact or null. Inspect all aliases before any write.
# Each decision contains tag, action, and the digest expected after publication.
export def plan-aliases [candidate: record, lookup: closure] {
    release-aliases $candidate.variant $candidate.version | each {|alias|
        let current = (do $lookup $alias.tag)
        let action = (alias-action $current $candidate --dated=$alias.dated)

        if $current != null {
            let release_tag = $"($current.variant)-($current.version)"
            let reference = (do $lookup $release_tag)
            if $reference == null or $reference.digest != $current.digest {
                error make {msg: $"alias ($alias.tag) does not match its immutable release"}
            }
        }

        let digest = if $action == 'retained' {
            $current.digest
        } else {
            $candidate.digest
        }

        {tag: $alias.tag, action: $action, digest: $digest}
    }
}

# Backend contract:
# - lookup(tag) -> artifact or null; only a missing manifest returns null.
# - create(tag) -> the authoritative artifact after validation and upload.
# - smoke(artifact) -> validate runtime behavior without replacing the release.
# - promote(tag, artifact) -> copy the artifact's exact manifest to an alias.
# - verify(tag, digest) -> verify anonymous access and digest identity.
# - receipt(record) -> persist progress; it is diagnostic, not recovery input.
# Callback failures propagate, leaving registry state available for a retry.
export def publish-release [expected: record, backend: record] {
    let release_tag = $"($expected.variant)-($expected.version)"
    let existing = (do $backend.lookup $release_tag)
    let artifact = if $existing == null {
        do $backend.create $release_tag
    } else {
        $existing
    }
    check-artifact $artifact $expected --exact

    mut receipt = {
        image: $expected.image
        release: $release_tag
        revision: $expected.revision
        digest: $artifact.digest
        status: 'pending'
        aliases: []
    }
    do $backend.receipt $receipt
    do $backend.smoke $artifact

    let decisions = (plan-aliases $artifact $backend.lookup)
    $receipt.aliases = $decisions
    do $backend.receipt $receipt
    do $backend.verify $release_tag $artifact.digest

    for decision in $decisions {
        if $decision.action == 'promote' {
            do $backend.promote $decision.tag $artifact
        }
        do $backend.verify $decision.tag $decision.digest

        $receipt.aliases = ($receipt.aliases | each {|alias|
            if $alias.tag == $decision.tag {
                $alias | insert verified true
            } else {
                $alias
            }
        })
        do $backend.receipt $receipt
    }

    $receipt.status = 'complete'
    do $backend.receipt $receipt
    $receipt
}
