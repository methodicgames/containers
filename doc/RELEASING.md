<!--
SPDX-FileCopyrightText: 2026 Methodic Games LLC
SPDX-License-Identifier: 0BSD
-->

# Releasing

This repository publishes versioned OCI images without generating a
changelog or creating hosted release objects. Signed Git tags identify
releases, and focused Git history remains the change record.

## Versioning

Release tags have the form `archlinux/<variant>-YYYY.MM.DD-N`, where
the variant is `base` or `dev` and the date is the dotted form of the
snapshot recorded in `src/archlinux/VERSION`. Each variant has an
independent sequence for that snapshot: `N` starts at `1` and increases
without gaps.

Removing the `archlinux/` namespace from the Git tag gives the exact
immutable OCI tag. For example, `archlinux/dev-2026.09.01-1` publishes
`dev-2026.09.01-1`. Publication also manages a date alias such as
`dev-2026.09.01` and the moving `dev` alias.

Arch's upstream tags use a different scheme:
`base-<YYYYMMDD>.0.<build-job>`. The final number is the Arch GitLab
build-job number, not a package release number for downstream images.

## Prerequisites

Prepare releases from a clean `main` worktree that exactly matches live
`origin/main`. The release process requires the validation toolchain
described in [Contributing](../CONTRIBUTING.md#development-setup) and
network access. Creating the tag uses the configured SSH signing
identity, whose public key must be listed in `.git-signers` on `main`.
Publication requires registry authentication and runs through GitHub
Actions in production.

To add, rotate, or revoke a release signer, change `.git-signers` in a
reviewed commit on `main` before tagging. Publication reads the file
from `origin/main`, so a removed key also stops reruns of tags it
signed.

The snapshot source, upstream image tag and digest, Archive URL, and
release date must remain synchronized. `src/archlinux/VERSION` is the
snapshot-date authority.

## Prepare

Select an upstream image and its same-date Archive snapshot with
`just update-arch YYYYMMDD`. Omitting the date selects the current UTC
date. This command always selects the newest upstream build for the
requested date and updates both pins together.

Run `just build base` and inspect the `pacman -Syyuu` transaction. If
it would downgrade any installed package, keep `ARG ARCH_IMAGE`
unchanged and manually advance the Archive URL in
`src/archlinux/Containerfile` and the date in `src/archlinux/VERSION`
by one day. Repeat the build until it completes without a downgrade. Do
not rerun `update-arch` to advance only the Archive date: it would
select another upstream image. Use the earliest successful snapshot to
avoid unnecessary package updates.

Run the canonical validation gate:

```sh
just validate
```

Create the next signed release tag locally with:

```sh
just release archlinux/dev-2026.09.01-1
```

The recipe creates the tag only when it satisfies the release checks
below, and it prints the explicit push command rather than pushing the
tag itself.

## Publish

After reviewing the tag, push it using the command printed by
`just release`. Pull requests and pushes to `main` validate but never
publish.

Release creation and publication share one set of release checks,
defined in `bin/releases.nu`. A release tag must be annotated, follow
its variant's gap-free sequence for the current snapshot, target a
commit on `origin/main`, and carry a signature from a key in
`.git-signers` on `origin/main`. Builds with `RELEASE_TAG` set and
publication also require a clean checkout of exactly the tagged commit,
so a release image cannot record a version or revision that no trusted
release tag identifies. The workflow applies these checks before
authenticating to GHCR.

The workflow publishes the selected variant's immutable release tag,
date alias, and floating alias. Publication is serialized separately
for `base` and `dev`, including anonymous verification, and pending
releases are queued. It grants registry-write permission only to the
publication job.

`just publish archlinux/<variant>-YYYY.MM.DD-N` is the authenticated
lower-level operation used by the release workflow. It acts on the
variant that the release tag selects and requires `REVISION` containing
the full tagged Git commit ID. Registry requests use skopeo, which
finds the credentials written by `podman login` the same way Podman
does, and ignore host registry mirrors and other `registries.conf`
settings.

When the versioned image is absent, publication runs `just validate`,
pushes the image once, and records its manifest digest. On retry, an
existing image with matching source, revision, version, variant, and
platform becomes authoritative: publication pulls and smoke-tests that
exact digest without rebuilding or replacing it. Conflicting metadata
and registry errors stop publication.

The date alias advances by numeric release sequence within its
snapshot. The floating alias advances by snapshot date, then numeric
sequence. Newer aliases remain untouched; equal versions must have
equal digests. Publication promotes the exact release manifest and
anonymously verifies its digest and those of the selected aliases.

Production publication must use the workflow. Direct registry writes
and manual `just publish` invocations bypass its concurrency lock.

## Verify

Publication anonymously verifies the release digest and selected alias
digests before releasing the per-variant lock. Development releases
also run a downstream GitHub Actions job with the release digest as its
job container.

To independently check anonymous access and alias identities, run:

```sh
just smoke-published archlinux/dev-2026.09.01-1
```

Use a release whose date matches the current `src/archlinux/VERSION`.
The check requires rootless Podman, skopeo, and network access, honors
`IMAGE`, and writes an empty registry-authentication file beneath
`.tmp/`. It accepts an alias at a newer release only when that alias
matches its own immutable release digest. Missing, older, or
conflicting aliases fail the check.

## Recovery

A partial publication failure can be retried with the same inputs. A
retry reuses the first published release digest after validating its
metadata and smoke-testing the image against its recorded source
revision. It advances only aliases that are absent or older and
verifies all selected digests anonymously. An existing equal-version
digest conflict is an error, not permission to overwrite an image.

The recorded Git commit must be available locally. Publication exports
that revision beneath `.tmp/release-smoke/` and runs only its
`just smoke` recipe, so later tool additions do not invalidate an older
image. Current publication code still controls registry inspection,
alias updates, and anonymous verification. To test a locally available
release image independently, run
`just smoke-release RELEASE_TAG TAGGED_COMMIT` with its full tagged
commit ID; this command honors `IMAGE`.

Keep production publication in the serialized release workflow. Manual
`just publish` invocations require the original release tag, tagged
`REVISION`, a current `origin/main`, and registry authentication, and
they pass the same [release checks](#publish) as the workflow; they
must not overlap a production publisher. Test alternative registries
through `IMAGE`. Plain HTTP is supported only for an explicit loopback
host and port used by disposable tests.

Historical workflow reruns execute historical code. Do not rerun
releases created before the current publication protections were
introduced. If an old release needs repair, inspect its existing
registry state and use the updated publication commands with its
original snapshot and revision while production publication is
quiescent. The newer commands do not rewrite old Git tags or disable
old workflows. Never move a signed release tag.
