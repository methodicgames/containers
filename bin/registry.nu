# SPDX-FileCopyrightText: 2026 Methodic Games LLC
# SPDX-License-Identifier: 0BSD

# Registry access through skopeo, which shares Podman's credential lookup and
# transport. No publication policy.

const manifest_media_types = [
    'application/vnd.oci.image.manifest.v1+json'
    'application/vnd.docker.distribution.manifest.v2+json'
]

# Context fields: image, loopback, anonymous. Plain HTTP is allowed only for an
# explicit loopback host and port; anonymous contexts send no credentials.
export def registry-context [image: string, --anonymous] {
    let pattern = '^(?<host>[a-z0-9.-]+(?::[0-9]+)?)/[a-z0-9._/-]+$'
    let matches = ($image | parse --regex $pattern)
    if ($matches | is-empty) {
        error make {msg: 'IMAGE must be a fully qualified registry/repository without a tag'}
    }

    {
        image: $image
        loopback: ($matches.0.host =~ '^(localhost|127[.]0[.]0[.]1):[0-9]+$')
        anonymous: $anonymous
    }
}

# Connection options for one side of a skopeo command, such as src- or dest-.
def connection [client: record, side: string = ''] {
    let tls = [$"--($side)tls-verify=(not $client.loopback)"]
    if $client.anonymous {
        $tls | append $"--($side)no-creds"
    } else {
        $tls
    }
}

def inspect-raw [client: record, reference: string, --config] {
    let target = if $config { ['--config'] } else { [] }
    (
        ^skopeo inspect --raw ...$target ...(connection $client)
            $"docker://($client.image)($reference)"
        | complete
    )
}

def require-success [result: record, failure: string] {
    if $result.exit_code != 0 {
        error make {msg: $"($failure): ($result.stderr | str trim)"}
    }

    $result.stdout
}

export def parse-manifest [raw: string] {
    let manifest = ($raw | from json)
    if $manifest.schemaVersion? != 2 or $manifest.mediaType? not-in $manifest_media_types {
        error make {msg: 'expected a single-platform OCI or Docker v2 image manifest'}
    }

    {digest: $"sha256:($raw | hash sha256)"}
}

# Return null only when the registry reports the manifest unknown. skopeo's
# exit status does not reliably identify that case, so match its message; any
# other failure, including an unrecognized message, stops the caller.
export def read-manifest [client: record, tag: string] {
    if not ($tag =~ '^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$') {
        error make {msg: 'invalid manifest tag'}
    }

    let result = (inspect-raw $client $":($tag)")
    if $result.exit_code != 0 and ($result.stderr | str contains 'manifest unknown') {
        return null
    }
    parse-manifest (require-success $result 'registry manifest lookup failed')
}

export def lookup-artifact [client: record, tag: string] {
    let manifest = (read-manifest $client $tag)
    if $manifest == null {
        return null
    }

    let config = (
        require-success (inspect-raw $client $"@($manifest.digest)" --config)
            'registry config lookup failed'
        | from json
    )
    let labels = $config.config.Labels

    $manifest | merge {
        source: ($labels | get 'org.opencontainers.image.source')
        revision: ($labels | get 'org.opencontainers.image.revision')
        version: ($labels | get 'org.opencontainers.image.version')
        variant: ($labels | get 'games.methodic.containers.variant')
        architecture: $config.architecture
        os: $config.os
    }
}

export def promote-manifest [client: record, tag: string, artifact: record] {
    # Retag the exact release manifest; skopeo fails rather than convert it.
    let result = (
        ^skopeo copy --quiet --preserve-digests
            ...(connection $client 'src-') ...(connection $client 'dest-')
            $"docker://($client.image)@($artifact.digest)"
            $"docker://($client.image):($tag)"
        | complete
    )
    require-success $result 'registry alias update failed' | ignore

    verify-manifest $client $tag $artifact.digest
}

export def verify-manifest [client: record, tag: string, digest: string] {
    let manifest = (read-manifest $client $tag)
    if $manifest == null or $manifest.digest != $digest {
        error make {msg: $"published tag ($tag) does not resolve to ($digest)"}
    }
}
