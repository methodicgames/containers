# SPDX-FileCopyrightText: 2026 Methodic Games LLC
# SPDX-License-Identifier: 0BSD

# Resumable publication policy, independent of registry transport.

use versions.nu *

# Artifacts contain source, variant, architecture, os, revision, version, digest.
# Check that an artifact is a well-formed image of this project and variant.
export def check-artifact [artifact: record, variant: string] {
    let identity_matches = (
        $artifact.source == 'https://github.com/methodicgames/containers'
        and $artifact.variant == $variant
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
}

export def alias-action [current: any, candidate: record, --dated] {
    if $current == null {
        return 'promote'
    }

    check-artifact $current $candidate.variant
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
            let immutable_tag = (image-tag $current.variant $current.version)
            let reference = (do $lookup $immutable_tag)
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
# Callback failures propagate, leaving registry state available for a retry.
# The expected release contains image, variant, version, and revision.
export def publish-release [expected: record, backend: record] {
    let immutable_tag = (image-tag $expected.variant $expected.version)
    let existing = (do $backend.lookup $immutable_tag)
    let artifact = if $existing == null {
        do $backend.create $immutable_tag
    } else {
        $existing
    }
    check-artifact $artifact $expected.variant
    if (
        $artifact.version != $expected.version
        or $artifact.revision != $expected.revision
    ) {
        error make {msg: 'release tag already identifies a different version or revision'}
    }

    do $backend.smoke $artifact

    let decisions = (plan-aliases $artifact $backend.lookup)
    do $backend.verify $immutable_tag $artifact.digest

    for decision in $decisions {
        if $decision.action == 'promote' {
            do $backend.promote $decision.tag $artifact
        }
        do $backend.verify $decision.tag $decision.digest
    }

    {
        image: $expected.image
        release: $immutable_tag
        revision: $expected.revision
        digest: $artifact.digest
        aliases: $decisions
    }
}
