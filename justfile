# SPDX-FileCopyrightText: 2026 Methodic Games LLC
# SPDX-License-Identifier: 0BSD

set shell := ["nu", "--no-config-file", "--commands"]

# Recipes export parameters because quote() emits POSIX shell syntax that
# Nushell cannot parse. Nushell matches environment names case-insensitively,
# so keep parameter names distinct from settings such as REVISION.

today := `date now | date to-timezone UTC | format date "%Y%m%d"`

# List public recipes; validation builds images and requires rootless Podman.
default:
    @just --list

# Format maintained source files.
format:
    nu --no-config-file bin/containers.nu format

# Run source, metadata, and static-analysis checks.
lint:
    nu --no-config-file bin/containers.nu lint

# Run the local std/assert suites without contacting a registry.
test:
    nu --no-config-file tests/versions.nu
    nu --no-config-file tests/publication.nu
    nu --no-config-file tests/registry.nu
    nu --no-config-file tests/release.nu
    nu --no-config-file tests/smoke-release.nu

# Test manifest publication against a disposable rootless registry.
test-registry:
    nu --no-config-file tests/integration/registry.nu

# Run the complete source, build, smoke, and lint gate.
validate:
    nu --no-config-file bin/containers.nu validate

# Remove repository-local output and operational state.
clean:
    nu --no-config-file bin/containers.nu clean

# Update the Arch snapshot and its newest same-date upstream image.
update-arch $snapshot=today:
    nu --no-config-file bin/containers.nu update-arch $env.snapshot

# Create a signed, gap-free release tag locally without pushing it.
release $release-tag:
    nu --no-config-file bin/containers.nu release $env.release-tag

# Verify a pushed release tag and emit its metadata to the workflow.
[private]
validate-release $release-tag:
    nu --no-config-file bin/containers.nu validate-release $env.release-tag

# Build one variant, or all variants, with its local or release tag.
build $variant="all":
    nu --no-config-file bin/containers.nu build $env.variant

# Run root, mirror, metadata, and tool smoke tests.
smoke $variant="all":
    nu --no-config-file bin/containers.nu smoke $env.variant

# Check root identity and required tools inside a development job container.
smoke-job:
    nu --no-config-file bin/containers.nu smoke-job

# Smoke-test a local release image using its recorded source revision.
smoke-release $release-tag $tagged-commit:
    nu --no-config-file bin/containers.nu smoke-release $env.release-tag $env.tagged-commit

# Verify a release and its current aliases by digest using anonymous pulls.
smoke-published $release-tag:
    nu --no-config-file bin/containers.nu smoke-published $env.release-tag

# Publish or resume a release and verify its aliases. Set REVISION first.
publish $release-tag:
    nu --no-config-file bin/containers.nu publish $env.release-tag
