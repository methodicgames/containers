#!/usr/bin/env -S nu --no-config-file

use publication.nu *
use registry.nu *
use versions.nu *
use smoke.nu smoke-image

def fail [message: string, code: int = 1] {
    print --stderr $"error: ($message)"
    exit $code
}

def variants [requested: string] {
    if $requested == 'all' {
        return ['base', 'dev']
    }
    if $requested in ['base', 'dev'] {
        return [$requested]
    }
    fail $"unknown variant ($requested); expected base, dev, or all" 2
}

def publication-variants [requested: string, release_variant: string] {
    if $requested == 'all' {
        return [$release_variant]
    }
    if $requested != $release_variant {
        fail $"release tag selects ($release_variant), not ($requested)"
    }
    [$requested]
}

def local-release-tags [variant: string, date: string] {
    ^git tag --list $"archlinux/($variant)-($date)-*"
    | lines
    | where {|tag| not ($tag | is-empty) }
}

def remote-release-tags [variant: string, date: string] {
    let result = (
        ^git ls-remote --tags --refs origin $"refs/tags/archlinux/($variant)-($date)-*"
        | complete
    )
    if $result.exit_code != 0 {
        print --stderr ($result.stderr | str trim)
        exit $result.exit_code
    }
    $result.stdout
    | lines
    | where {|line| not ($line | is-empty) }
    | each {|line|
            $line
            | split row (char tab)
            | last
            | str replace 'refs/tags/' ''
        }
}

# Capture repository and environment inputs once at the command boundary.
def image-context [revision_default: string] {
    let snapshot = (open --raw src/archlinux/VERSION | str trim)
    let release_tag = ($env.RELEASE_TAG? | default '')
    let release = if ($release_tag | is-empty) {
        null
    } else {
        let parsed = (parse-release-tag $release_tag)
        check-release-snapshot $parsed $snapshot
        $parsed
    }

    {
        image: ($env.IMAGE? | default 'ghcr.io/methodicgames/archlinux')
        snapshot: $snapshot
        release: $release
        version: (if $release == null { 'local' } else { $release.version })
        revision: ($env.REVISION? | default $revision_default)
    }
}

def validate-revision [revision: string] {
    if not ($revision | is-empty) and not (is-git-revision $revision) {
        fail 'REVISION must be a full hexadecimal Git object ID'
    }
}

def markdown-files [] {
    ^git ls-files --cached --others --exclude-standard -- '*.md'
    | lines
    | where {|file| not ($file | is-empty) and ($file | path exists) }
}

def validate-source [] {
    let snapshot = (open --raw src/archlinux/VERSION | str trim)
    let snapshot_path = (parse-snapshot $snapshot).path
    let containerfile = 'src/archlinux/Containerfile'
    let content = (open --raw $containerfile)
    let upstream = (
        $content
        | lines
        | where {|line| $line starts-with 'ARG ARCH_IMAGE=' }
    )
    if ($upstream | length) != 1 {
        fail 'malformed pinned Arch image'
    }
    let image_pattern = 'ARG ARCH_IMAGE=docker[.]io/archlinux/archlinux:base-(?<snapshot>[0-9]{8})[.]0[.][0-9]+@sha256:[0-9a-f]{64}'
    let image_match = (
        $upstream | first | parse --regex $"^($image_pattern)$"
    )
    if ($image_match | is-empty) {
        fail 'malformed pinned Arch image'
    }
    if $image_match.0.snapshot > $snapshot {
        fail $"upstream image is newer than Archive snapshot ($snapshot)"
    }

    let lines = ($content | lines)
    let archive = $"archive.archlinux.org/repos/($snapshot_path)/"
    if not ($content | str contains $archive) {
        fail 'Archive snapshot does not match the Arch version'
    }
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
    let lint_image = $"($image_context.image):dev-($image_context.version)"
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
    # CHECK: Remove this exact diagnostic exception when actionlint supports queue.
    # https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency#example-queueing-multiple-pending-runs
    (
        ^actionlint -ignore '^unexpected key "queue" for "concurrency" section[.] expected one of "cancel-in-progress", "group"$'
            .github/workflows/containers.yaml
    )
}

def "main clean" [] {
    rm --recursive --force dst .tmp
}

