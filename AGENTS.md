# AGENTS

This repository defines versioned OCI image families built with
rootless Podman and published to GHCR by GitHub Actions.

## Authorities

- `/README.md` is the user-facing reference.
- `/CONTRIBUTING.md` defines contributor and validation workflows.
- `/doc/GOAL.md` records durable priorities. Treat it as high-level
  priorities, not an implementation specification.
- `/doc/DESIGN.md` records architecture and enduring boundaries.
- `/doc/NOTES.md` records curated durable knowledge and non-obvious
  operational discoveries, not an activity log.
- `/doc/FYI.md` records deferred incidental findings. Do not
  investigate them merely to expand an item.
- `/doc/SKILLS.md`, when present, records project-specific skill
  overrides. When using a skill, read its matching section.
- `/doc/PROJECT.md` records dependency-update rules, setup decisions,
  and baseline exceptions.
- `/doc/RELEASING.md` defines release and recovery procedures.
- `/justfile` is the authority for local and CI automation.

## Consequential Constraints

- Keep image-family source under `/src/<family>/` and pin upstream
  images by immutable tag and digest.
- Treat `/src/archlinux/VERSION` as the Arch Archive snapshot source of
  truth. Its dotted date determines Arch release-tag dates.
- Use rootless Podman. Do not substitute Docker unless the task
  explicitly changes the supported tooling.
- Use Just recipes for validation, builds, smoke tests, releases, and
  publication; workflows must not reimplement them.
- Pull requests and `main` pushes must never publish. Only a valid,
  explicitly pushed signed release tag may publish images.

## Hard Constraints

- Do not modify `/AGENTS.md` without explicit user permission.
- Conspicuously report any changes to `/doc/DESIGN.md` and
  `/doc/GOAL.md` to the user at the end of the task.
- The 0BSD license covers repository-authored source only. Do not imply
  that software installed in an image uses that license.
