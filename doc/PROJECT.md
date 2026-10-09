# Project Setup

## Dependencies

- Treat the Arch base-image tag and digest, Archive URL, and
  `src/archlinux/VERSION` as one coordinated input. Update them through
  `just update-arch`, then follow `doc/RELEASING.md` to select the
  earliest snapshot that upgrades without package downgrades.
- Keep the disposable registry test image pinned by both version and
  digest.
- Pin third-party Actions to full commit IDs with readable release
  comments. Update repeated Action references and their explicit tool
  versions together.
- Run `just validate` after every dependency update so the changed
  images are rebuilt and exercised by the complete acceptance gate.

## Repository Decisions

- `GIT-003`: Retain the established SHA-1 object format. The canonical
  upstream and public references are already GitHub-hosted SHA-1
  objects; rewriting them solely to prefer SHA-256 would break stable
  commit and image trace references without improving current
  interoperability. Reconsider only if the canonical host and required
  integrations support a transition that preserves those references.

## Project Setup Exceptions

- `LEGAL-005`: License all repository-authored source under 0BSD,
  including image definitions beneath `/src/`. This repository treats
  Containerfiles as infrastructure and distribution definitions rather
  than as a separately reusable software implementation; one permissive
  license keeps those definitions and their automation under the same
  terms. This exception does not relicense base images, installed
  packages, or other included software, which retain their own terms.
- `DEV-003`: Do not provide a Development Container for this
  repository. Its core build and smoke-test workflow requires the
  invoking user's rootless Podman namespaces, storage, and credentials.
  A nested or socket-forwarded container would add privilege and
  host-coupling concerns without isolating the actual build
  environment. The published `dev` image remains a downstream
  development and Actions artifact, not a self-hosting environment for
  this repository.
- `REL-001`, `REL-003`, and `REL-008`: Version each variant with signed
  `archlinux/<variant>-YYYY.MM.DD-N` tags whose date is the Arch
  Archive snapshot recorded in `src/archlinux/VERSION`, not the tagging
  date, and whose `N` is that variant's gap-free sequence for the
  snapshot. The snapshot fixes the packages an image contains, so its
  date tells consumers which operating-system state they receive; the
  published OCI tags derived from these Git tags are a public
  interface. `src/archlinux/VERSION` is the snapshot input pin, not a
  release counter. The maintainer decides when a variant's shipped
  content warrants a release.
- `REL-004`: Do not attribute commits to the `base` and `dev` streams
  with trailers. No version derivation or changelog consumes such
  attribution, and the maintainer selects which variants to release.
  Reconsider if changelog generation is adopted.
- `REL-005`: Do not generate a changelog or create hosted release
  objects. Signed release tags explicitly version and publish
  individual OCI images, while focused Git history remains the change
  record. Reconsider if the audience needs curated release notes, a
  compatibility policy, or non-container release artifacts.
