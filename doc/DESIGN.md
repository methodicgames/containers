<!--
SPDX-FileCopyrightText: 2026 Methodic Games LLC
SPDX-License-Identifier: 0BSD
-->

# Design

## Architecture

### Authority Map

- `src/<family>/` owns each image family's Containerfile and version
  metadata.
- `src/archlinux/VERSION` owns the Arch Archive snapshot date.
- `justfile` owns the public automation interface.
- `bin/containers.nu` coordinates repository automation.
- `bin/diagnostics.nu` owns command-ending failure reporting.
- `bin/versions.nu` owns snapshot, version, and release-tag parsing.
- `bin/releases.nu` owns release-tag trust: creation, sequence,
  ancestry, signature, and release-source checks.
- `bin/publication.nu` owns publication and alias policy.
- `bin/registry.nu` owns registry authentication and transport.
- `bin/smoke.nu` orchestrates image checks; `bin/runtime-checks.nu`
  runs tool and package checks inside an image.
- `tests/` owns named automation scenarios and their fixtures.
- `.github/workflows/` selects when the public commands run on GitHub
  Actions.
- `.git-signers` lists the SSH keys trusted to sign release tags.
- `README.md` is the user-facing reference; `CONTRIBUTING.md` is the
  contributor-facing reference.
- `doc/RELEASING.md` owns release and recovery procedures.

### Automation Boundary

Just exposes memorable commands and delegates implementation to
Nushell. Focused source checks remain available separately. The
canonical validation gate builds and smoke-tests both variants, then
uses the proposed `dev` image's pinned toolchain for source and
static-analysis checks. This makes the image pair one acceptance unit
and keeps local and hosted validation equivalent. Publication is the
only repository command that changes an external registry and requires
prior authentication. Initial publication depends on that gate;
recovery validates the already published release digest and smoke-tests
it using the recorded Git revision's source, without rebuilding it.
Historical source runs only its smoke recipe; current publication code
retains control of all registry writes. Publication policy tests use an
injected backend, and integration tests exercise real manifests against
a disposable rootless registry through the same policy.

Version parsing takes explicit input; matching a release to the current
snapshot is a separate check. Command orchestration captures image and
registry settings before passing them to helpers. Publication policy
uses callbacks for registry lookup, creation, smoke testing, promotion,
verification, and receipts, keeping transport and credentials outside
the policy. Publication and published-image checks share the same alias
planning rules.

### Hosted Publication

Pull requests and relevant pushes to `main` run the canonical gate on
the Actions runner with read-only repository permission. A matching
release-tag push starts the publication job, the only job with
registry-write permission. It validates the variant's release sequence,
signature, and ancestry before authenticating to GHCR. The signature
must come from a key listed in `.git-signers` on `origin/main`, so
release trust follows reviewed history rather than every key a hosting
account has registered, and removing a key there revokes it for later
publication runs. Publication is serialized per variant across snapshot
dates, with queued runs and no cancellation of an active publisher. The
first successful versioned manifest is authoritative; retries validate
its metadata and resume from that digest. Only a structured
missing-manifest response allows an initial upload. Authentication
failures and transport errors stop work.

Publication inspects both aliases before changing either. Date aliases
advance by sequence within their date; floating aliases advance by date
and sequence. Equal versions require equal digests, and each existing
alias must match its own immutable release. Promotion copies the exact
manifest bytes within the same repository. Writes are individually
verified and recoverable; the three tags are not an atomic transaction.

Anonymous manifest and pull checks remain inside the publication lock.
A receipt beneath `dst/publication/` records the release digest, alias
decisions, verification progress, and completion. Registry state is
sufficient for a fresh runner to resume. Development releases also test
the published digest as a GitHub Actions job container.

These guarantees apply to cooperating publishers. Manual registry
writes and historical workflow code do not acquire the new lock or obey
the new policy. Production uses the updated workflow; exceptional
manual recovery requires quiescent publication and the original release
inputs.

## Source and Generated State

`src/<family>/` holds every authoritative image input. For the Arch
family, the Containerfile pins the upstream image and Archive URL, and
`src/archlinux/VERSION` records the matching snapshot date.

Retained generated or build output belongs under `dst/`. Ignored caches
and other repository-local operational state belong under `.tmp/`.
Disposable exploration belongs under `scratch/`. All three directories
can be removed without deleting maintained source.

## Interfaces and Invariants

### Arch Linux Family

The Arch family supports `linux/amd64`. Its `base` stage begins from an
upstream image pinned by tag and digest, replaces the active package
mirror with a dated Arch Linux Archive snapshot, updates packages, and
clears the package cache.

The `dev` stage extends `base` directly. It adds non-interactive build
and validation tools required by this repository and its downstream
jobs. It does not define a separate CI stage or install host-oriented
interactive tools. Both variants intentionally run as container root;
rootless Podman maps that identity into the invoking user's namespace.

### Version and Tag Model

`YYYYMMDD` identifies the shared Archive snapshot and determines the
dotted date in release tags. A signed annotated Git tag
`archlinux/<variant>-YYYY.MM.DD-N` identifies one variant release. Each
variant has an independent per-snapshot sequence: `N` starts at `1` and
increases without gaps. Removing the `archlinux/` namespace from the
Git tag produces the exact immutable OCI tag.

Publication creates three tag classes:

- `VARIANT-YYYY.MM.DD-N` is the immutable release reference.
- `VARIANT-YYYY.MM.DD` moves within one release date.
- `VARIANT` is the moving convenience alias.

The Git release tag and OCI revision label trace an image to source.
Consumers pin OCI manifest digests when tag mutability is unacceptable.

## Decisions

### Licensing Boundary

Repository-authored definitions, automation, and documentation use
0BSD. Packages installed into images retain their own copyright and
licensing terms; image labels and project documentation do not
relicense them.

### Git Object Format

The repository retains the SHA-1 object format. The canonical upstream
and public references are already GitHub-hosted SHA-1 objects;
rewriting them solely to prefer SHA-256 would break stable commit and
image trace references without improving current interoperability.
Reconsider only if the canonical host and required integrations support
a transition that preserves those references.
