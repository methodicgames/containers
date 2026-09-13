# Containers

Methodic Games OCI container definitions built with rootless Podman and
published to the GitHub Container Registry.

## Status

The `archlinux` image family is published for `linux/amd64` in two
variants:

- `base` is a minimal, snapshot-pinned Arch Linux environment.
- `dev` adds general build and archive tools, including 7-Zip, Git LFS,
  `nvchecker` for release checks, the `b3sum` checksum utility, GitHub
  and Gitea CLIs, and a Node.js runtime for development and GitHub or
  Gitea Actions jobs. Interactive tooling remains the host's
  responsibility, and the image does not include `npm`.

Both variants are pinned to a dated Arch Linux Archive snapshot and an
immutable upstream image tag and digest.

## Requirements

Local examples and supported local workflows use rootless Podman.
Container root is intentional: it maps into the invoking user's
namespace and does not grant host root privileges.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the additional tools
required to build, validate, or update the images.

## Getting Started

Pull the moving aliases with:

```sh
podman pull ghcr.io/methodicgames/archlinux:base
podman pull ghcr.io/methodicgames/archlinux:dev
```

The package page is
<https://github.com/orgs/methodicgames/packages/container/package/archlinux>.

## Usage

Immutable release references use the family version:

```text
ghcr.io/methodicgames/archlinux:base-<YYYY.MM.DD-N>
ghcr.io/methodicgames/archlinux:dev-<YYYY.MM.DD-N>
```

Publication advances a date alias such as `dev-<YYYY.MM.DD>` and the
moving `dev` alias when they do not already identify a newer release.
Consumers that require content identity can combine a readable release
tag with its OCI digest:

```text
ghcr.io/methodicgames/archlinux:dev-2026.09.01-1@sha256:<manifest-digest>
```

Use the development variant in a GitHub Actions job:

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04
    container: ghcr.io/methodicgames/archlinux:dev
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
      - run: just --version
```

Use the development variant from a Dev Container definition:

```json
{
  "image": "ghcr.io/methodicgames/archlinux:dev",
  "remoteUser": "root",
  "updateRemoteUserUID": false
}
```

## Project Structure

- `src/<family>/` contains authoritative image definitions and version
  metadata.
- `bin/` implements repository automation exposed through `justfile`.
- `tests/` contains named Nushell test scenarios and registry
  integration tests.
- `.github/workflows/` defines hosted validation and publication.
- `doc/` records durable goals, design, operational knowledge, project
  setup decisions, and release procedures.
- Generated output belongs under `dst/`; operational state belongs
  under `.tmp/`; disposable exploration belongs under `scratch/`.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, validation, and
contribution guidance. See [doc/RELEASING.md](doc/RELEASING.md) for the
versioning, publication, verification, and recovery procedures.

## License

Repository-authored source is available under the
[Zero-Clause BSD](LICENSE) license. Software installed in the images
retains its own licensing terms. Copyright and licensing metadata
conform to the [REUSE Specification](https://reuse.software/spec/); run
`reuse lint` from the repository root to verify compliance.
