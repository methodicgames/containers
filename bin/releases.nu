# SPDX-FileCopyrightText: 2026 Methodic Games LLC
# SPDX-License-Identifier: 0BSD

# Release trust: whether a release tag may be created, published, or built.
# Tag creation, the release workflow, release builds, and manual publication
# all apply these checks, and a rejection ends the command. Callers match the
# release to VERSION separately.

use diagnostics.nu fail
use versions.nu *

const trusted_ref = 'refs/remotes/origin/main'

def require-clean-worktree [subject: string] {
    if not (^git status --porcelain | str trim | is-empty) {
        fail $"($subject) require a clean worktree"
    }
}

# Git tag pattern for every release of this variant and snapshot date.
def series-pattern [release: record] {
    $"archlinux/($release.variant)-($release.date)-*"
}

def ls-remote [options: list<string>, pattern: string] {
    let result = (^git ls-remote ...$options origin $pattern | complete)
    if $result.exit_code != 0 {
        print --stderr ($result.stderr | str trim)
        fail 'cannot read origin'
    }

    $result.stdout
    | lines
    | where {|line| not ($line | is-empty) }
    | each {|line|
            let fields = ($line | split row (char tab))
            {revision: $fields.0, ref: $fields.1}
        }
}

# Trust comes from .git-signers at a reviewed ref, not from the tag's own tree,
# so removing a key on main revokes it for later publication runs. Returns the
# rejection reason, or null for a trusted signature.
def signature-problem [tag_ref: string, trusted: string] {
    let tag = ($tag_ref | str replace 'refs/tags/' '')
    let signers = (^git show $"($trusted):.git-signers" | complete)
    if $signers.exit_code != 0 {
        return $"($trusted) does not define .git-signers"
    }
    if not (^git cat-file tag $tag_ref | str contains '-----BEGIN SSH SIGNATURE-----') {
        return $"release tag ($tag) must have an SSH signature"
    }

    let directory = ('.tmp/release-signers' | path join (random uuid) | path expand)
    let allowed_signers = ($directory | path join 'allowed-signers')
    mkdir $directory
    $signers.stdout | save $allowed_signers
    let result = (
        ^git -c $"gpg.ssh.allowedSignersFile=($allowed_signers)" verify-tag $tag_ref
        | complete
    )
    rm --recursive --force $directory
    if $result.exit_code != 0 {
        print --stderr ($result.stderr | str trim)
        return $"release tag ($tag) is not signed by a key in ($trusted):.git-signers"
    }
    null
}

# Create the next signed release tag from main while it matches live origin.
# Only tags already on origin count toward the sequence; local tags may never
# have been published.
export def create-release-tag [release: record] {
    require-clean-worktree 'release tags'
    let branch = (^git symbolic-ref --quiet --short HEAD | complete)
    if $branch.exit_code != 0 or ($branch.stdout | str trim) != 'main' {
        fail 'release tags must be created from the main branch'
    }

    let remote_main = (ls-remote ['--heads'] refs/heads/main)
    if ($remote_main | is-empty) {
        fail 'origin/main is unavailable'
    }
    if (^git rev-parse HEAD | str trim) != $remote_main.0.revision {
        fail 'main must exactly match origin/main before creating a release tag'
    }

    let tag_ref = $"refs/tags/($release.tag)"
    if (^git show-ref --verify --quiet $tag_ref | complete).exit_code == 0 {
        fail $"release tag ($release.tag) already exists locally"
    }
    let published = (
        ls-remote ['--tags' '--refs'] $"refs/tags/(series-pattern $release)"
        | get ref
        | str replace 'refs/tags/' ''
    )
    let expected = (
        (validate-release-sequence $release.variant $release.date $published | length) + 1
    )
    if $release.sequence != $expected {
        fail $"next release for ($release.variant) on ($release.date) must be archlinux/($release.variant)-($release.date)-($expected)"
    }

    ^git tag --sign --annotate $release.tag --message $"Release ($release.version)"
    # HEAD matches live origin/main, so this applies the signers publication trusts.
    let problem = (signature-problem $tag_ref HEAD)
    if $problem != null {
        ^git tag --delete $release.tag | ignore
        fail $problem
    }
}

# Check a pushed release tag and return the commit it releases. The checkout
# must already contain the fetched release tags and origin/main.
export def check-pushed-release [release: record] {
    let tag_ref = $"refs/tags/($release.tag)"
    if (^git show-ref --verify --quiet $tag_ref | complete).exit_code != 0 {
        fail $"release tag ($release.tag) is not present"
    }
    if (^git cat-file -t $tag_ref | str trim) != 'tag' {
        fail $"release tag ($release.tag) must be annotated"
    }

    let series = (^git tag --list (series-pattern $release) | lines)
    validate-release-sequence $release.variant $release.date $series | ignore

    let revision = (^git rev-list -n 1 $tag_ref | str trim)
    if (^git merge-base --is-ancestor $revision $trusted_ref | complete).exit_code != 0 {
        fail $"release tag ($release.tag) does not target a commit on origin/main"
    }
    let problem = (signature-problem $tag_ref $trusted_ref)
    if $problem != null {
        fail $problem
    }

    $revision
}

# Release images record REVISION and their release version, so build them only
# from that clean commit and only when a trusted pushed release tag names it.
export def check-release-source [release: record, revision: string] {
    require-clean-worktree 'release builds'
    if $revision != (^git rev-parse HEAD | str trim) {
        fail 'release builds require REVISION to be the checked-out commit'
    }
    if (check-pushed-release $release) != $revision {
        fail $"release tag ($release.tag) does not target REVISION"
    }
}