def check-archive-snapshot [snapshot: string] {
    let snapshot_path = (parse-snapshot $snapshot).path
    let archive = $"archive.archlinux.org/repos/($snapshot_path)/"
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

    let containerfile = 'src/archlinux/Containerfile'
    let version_file = 'src/archlinux/VERSION'
    let upstream = $"docker.io/archlinux/archlinux:($entry.name)@($entry.digest)"
    let current_version = (open --raw $version_file | str trim)
    let content = (open --raw $containerfile)

    let image_is_current = (
        $content | lines | any {|line| $line == $"ARG ARCH_IMAGE=($upstream)" }
    )
    let archive_is_current = ($content | str contains $archive)
    let version_is_current = $current_version == $snapshot
    if $image_is_current and $archive_is_current and $version_is_current {
        print $"Arch inputs are already current for ($snapshot)"
        return
    }

    let lines = ($content | lines)
    let image_count = (
        $lines | where {|line| $line starts-with 'ARG ARCH_IMAGE=' } | length
    )
    let archive_count = (
        $lines
        | where {|line|
                $line =~ 'archive[.]archlinux[.]org/repos/[0-9]{4}/[0-9]{2}/[0-9]{2}/'
            }
        | length
    )
    if $image_count != 1 or $archive_count != 1 {
        fail 'expected one upstream image and one Archive URL'
    }

    let updated = (
        $content
        | str replace --regex '(?m)^ARG ARCH_IMAGE=.*$' $"ARG ARCH_IMAGE=($upstream)"
        | str replace --regex 'archive[.]archlinux[.]org/repos/[0-9]{4}/[0-9]{2}/[0-9]{2}/' $archive
    )
    $updated | save --force $containerfile
    $"($snapshot)\n" | save --force $version_file
    print $"Updated Arch ($snapshot) from ($entry.name)"
}

def "main validate-release" [release_tag: string] {
    let release = (parse-release-tag $release_tag)
    check-release-snapshot $release (open --raw src/archlinux/VERSION | str trim)

    let tag_ref = $"refs/tags/($release.tag)"
    let exists = (^git show-ref --verify --quiet $tag_ref | complete)
    if $exists.exit_code != 0 {
        fail $"release tag ($release.tag) is not present"
    }
    let object_type = (^git cat-file -t $tag_ref | str trim)
    if $object_type != 'tag' {
        fail $"release tag ($release.tag) must be annotated"
    }

    let tags = (local-release-tags $release.variant $release.date)
    validate-release-sequence $release.variant $release.date $tags | ignore

    let revision = (^git rev-list -n 1 $tag_ref | str trim)
    let on_main = (
        ^git merge-base --is-ancestor $revision refs/remotes/origin/main
        | complete
    )
    if $on_main.exit_code != 0 {
        fail $"release tag ($release.tag) does not target a commit on origin/main"
    }

    let tag_object = (^git rev-parse $tag_ref | str trim)
    let metadata = (
        ^curl --fail --silent --show-error
            --header 'Accept: application/vnd.github+json'
            --header $"Authorization: Bearer ($env.TAG_API_TOKEN)"
            --header 'X-GitHub-Api-Version: 2026-03-10'
            $"($env.GITHUB_API_URL)/repos/($env.GITHUB_REPOSITORY)/git/tags/($tag_object)"
        | from json
    )
    if not $metadata.verification.verified {
        fail $"GitHub did not verify the release-tag signature: ($metadata.verification.reason)"
    }

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
    let release = (parse-release-tag $release_tag)
    check-release-snapshot $release (open --raw src/archlinux/VERSION | str trim)

    let status = (^git status --porcelain | str trim)
    if not ($status | is-empty) {
        fail 'release tags require a clean worktree'
    }

    let branch = (^git symbolic-ref --quiet --short HEAD | complete)
    if $branch.exit_code != 0 or ($branch.stdout | str trim) != 'main' {
        fail 'release tags must be created from the main branch'
    }

    let remote_main = (
        ^git ls-remote --heads origin refs/heads/main
        | complete
    )
    if $remote_main.exit_code != 0 {
        print --stderr ($remote_main.stderr | str trim)
        exit $remote_main.exit_code
    }
    if ($remote_main.stdout | str trim | is-empty) {
        fail 'origin/main is unavailable'
    }
    let remote_revision = (
        $remote_main.stdout
        | lines
        | first
        | split row (char tab)
        | first
    )
    let revision = (^git rev-parse HEAD | str trim)
    if $revision != $remote_revision {
        fail 'main must exactly match origin/main before creating a release tag'
    }

    let local_tag = (
        ^git show-ref --verify --quiet $"refs/tags/($release.tag)"
        | complete
    )
    if $local_tag.exit_code == 0 {
        fail $"release tag ($release.tag) already exists locally"
    }

    let remote_tags = (
        remote-release-tags $release.variant $release.date
    )
    let sequences = (
        validate-release-sequence $release.variant $release.date $remote_tags
    )
    let expected = ($sequences | length) + 1
    if $release.sequence != $expected {
        fail $"next release for ($release.variant) on ($release.date) must be archlinux/($release.variant)-($release.date)-($expected)"
    }

    ^git tag --sign --annotate $release.tag --message $"Release ($release.version)"
    ^git verify-tag $release.tag
    print $"Created ($release.tag); push it with:"
    print $"git push origin refs/tags/($release.tag)"
}

