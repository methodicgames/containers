set shell := ["nu", "--no-config-file", "--commands"]

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
update-arch snapshot=today:
    nu --no-config-file bin/containers.nu update-arch {{ quote(snapshot) }}

# Create a signed, gap-free release tag locally without pushing it.
release release-tag:
    nu --no-config-file bin/containers.nu release {{ quote(release-tag) }}

# Validate a release with GitHub and emit metadata using the workflow environment.
validate-release release-tag:
    nu --no-config-file bin/containers.nu validate-release {{ quote(release-tag) }}

# Build one variant, or all variants, with its local or release tag.
build variant="all":
    nu --no-config-file bin/containers.nu build {{ quote(variant) }}

# Add release-date and floating aliases. Set RELEASE_TAG first.
tag variant="all":
    nu --no-config-file bin/containers.nu tag {{ quote(variant) }}

# Run root, mirror, metadata, and tool smoke tests.
smoke variant="all":
    nu --no-config-file bin/containers.nu smoke {{ quote(variant) }}

# Check root identity and required tools inside a development job container.
smoke-job:
    nu --no-config-file bin/containers.nu smoke-job

# Smoke-test a local release image using its recorded source revision.
smoke-release release-tag revision:
    nu --no-config-file bin/containers.nu smoke-release {{ quote(release-tag) }} {{ quote(revision) }}

# Verify a release and its current aliases by digest using anonymous pulls.
smoke-published release-tag:
    nu --no-config-file bin/containers.nu smoke-published {{ quote(release-tag) }}

# Publish or resume a release and verify its aliases. Set RELEASE_TAG and REVISION.
publish variant="all":
    nu --no-config-file bin/containers.nu publish {{ quote(variant) }}
