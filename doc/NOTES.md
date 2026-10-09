<!--
SPDX-FileCopyrightText: 2026 Methodic Games LLC
SPDX-License-Identifier: 0BSD
-->

# Notes

## Selecting an Arch Snapshot

The final numeric component in an upstream Arch image tag is the
upstream GitLab build-job number, not a downstream package or image
release. Select the upstream image first, then use the earliest Archive
snapshot on or after its embedded date that completes `pacman -Syyuu`
without downgrading installed packages.

The image digest fixes the starting filesystem; the Archive date fixes
the package repositories used during the build. Reproducibility
requires both.

## Version Identity

`src/archlinux/VERSION` fixes the shared Archive snapshot date. A
signed Git tag `archlinux/<variant>-YYYY.MM.DD-N` assigns a version to
one variant's release. The dotted date comes from the snapshot, and `N`
is that variant's gap-free sequence for the date. Published OCI tags
omit the `archlinux/` prefix.

Published images use `YYYY.MM.DD-N` as their version and record the
tagged Git commit as their revision. Unreleased local builds use
`local` as their version and, unless `REVISION` is set, their revision.
Publication requires `RELEASE_TAG`. Builds with `RELEASE_TAG` set and
publication require a clean worktree whose `HEAD` is `REVISION`, so a
release image cannot record a revision other than its source.

## Root Identity

Container root is required by package tooling and GitHub Actions job
containers. With rootless Podman, it maps through the invoking user's
user namespace and does not grant host root privileges.

## Inherited Image Labels

Derived images inherit every label from the upstream Arch image unless
the Containerfile overrides it. Upstream sets OCI `authors`, `created`,
`licenses`, and `url` labels that describe Arch's image build,
including the license of its build scripts. The base stage replaces
them so image metadata neither misattributes the image nor declares one
license for its installed software. Smoke tests reject any other OCI
label that upstream adds until it has been reviewed.

## Public Versus Interactive Tools

The `dev` image contains tools needed for builds and non-interactive
jobs. It intentionally omits `npm`, pagers, manual pages, shell
completion, file finders, and other tools expected to remain the host's
responsibility. `tmux` is included as a job tool for driving terminal
programs, not as host-oriented interactive tooling. Smoke tests enforce
both the required and intentionally absent inventories.

## Emscripten Command Path

Arch's Emscripten package supplies `/etc/profile.d/emscripten.sh` to
append its tools directory to `PATH`. Direct container commands and
non-login shells do not automatically source that script.

The development image sources the packaged script during its build,
links the resulting tools directory at `/usr/local/lib/emscripten`, and
adds that stable path to the image environment. Package updates that
move the tools directory therefore follow the package's profile without
requiring a source change. The build checks that the profile appends
exactly one directory containing an executable `emcc`; a change to that
contract fails the build for review.
