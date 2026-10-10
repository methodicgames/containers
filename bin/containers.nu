#!/usr/bin/env -S nu --no-config-file
# SPDX-FileCopyrightText: 2026 Methodic Games LLC
# SPDX-License-Identifier: 0BSD

use diagnostics.nu fail
use publication.nu *
use registry.nu *
use releases.nu *
use versions.nu *
use smoke.nu smoke-image

const version_file = 'src/archlinux/VERSION'
const containerfile = 'src/archlinux/Containerfile'
const image_pin = 'ARG ARCH_IMAGE='
const default_image = 'ghcr.io/methodicgames/archlinux'

def variants [requested: string] {
    if $requested == 'all' {
        return ['base', 'dev']
    }
    if $requested in ['base', 'dev'] {
        return [$requested]
    }
    fail $"unknown variant ($requested); expected base, dev, or all" 2
}

def arch-snapshot [] {
    open --raw $version_file | str trim
}

# A release tag selects a release of the current Arch snapshot.
def current-release [release_tag: string] {
    let release = (parse-release-tag $release_tag)
    check-release-snapshot $release (arch-snapshot)
    $release
}

# Capture repository and environment inputs once at the command boundary.
# Commands that take a release tag pass it; others read RELEASE_TAG, which
# publication exports for its nested validation build.
def image-context [revision_default: string, --release-tag: string] {
    let release_tag = ($release_tag | default ($env.RELEASE_TAG? | default ''))
    let release = if ($release_tag | is-empty) {
        null
    } else {
        current-release $release_tag
    }

    {
        image: ($env.IMAGE? | default $default_image)
        snapshot: (arch-snapshot)
        release: $release
        revision: ($env.REVISION? | default $revision_default)
    }
}

def markdown-files [] {
    ^git ls-files --cached --others --exclude-standard -- '*.md'
    | lines
    | where {|file| not ($file | is-empty) and ($file | path exists) }
}

def archive-url [snapshot: string] {
    $"archive.archlinux.org/repos/((parse-snapshot $snapshot).path)/"
}

# Read the upstream image and Archive URL that the Containerfile pins. Source
# validation and update-arch both require exactly one well-formed pin of each.
def arch-pins [content: string] {
    let images = ($content | lines | where {|line| $line starts-with $image_pin })
    let archives = (
        $content
        | parse --regex '(?<url>archive[.]archlinux[.]org/repos/[0-9]{4}/[0-9]{2}/[0-9]{2}/)'
    )
    if ($images | length) != 1 or ($archives | length) != 1 {
        fail 'expected one upstream image and one Archive URL'
    }

    let image = ($images | first | str replace $image_pin '')
    let image_match = (
        $image
        | parse --regex '^docker[.]io/archlinux/archlinux:base-(?<snapshot>[0-9]{8})[.]0[.][0-9]+@sha256:[0-9a-f]{64}$'
    )
    if ($image_match | is-empty) {
        fail 'malformed pinned Arch image'
    }

    {image: $image, image_snapshot: $image_match.0.snapshot, archive: $archives.0.url}
}

def validate-source [] {
    let snapshot = (arch-snapshot)
    let content = (open --raw $containerfile)
    let pins = (arch-pins $content)
    if $pins.image_snapshot > $snapshot {
        fail $"upstream image is newer than Archive snapshot ($snapshot)"
    }
    if $pins.archive != (archive-url $snapshot) {
        fail 'Archive snapshot does not match the Arch version'
    }

    let lines = ($content | lines)
    if not ($lines | any {|line| $line == 'FROM ${ARCH_IMAGE} AS base' }) {
        fail 'base stage does not use the pinned Arch image'
    }
    if not ($lines | any {|line| $line == 'FROM base AS dev' }) {
        fail 'dev stage does not extend base'
    }
    if ($lines | any {|line| $line =~ '^FROM .* AS ci$' }) {
        fail 'unexpected ci stage'
    }
}

def "main format" [] {
    let markdown = (markdown-files)
    if not ($markdown | is-empty) {
        ^rumdl fmt ...$markdown
    }
    ^just --unstable --fmt
}

def "main validate" [] {
    validate-source
    ^just --unstable --fmt --check
    ^just test
    ^just test-registry

    ^nu --no-config-file bin/containers.nu build
    ^nu --no-config-file bin/containers.nu smoke

    let image_context = (image-context 'local')
    let lint_version = (build-version $image_context.release dev)
    let lint_image = $"($image_context.image):(image-tag dev $lint_version)"
    (
        ^podman run --rm
            --volume $"((pwd)):/src:ro"
            --workdir /src
            $lint_image
            nu --no-config-file bin/containers.nu lint
    )
}

