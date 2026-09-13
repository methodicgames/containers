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
`origin/main`. The release process requires Git, Just, Nushell, tar,
rootless Podman, and network access. Creating the tag uses the
configured signing identity. Publication requires registry
authentication and runs through GitHub Actions in production.

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

The recipe checks that the worktree is clean and synchronized, the tag
date matches `src/archlinux/VERSION`, and the selected variant's
per-snapshot sequence starts at `1` and has no gaps. It creates and
verifies a signed annotated tag, then prints the explicit push command.
It never pushes the tag itself.

## Publish

After reviewing the tag, push it using the command printed by
`just release`. GitHub Actions independently validates its syntax,
sequence, annotation, signature, and ancestry from `origin/main` before
authenticating to GHCR. Pull requests and pushes to `main` validate but
never publish.

The workflow publishes the selected variant's immutable release tag,
date alias, and floating alias. Publication is serialized separately
for `base` and `dev`, including anonymous verification, and pending
releases are queued. It grants registry-write permission only to the
publication job.

The lower-level `just tag` and `just publish` recipes default to the
variant selected by `RELEASE_TAG`; an explicit variant must match it.

`just publish` is the authenticated lower-level operation used by the
release workflow. It requires
`RELEASE_TAG=archlinux/<variant>-YYYY.MM.DD-N` and `REVISION`
containing the full tagged Git commit ID. Registry requests use the
credentials written by `podman login`. `REGISTRY_AUTH_FILE` takes
precedence over `DOCKER_CONFIG`; either selects an exclusive file.
Otherwise, lookup checks the runtime auth file, then
`XDG_CONFIG_HOME/containers/auth.json` (defaulting to
`~/.config/containers/auth.json`), then `~/.docker/config.json`. The
registry client supports basic authentication and bearer tokens issued
over HTTPS by the registry host, including GHCR. Credential helpers and
cross-host authentication services are not supported.

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
The check requires rootless Podman and network access, honors `IMAGE`,
and writes an empty registry-authentication file beneath `.tmp/`. It
accepts an alias at a newer release only when that alias matches its
own immutable release digest. Missing, older, or conflicting aliases
fail the check.

A diagnostic receipt is written to
`dst/publication/<variant>-<YYYY.MM.DD-N>.json`. Recovery does not
depend on retaining it.

## Recovery

A partial publication failure can be retried with the same inputs. A
retry reuses the first published release digest after validating its
metadata and smoke-testing the image against its recorded source
revision. It advances only aliases that are absent or older, verifies
all selected digests anonymously, and records progress under
`dst/publication/`. An existing equal-version digest conflict is an
error, not permission to overwrite an image.

The recorded Git commit must be available locally. Publication exports
that revision beneath `.tmp/release-smoke/` and runs only its
`just smoke` recipe, so later tool additions do not invalidate an older
image. Current publication code still controls registry inspection,
alias updates, and anonymous verification. To test a locally available
release image independently, run
`just smoke-release RELEASE_TAG REVISION` with its full tagged commit
ID; this command honors `IMAGE`.

Keep production publication in the serialized release workflow. Manual
`just publish` invocations require the original `RELEASE_TAG`, tagged
`REVISION`, matching snapshot source, and registry authentication; they
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
