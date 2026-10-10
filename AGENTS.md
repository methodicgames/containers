<!--
SPDX-FileCopyrightText: 2026 Methodic Games LLC
SPDX-License-Identifier: 0BSD
-->

# AGENTS

This repository defines versioned OCI image families built with
rootless Podman and published to GHCR by GitHub Actions. Use rootless
Podman; do not substitute Docker unless the task explicitly changes the
supported tooling.

Project context and use are documented in `/README.md`; contributor
conventions and canonical validation are documented in
`/CONTRIBUTING.md`. Consult `/doc/DESIGN.md` for architecture decisions
and `/doc/NOTES.md` for non-obvious operational knowledge when
relevant.

## File-Specific Instructions

- `/AGENTS.md`: Do not modify without explicit user permission.
- `/doc/DESIGN.md` and `/doc/GOAL.md`: Conspicuously report any changes
  to the user at the end of the task. Treat `/doc/GOAL.md` as
  high-level priorities, not an implementation specification.
- `/doc/NOTES.md`: Curated durable knowledge and non-obvious
  operational discoveries, not an activity log.
- `/doc/FYI.md`: Deferred incidental findings. Do not investigate them
  merely to expand an item.
- `/doc/SKILLS.md`: Project-specific skill overrides. When using a
  skill, read its matching section.
- `/doc/PROJECT.md`: Dependency-update rules and deliberate project
  setup exceptions.
- `/doc/RELEASING.md`: Release and recovery procedures.
- `/dst/`, `/.tmp/`, and `/scratch/`: Disposable generated and build
  output, non-output operational state, and exploratory material,
  respectively; not maintained project source.
- `/src/<family>/`: Image-family source. Pin upstream images by
  immutable tag and digest.
- `/src/archlinux/VERSION`: Arch Archive snapshot source of truth. Its
  dotted date determines Arch release-tag dates.
- `/justfile`: Authority for local and CI automation. Use its recipes
  for validation, builds, smoke tests, releases, and publication.
- `/.github/workflows/`: Invoke Just recipes rather than reimplementing
  them. Pull requests and `main` pushes must never publish. Only a
  valid, explicitly pushed signed release tag may publish images.
- `/.git-signers`: Trusted release-signer SSH keys. Change only with
  explicit user approval.
- `/LICENSE` and `/REUSE.toml`: The 0BSD license covers
  repository-authored source only. Do not imply that software installed
  in an image uses that license.

## Commits

Obtain user approval for the exact staged state and message before
creating a commit. A completed change does not authorize a commit or
push.

## Comments and Documentation

Do not create unnecessary cross-reference maintenance burden: avoid
restating changeable facts from source code, configuration, tests, or
other authoritative material when routine changes would require
synchronized edits elsewhere. Examples include exact test counts,
exhaustive inventories, and incidental implementation details. Prefer
explaining intent, behavior, or rationale and referring readers to the
authoritative source.

When specificity is necessary for clarity, use the least restrictive
accurate wording. Identify examples as non-exhaustive and avoid fixed
counts or claims of exclusivity unless readers need that precision.
Preserve exact wording where it defines a requirement or contract. Keep
unavoidable duplicated facts synchronized when changing their source.