def "main lint" [] {
    validate-source
    ^just --unstable --fmt --check

    let markdown = (markdown-files)
    if not ($markdown | is-empty) {
        ^rumdl check --no-cache ...$markdown
    }
    ^reuse --no-multiprocessing lint
    ^actionlint
}

def "main clean" [] {
    rm --recursive --force dst .tmp
}

def check-archive-snapshot [snapshot: string] {
    let archive = (archive-url $snapshot)
    let archive_result = (
        ^curl --fail --silent --output /dev/null --head
            $"https://($archive)core/os/x86_64/core.db"
        | complete
    )
    if $archive_result.exit_code != 0 {
        fail $"Arch snapshot ($snapshot) is unavailable"
    }

    $archive
}

def latest-arch-image [snapshot: string] {
    let response = (
        ^curl --fail --silent --show-error --get
            --data-urlencode $"name=base-($snapshot).0."
            --data-urlencode page_size=100
            https://hub.docker.com/v2/repositories/archlinux/archlinux/tags
        | complete
    )
    if $response.exit_code != 0 {
        print --stderr ($response.stderr | str trim)
        exit $response.exit_code
    }
    let entries = (
        $response.stdout
        | from json
        | get results
        | where {|result|
                let name_matches = (
                    $result.name =~ $"^base-($snapshot)[.]0[.][0-9]+$"
                )
                let digest_matches = (
                    ($result.digest? | default '') =~ '^sha256:[0-9a-f]{64}$'
                )
                $name_matches and $digest_matches
            }
        | each {|result|
                {
                    name: $result.name
                    digest: $result.digest
                    job: ($result.name | split row '.' | last | into int)
                }
            }
    )
    if ($entries | is-empty) {
        fail $"no upstream Arch image found for ($snapshot)"
    }
    $entries | sort-by job | last
}

def "main update-arch" [snapshot: string] {
    let archive = (check-archive-snapshot $snapshot)
    let entry = (latest-arch-image $snapshot)

    let upstream = $"docker.io/archlinux/archlinux:($entry.name)@($entry.digest)"
    let content = (open --raw $containerfile)
    let pins = (arch-pins $content)
    let version_is_current = (arch-snapshot) == $snapshot
    if $pins.image == $upstream and $pins.archive == $archive and $version_is_current {
        print $"Arch inputs are already current for ($snapshot)"
        return
    }

    let updated = (
        $content
        | str replace $"($image_pin)($pins.image)" $"($image_pin)($upstream)"
        | str replace $pins.archive $archive
    )
    $updated | save --force $containerfile
    $"($snapshot)\n" | save --force $version_file
    print $"Updated Arch ($snapshot) from ($entry.name)"
}

def "main validate-release" [release_tag: string] {
    let release = (current-release $release_tag)
    let revision = (check-pushed-release $release)

    let outputs = [
        $"date=($release.date)"
        $"revision=($revision)"
        $"variant=($release.variant)"
        $"version=($release.version)"
    ]
    let output = ($outputs | str join (char newline)) + (char newline)
    $output | save --append $env.GITHUB_OUTPUT
    print ($release | select variant date version | insert revision $revision | to json --raw)
}

def "main release" [release_tag: string] {
    let release = (current-release $release_tag)
    create-release-tag $release
    print $"Created ($release.tag); push it with:"
    print $"git push origin refs/tags/($release.tag)"
}

def "main build" [requested: string = 'all'] {
    let image_context = (image-context 'local')
    if $image_context.release != null {
        check-release-source $image_context.release $image_context.revision
    }
    for target in (variants $requested) {
        let version = (build-version $image_context.release $target)
        (
            ^podman build
                --file $containerfile
                --platform linux/amd64
                --target $target
                --build-arg $"VERSION=($version)"
                --build-arg $"REVISION=($image_context.revision)"
                --tag $"($image_context.image):(image-tag $target $version)"
                src/archlinux
        )
    }
}

def "main smoke" [requested: string = 'all'] {
    let image_context = (image-context 'local')
    let source = (pwd)

    for variant in (variants $requested) {
        smoke-image $image_context $variant $source
    }
}

def "main smoke-job" [] {
    ^nu --no-config-file bin/runtime-checks.nu job
}

