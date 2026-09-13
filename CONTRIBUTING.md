# Contributing

## Scope

Changes should keep each image family reproducible, minimal for its
stated role, and usable through rootless Podman. Add a platform only
when every upstream input and validation path supports it.

Use American English in repository-authored prose. Use Nushell for
repository automation and keep `justfile` as the public command
surface. Do not edit generated or operational state as maintained
source.

## Development Setup

Focused source linting requires Git, Just, Nushell, Rumdl, REUSE, and
actionlint. The canonical validation gate additionally requires
rootless Podman and tar, and uses the built `dev` image for the full
lint toolchain. Publication integration tests pull a digest-pinned
registry image and bind a disposable instance to a random loopback
port. Updating the Arch snapshot requires `curl` and network access.

No dependency-installation step is required. Confirm the tools are
available, then inspect the public commands with:

```sh
just --list
```

Update the Arch snapshot using a UTC date in `YYYYMMDD` form, or omit
the argument to use the current UTC date:

```sh
just update-arch 20260901
just update-arch
```

The recipe selects the newest upstream Arch base image published for
the requested date, pins its digest, verifies and updates the Archive
URL, and records the snapshot date. It leaves an already-current
configuration unchanged. It fails without changing files if either the
snapshot or a same-date upstream image is unavailable. See
[Notes](doc/NOTES.md#selecting-an-arch-snapshot) for the
snapshot-selection rationale.

## Validation

Run focused source and static-analysis checks during iteration with:

```sh
just lint
```

Run the canonical acceptance gate before completion:

```sh
just validate
```

That command runs version, registry-response, publication policy,
recovery, and historical smoke selection tests, exercises manifest
writes against a disposable rootless registry, builds and smoke-tests
both image variants, then runs the source and static-analysis checks
inside the proposed `dev` image.

Tests live under `tests/` and use Nushell's bundled `std/assert`
module. Run `just test` for the local suites and `just test-registry`
for the rootless registry integration suite. Each suite reports named
scenarios and stops on the first failure. Add independent scenarios to
the appropriate suite's `run-tests` record; no external testing package
is required.

Test state stays beneath `.tmp/`; the integration runner removes its
registry container and fixture image references on success or failure.
The individual image recipes remain available for focused iteration:

```sh
just build
just smoke
```

Those image commands accept `base` or `dev` and default to both
variants. Images default to `ghcr.io/methodicgames/archlinux`; override
`IMAGE` when a different local name or registry is required:

```sh
IMAGE=localhost/archlinux just build dev
```

`just validate` always checks both variants as one acceptance unit.
Unreleased local builds use the `local` version. Review the intended
diff and run `git diff --check` for every change. Report skipped or
unavailable checks as unverified, preserving useful diagnostics and
failure status.

Hosted development job containers run `just smoke-job` to check root
identity and required tool versions. Local `just smoke dev` runs the
same recipe inside the built image.

## Formatting

Use four spaces per indentation level in Nushell scripts and Nushell
code examples. Preserve literal data when changing indentation.

Format maintained Markdown and the Justfile with:

```sh
just format
```

Use title case for document headings, table column headings, and
human-readable workflow and step names. Preserve proper names,
acronyms, code identifiers, and required literal headings. Review
formatting changes before committing. Text files end with exactly one
newline.

### Language Quality Tools

- Markdown uses Rumdl with `.rumdl.toml`; `just format` rewrites it and
  `just lint` checks it.
- Just uses its built-in formatter; both quality commands invoke it in
  the appropriate write or check mode.
- GitHub Actions YAML uses actionlint through `just lint`. The pinned
  tool does not recognize GitHub's `concurrency.queue` property yet.
  The invocation excludes only that exact unknown-key diagnostic; a
  `CHECK:` comment records its removal condition and the GitHub
  reference.
- Nushell has no separate formatter or linter selected. Loading
  `bin/containers.nu` exercises the Nushell parser, and the public
  commands provide behavioral validation. No suitable Nushell-specific
  tool is currently available in the official Arch package
  repositories.
- Containerfile and embedded package-installation shell have no
  separate formatter or linter selected. The source-contract checks,
  Podman build, and runtime smoke tests provide stronger
  project-specific coverage; ShellCheck does not parse Containerfile
  instructions as shell scripts.

Re-evaluate the unselected Nushell and Containerfile tools when a
maintained, suitable option is available from the official Arch
repositories. Before adopting a fixed-style formatter, confirm broad
language-community consensus or obtain an explicit project decision
about its style.

## Generated Files

- Edit image-family source only under `src/<family>/`.
- Treat `src/archlinux/VERSION` as the Arch snapshot authority.
- Put retained generated or build output under `dst/`.
- Put repository-local caches and other operational state under
  `.tmp/`.
- Use `scratch/` only for disposable exploration.
- Run `just clean` to remove `dst/` and `.tmp/` without touching source
  or scratch material.

Do not edit generated artifacts directly.

To add another image family, place its Containerfile and version
metadata under `src/`, extend `bin/containers.nu`, and update the
publication workflow without duplicating the public Just interface.

## Shared Skills

Codex is the supported agent client. Obtain shared workflows from
[Methodic Games Agent Skills](https://git.methodic.games/methodic/skills).
In a separate checkout of that collection, run:

```sh
just install codex
```

The installer copies the collection into `~/.agents/skills`, Codex's
[user skill discovery directory](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills).
It includes each package's supporting scripts and references. Refresh
installed copies with `just update codex` from that same checkout.

This project's workflows use `git-commit`, `markdown-format`, and
`copyedit`; pinned external-dependency audits use
`dependencies-update`. Setup audits use `project-audit` and its
companion `project-init`; deferred-findings and actionable-comment
reviews use `fyi-audit` and `todo-audit` when requested. Installing the
collection also supplies optional workflows that this repository does
not require.

Before agent-assisted work, confirm the relevant skills appear in
Codex's available skill list. Keep one discoverable copy of each shared
skill; do not add duplicate copies under this repository's `.agents/`
or `.codex/` directories.

## Commits

Keep commits focused and use Conventional Commits. Limit subjects to 50
characters and body and footer lines to 71 characters. Stage only
reviewed scope, preserve configured identity and signing, obtain
approval for the exact staged state and message, and verify signed
commits after creation. A completed change does not authorize a commit
or push.

Only a valid release-tag push publishes images. Follow
[the release procedure](doc/RELEASING.md) to prepare, publish, verify,
or recover a release. Do not publish local test tags as part of
ordinary validation.
