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
Publication requires `RELEASE_TAG`.

## Root Identity

Container root is required by package tooling and GitHub Actions job
containers. With rootless Podman, it maps through the invoking user's
user namespace and does not grant host root privileges.

## Public Versus Interactive Tools

The `dev` image contains tools needed for builds and non-interactive
jobs. It intentionally omits `npm`, pagers, manual pages, shell
completion, file finders, and other tools expected to remain the host's
responsibility. Smoke tests enforce both the required and intentionally
absent inventories.
