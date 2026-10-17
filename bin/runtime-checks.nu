#!/usr/bin/env -S nu --no-config-file
# SPDX-FileCopyrightText: 2026 Methodic Games LLC
# SPDX-License-Identifier: 0BSD

# Run inside the image. Host-side container orchestration lives in smoke.nu.

# Commands the development image must provide. Each package has one
# representative with `run` arguments, which the job check executes; other
# commands from the same package need only exist.
const development_commands = [
    {command: '7z', run: []}
    {command: 'actionlint', run: ['-version']}
    {command: 'b3sum', run: ['--version']}
    {command: 'biome', run: ['--version']}
    {command: 'bsdcpio'}
    {command: 'bsdtar', run: ['--version']}
    {command: 'c3c', run: ['--version']}
    {command: 'check-jsonschema', run: ['--version']}
    {command: 'clang', run: ['--version']}
    {command: 'clang++'}
    {command: 'curl', run: ['--version']}
    {command: 'dotnet', run: ['--version']}
    {command: 'dotCover', run: ['help']}
    {command: 'dottrace', run: ['--help']}
    {command: 'emcc', run: ['--version']}
    {command: 'em++'}
    {command: 'emar'}
    {command: 'emcmake'}
    {command: 'emconfigure'}
    {command: 'emmake'}
    {command: 'emranlib'}
    {command: 'gcc', run: ['--version']}
    {command: 'gh', run: ['--version']}
    {command: 'git', run: ['--version']}
    {command: 'git-lfs', run: ['version']}
    {command: 'jb', run: ['inspectcode' '--version']}
    {command: 'jq', run: ['--version']}
    {command: 'just', run: ['--version']}
    {command: 'make', run: ['--version']}
    {command: 'node', run: ['--version']}
    {command: 'nu', run: ['--version']}
    {command: 'nvchecker', run: ['--version']}
    {command: 'refasmer', run: ['--help']}
    {command: 'reuse', run: ['--version']}
    {command: 'rumdl', run: ['--version']}
    {command: 'ssh', run: ['-V']}
    {command: 'tar', run: ['--version']}
    {command: 'tea', run: ['--version']}
    {command: 'tmux', run: ['-V']}
    {command: 'unzip', run: ['-v']}
    {command: 'zip', run: ['-v']}
    {command: 'zstd', run: ['--version']}
]

const excluded_packages = [bash-completion fd less man-db npm ripgrep wget]

def main [] {
    print 'Use a subcommand: dev or job.'
}

def "main dev" [] {
    for entry in $development_commands {
        if (which $entry.command | is-empty) {
            error make {msg: $"missing command ($entry.command)"}
        }
    }

    for package in $excluded_packages {
        if (^pacman -Q $package | complete).exit_code == 0 {
            error make {msg: $"unexpected package ($package)"}
        }
    }
}

def "main job" [] {
    let uid = (^id -u | str trim)
    if $uid != '0' {
        error make {msg: 'job container does not run as root'}
    }

    for entry in ($development_commands | where {|entry| $entry.run? != null }) {
        let result = (^$entry.command ...$entry.run | complete)
        if $result.exit_code != 0 {
            error make {msg: $"cannot run ($entry.command): ($result.stderr | str trim)"}
        }

        # One identifying line per command keeps job logs readable.
        let summary = (
            [$result.stdout $result.stderr]
            | each { lines }
            | flatten
            | str trim
            | where {|line| $line != '' }
            | get -o 0
            | default ''
        )
        print $"($entry.command): ($summary)"
    }
}
