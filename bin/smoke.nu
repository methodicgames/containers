# Host-side image checks. Call through the public Just recipes.

use versions.nu parse-snapshot

def run-image-check [image_ref: string, command: list<string>, failure: string] {
    let result = (^podman run --rm $image_ref ...$command | complete)
    if $result.exit_code != 0 {
        error make {msg: $"($failure): ($result.stderr | str trim)"}
    }

    $result.stdout | str trim
}

def check-root [image_ref: string] {
    let uid = (run-image-check $image_ref ['id' '-u'] 'cannot check container identity')
    if $uid != '0' {
        error make {msg: $"($image_ref) does not run as root"}
    }
}

def check-mirror [image_ref: string, snapshot: string] {
    let snapshot_path = (parse-snapshot $snapshot).path
    let expected = $"Server = https://archive.archlinux.org/repos/($snapshot_path)/$repo/os/$arch"

    run-image-check $image_ref [
        'grep' '-Fxq' $expected '/etc/pacman.d/mirrorlist'
    ] $"($image_ref) does not use the expected Archive mirror" | ignore
}

def check-package-state [image_ref: string] {
    let cache_entry = (run-image-check $image_ref [
        'find' '/var/cache/pacman/pkg' '-mindepth' '1' '-print' '-quit'
    ] $"($image_ref) cannot inspect its package cache")
    if $cache_entry != '' {
        error make {msg: $"($image_ref) package cache is not empty"}
    }

    let sync_database = (run-image-check $image_ref [
        'find' '/var/lib/pacman/sync' '-maxdepth' '1' '-name' '*.db' '-print' '-quit'
    ] $"($image_ref) cannot inspect its package sync database")
    if $sync_database == '' {
        error make {msg: $"($image_ref) has no active package sync database"}
    }
}

def check-image-metadata [image_ref: string, variant: string, image_context: record] {
    let details = (^podman image inspect $image_ref | from json | first)
    let labels = $details.Labels

    if $details.Architecture != 'amd64' {
        error make {msg: $"($image_ref) has an unexpected architecture"}
    }
    if ($labels | get 'games.methodic.containers.variant') != $variant {
        error make {msg: $"($image_ref) has an unexpected variant label"}
    }
    if ($labels | get 'org.opencontainers.image.version') != $image_context.version {
        error make {msg: $"($image_ref) has an unexpected version label"}
    }
    if ($labels | get 'org.opencontainers.image.revision') != $image_context.revision {
        error make {msg: $"($image_ref) has an unexpected revision label"}
    }
    if ($labels | get 'org.opencontainers.image.source') != 'https://github.com/methodicgames/containers' {
        error make {msg: $"($image_ref) has an unexpected source label"}
    }
}

def run-with-source [image_ref: string, source: path, command: list<string>] {
    (
        ^podman run --rm
            --volume $"($source):/src:ro"
            --workdir /src
            $image_ref ...$command
    )
}

def check-development-image [image_ref: string, source: path] {
    run-with-source $image_ref $source [
        'nu' '--no-config-file' 'bin/runtime-checks.nu' 'dev'
    ]
    run-with-source $image_ref $source ['just' 'smoke-job']
    run-with-source $image_ref $source ['reuse' 'lint']
}

# Context supplies image, version, revision, and snapshot; source is the repo root.
export def smoke-image [image_context: record, variant: string, source: path] {
    let image_ref = $"($image_context.image):($variant)-($image_context.version)"

    check-root $image_ref
    check-mirror $image_ref $image_context.snapshot
    check-package-state $image_ref
    check-image-metadata $image_ref $variant $image_context

    if $variant == 'dev' {
        check-development-image $image_ref $source
    }
}
