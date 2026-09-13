#!/usr/bin/env -S nu --no-config-file

# Run inside the image. Host-side container orchestration lives in smoke.nu.

def require-command [command: string] {
    if (which $command | is-empty) {
        error make {msg: $"missing command ($command)"}
    }
}

def reject-package [package: string] {
    let installed = (^pacman -Q $package | complete)
    if $installed.exit_code == 0 {
        error make {msg: $"unexpected package ($package)"}
    }
}

def main [] {
    print 'Use a subcommand: dev or job.'
}

def "main dev" [] {
    let required_commands = [
        7z actionlint b3sum bsdcpio bsdtar curl gcc gh git git-lfs jq just make
        node nu nvchecker reuse rumdl ssh tar tea unzip zip zstd
    ]
    for command in $required_commands {
        require-command $command
    }

    let excluded_packages = [bash-completion fd less man-db npm ripgrep wget]
    for package in $excluded_packages {
        reject-package $package
    }
}

def "main job" [] {
    let uid = (^id -u | str trim)
    if $uid != '0' {
        error make {msg: 'job container does not run as root'}
    }

    let seven_zip = (^7z | complete)
    if $seven_zip.exit_code != 0 {
        error make {msg: 'cannot query 7-Zip version'}
    }
    $seven_zip.stdout
    | lines
    | where {|line| not ($line | str trim | is-empty) }
    | first
    | print

    ^actionlint -version
    ^b3sum --version
    ^bsdtar --version
    ^gh --version
    ^node --version
    ^git --version
    ^git lfs version
    ^just --version
    ^nu --version
    ^nvchecker --version
    ^tea --version
}
