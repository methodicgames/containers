# Pure parsing and naming rules shared by local and registry operations.

export def parse-snapshot [snapshot: string] {
    if not ($snapshot =~ '^[0-9]{8}$') {
        error make {msg: $"invalid Arch snapshot ($snapshot); expected YYYYMMDD"}
    }

    let date = ($snapshot | into datetime --format '%Y%m%d')
    if ($date | format date '%Y%m%d') != $snapshot {
        error make {msg: $"invalid Arch snapshot date ($snapshot)"}
    }

    {
        snapshot: $snapshot
        date: ($date | format date '%Y.%m.%d')
        path: ($date | format date '%Y/%m/%d')
    }
}

export def parse-published-version [version: string] {
    let pattern = '^(?<date>[0-9]{4}[.][0-9]{2}[.][0-9]{2})-(?<sequence>[1-9][0-9]*)$'
    let matches = ($version | parse --regex $pattern)
    if ($matches | is-empty) {
        error make {msg: $"invalid published version ($version)"}
    }

    let parts = ($matches | first)
    let snapshot = (parse-snapshot ($parts.date | str replace --all '.' ''))

    {
        date: $snapshot.date
        sequence: ($parts.sequence | into int)
    }
}

# Parsing does not consult VERSION. Callers enforce their snapshot requirement.
export def parse-release-tag [release_tag: string] {
    let pattern = '^archlinux/(?<variant>base|dev)-(?<version>.+)$'
    let matches = ($release_tag | parse --regex $pattern)
    if ($matches | is-empty) {
        error make {
            msg: $"invalid release tag ($release_tag); expected archlinux/base-YYYY.MM.DD-N or archlinux/dev-YYYY.MM.DD-N"
        }
    }

    let parts = ($matches | first)
    let version = (parse-published-version $parts.version)

    {
        tag: $release_tag
        variant: $parts.variant
        date: $version.date
        sequence: $version.sequence
        version: $parts.version
    }
}

export def check-release-snapshot [release: record, snapshot: string] {
    let snapshot_date = (parse-snapshot $snapshot).date
    if $release.date != $snapshot_date {
        error make {
            msg: $"release date ($release.date) must match Arch snapshot date ($snapshot_date)"
        }
    }
}

export def is-git-revision [revision: string] {
    $revision =~ '^([0-9a-f]{40}|[0-9a-f]{64})$'
}

# Alias descriptors carry their scope explicitly; order controls promotion order.
export def release-aliases [variant: string, version: string] {
    let date = (parse-published-version $version).date

    [
        {tag: $"($variant)-($date)", dated: true}
        {tag: $variant, dated: false}
    ]
}

export def validate-release-sequence [variant: string, date: string, tags: list<string>] {
    let sequences = (
        $tags
        | each {|tag|
                let release = (parse-release-tag $tag)
                if $release.variant != $variant or $release.date != $date {
                    error make {msg: $"release tag ($tag) does not belong to the ($variant) ($date) series"}
                }
                $release.sequence
            }
        | uniq
        | sort
    )

    for entry in ($sequences | enumerate) {
        let expected = $entry.index + 1
        if $entry.item != $expected {
            error make {msg: $"release sequence for ($variant) ($date) skips ($expected)"}
        }
    }

    $sequences
}