def "main build" [requested: string = 'all'] {
    let image_context = (image-context 'local')
    for target in (variants $requested) {
        (
            ^podman build
                --file src/archlinux/Containerfile
                --platform linux/amd64
                --target $target
                --build-arg $"VERSION=($image_context.version)"
                --build-arg $"REVISION=($image_context.revision)"
                --tag $"($image_context.image):($target)-($image_context.version)"
                src/archlinux
        )
    }
}

def "main tag" [requested: string = 'all'] {
    let image_context = (image-context '')
    validate-revision $image_context.revision
    if $image_context.release == null {
        fail 'RELEASE_TAG is required to create publication aliases'
    }

    for target in (publication-variants $requested $image_context.release.variant) {
        let source = $"($image_context.image):($target)-($image_context.version)"
        ^podman image exists $source
        for alias in (release-aliases $target $image_context.version) {
            ^podman tag $source $"($image_context.image):($alias.tag)"
        }
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

    # Only the historical smoke recipe runs here. Registry writes remain current.
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
    (
        ^podman pull --authfile $authfile
            --tls-verify=(not $client.loopback)
            $"($image)@($digest)"
    )
    verify-manifest $client $tag $digest
}

def "main smoke-published" [release_tag: string] {
    let release = (parse-release-tag $release_tag)
    check-release-snapshot $release (open --raw src/archlinux/VERSION | str trim)
    let image = ($env.IMAGE? | default 'ghcr.io/methodicgames/archlinux')
    let client = (registry-context $image --anonymous)
    let tag = $"($release.variant)-($release.version)"
    let artifact = (lookup-artifact $client $tag)
    if $artifact == null {
        fail $"release ($tag) is absent"
    }

    check-artifact $artifact $release
    if $artifact.version != $release.version {
        fail 'release version mismatch'
    }
    anonymous-verify $image $tag $artifact.digest

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

def "main publish" [requested: string = 'all'] {
    let image_context = (image-context '')
    if $image_context.release == null {
        fail 'RELEASE_TAG is required to publish images'
    }
    if not (is-git-revision $image_context.revision) {
        fail 'publication requires REVISION as a full Git object ID'
    }
    publication-variants $requested $image_context.release.variant | ignore

    let expected = {
        image: $image_context.image
        variant: $image_context.release.variant
        version: $image_context.version
        revision: $image_context.revision
    }

    let client = (registry-context $image_context.image)
    let receipt_path = $"dst/publication/($expected.variant)-($expected.version).json"
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
            (
                ^podman push --tls-verify=(not $client.loopback)
                    --digestfile $digestfile
                    $"($image_context.image):($tag)"
            )
            let digest = (open --raw $digestfile | str trim)
            verify-manifest $client $tag $digest
            lookup-artifact $client $tag
        }
        smoke: {|artifact|
            let reference = $"($image_context.image)@($artifact.digest)"
            ^podman pull --tls-verify=(not $client.loopback) $reference
            ^podman tag $reference $"($image_context.image):($artifact.variant)-($artifact.version)"
            ^just smoke-release $image_context.release.tag $artifact.revision
        }
        promote: {|tag, artifact| promote-manifest $client $tag $artifact }
        verify: {|tag, digest| anonymous-verify $image_context.image $tag $digest }
        receipt: {|receipt|
            mkdir ($receipt_path | path dirname)
            $receipt | to json | save --force $receipt_path
        }
    }

    let receipt = (publish-release $expected $backend)
    if ($env.GITHUB_OUTPUT? | default '') != '' {
        $"digest=($receipt.digest)\n" | save --append $env.GITHUB_OUTPUT
    }
    print ($receipt | to json)
}

def main [] {
    print 'Run just --list to see the public commands.'
}