def "main smoke-release" [release_tag: string, revision: string] {
    # A historical release may predate the current snapshot.
    let release = (parse-release-tag $release_tag)
    if not (is-git-revision $revision) {
        fail 'release smoke requires a full Git commit ID'
    }
    if (^git cat-file -t $revision | str trim) != 'commit' {
        fail 'release smoke requires a Git commit object'
    }

    let directory = ('.tmp/release-smoke' | path join (random uuid) | path expand)
    let source = ($directory | path join 'source')
    let archive = ($directory | path join 'source.tar')
    mkdir $source
    ^git archive --format=tar --output $archive $revision
    ^tar --extract --file $archive --directory $source

    # Only the historical smoke recipe runs here.
    with-env {RELEASE_TAG: $release.tag, REVISION: $revision} {
        cd $source
        ^just smoke $release.variant
    }
}

def anonymous-verify [image: string, tag: string, digest: string] {
    let client = (registry-context $image --anonymous)
    verify-manifest $client $tag $digest

    let authfile = '.tmp/anonymous-pull/auth.json'
    mkdir ($authfile | path dirname)
    '{"auths":{}}' | save --force $authfile
    without-host-registries {
        (
            ^podman pull --authfile $authfile
                --tls-verify=(not $client.loopback)
                $"($image)@($digest)"
        )
    }
    verify-manifest $client $tag $digest
}

def "main smoke-published" [release_tag: string] {
    let image_context = (image-context '' --release-tag $release_tag)
    let release = $image_context.release
    let image = $image_context.image
    let client = (registry-context $image --anonymous)
    let artifact = (lookup-artifact $client $release.image_tag)
    if $artifact == null {
        fail $"release ($release.image_tag) is absent"
    }

    check-artifact $artifact $release.variant
    if $artifact.version != $release.version {
        fail 'release version mismatch'
    }
    anonymous-verify $image $release.image_tag $artifact.digest

    let lookup = {|tag| lookup-artifact $client $tag }
    let decisions = (plan-aliases $artifact $lookup)
    for decision in $decisions {
        if $decision.action == 'promote' {
            fail $"alias ($decision.tag) is absent or older than the release"
        }
        anonymous-verify $image $decision.tag $decision.digest
        print $"($decision.tag): ($decision.action) at ($decision.digest)"
    }
}

def "main publish" [release_tag: string] {
    # Nested validation builds and smoke-tests the release named by RELEASE_TAG.
    load-env {RELEASE_TAG: $release_tag}
    let image_context = (image-context '' --release-tag $release_tag)
    if not (is-git-revision $image_context.revision) {
        fail 'publication requires REVISION as a full Git object ID'
    }
    check-release-source $image_context.release $image_context.revision

    let expected = {
        image: $image_context.image
        variant: $image_context.release.variant
        version: $image_context.release.version
        revision: $image_context.revision
    }

    let client = (registry-context $image_context.image)
    let backend = {
        lookup: {|tag| lookup-artifact $client $tag }
        create: {|tag|
            ^just validate

            # Recheck after the build; this does not replace the workflow lock.
            if (read-manifest $client $tag) != null {
                fail 'release appeared during validation; retry to inspect it'
            }

            mkdir .tmp/publication
            let digestfile = $".tmp/publication/($tag).digest"
            without-host-registries {
                (
                    ^podman push --tls-verify=(not $client.loopback)
                        --digestfile $digestfile
                        $"($image_context.image):($tag)"
                )
            }
            let digest = (open --raw $digestfile | str trim)
            verify-manifest $client $tag $digest
            lookup-artifact $client $tag
        }
        smoke: {|artifact|
            let reference = $"($image_context.image)@($artifact.digest)"
            without-host-registries {
                ^podman pull --tls-verify=(not $client.loopback) $reference
            }
            ^podman tag $reference $"($image_context.image):(image-tag $artifact.variant $artifact.version)"
            # The checkout is the artifact's revision, so its own checks apply.
            smoke-image $image_context $artifact.variant (pwd)
        }
        promote: {|tag, artifact| promote-manifest $client $tag $artifact }
        verify: {|tag, digest| anonymous-verify $image_context.image $tag $digest }
    }

    let publication = (publish-release $expected $backend)
    if ($env.GITHUB_OUTPUT? | default '') != '' {
        $"digest=($publication.digest)\n" | save --append $env.GITHUB_OUTPUT
    }
    print ($publication | to json)
}

def main [] {
    print 'Run just --list to see the public commands.'
}
