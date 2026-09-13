# Registry authentication and manifest transport. No publication policy.

const manifest_media_types = [
    'application/vnd.oci.image.manifest.v1+json'
    'application/vnd.docker.distribution.manifest.v2+json'
]

def body-text [] {
    let body = $in
    if ($body | describe) == 'binary' {
        $body | decode utf-8
    } else {
        $body | into string
    }
}

def parse-registry-address [image: string] {
    let pattern = '^(?<host>[a-z0-9.-]+(?::[0-9]+)?)/(?<repository>[a-z0-9._/-]+)$'
    let matches = ($image | parse --regex $pattern)
    if ($matches | is-empty) {
        error make {msg: 'IMAGE must be a fully qualified registry/repository without a tag'}
    }

    let address = ($matches | first)
    let loopback = ($address.host =~ '^(localhost|127[.]0[.]0[.]1):[0-9]+$')
    let scheme = if $loopback { 'http' } else { 'https' }

    $address | merge {
        image: $image
        origin: $"($scheme)://($address.host)"
        loopback: $loopback
    }
}

# Capture Podman's environment-dependent search order at client construction.
def authentication-files [] {
    let override = ($env.REGISTRY_AUTH_FILE? | default '')
    if $override != '' {
        return [$override]
    }

    let docker_config = ($env.DOCKER_CONFIG? | default '')
    if $docker_config != '' {
        return [($docker_config | path join 'config.json')]
    }

    let runtime = ($env.XDG_RUNTIME_DIR? | default '')
    let runtime_file = if $runtime != '' {
        $runtime | path join 'containers/auth.json'
    } else {
        $'/run/containers/(^id -u | str trim)/auth.json'
    }

    let configured_home = ($env.XDG_CONFIG_HOME? | default '')
    let config_home = if $configured_home != '' {
        $configured_home
    } else {
        $nu.home-dir | path join '.config'
    }

    [
        $runtime_file
        ($config_home | path join 'containers/auth.json')
        ($nu.home-dir | path join '.docker/config.json')
    ]
}

def read-basic-credentials [address: record, files: list<string>] {
    for file in $files {
        if not ($file | path exists) {
            continue
        }

        let entries = (open --raw $file | from json | get -o auths | default {})
        # Prefer a repository-scoped login over a registry-wide login.
        let matching_keys = (
            $entries
            | columns
            | where {|key|
                    (
                        $key == $address.host
                        or $key == $address.image
                        or ($address.image starts-with $"($key)/")
                    )
                }
            | sort-by {|key| $key | str length } --reverse
        )

        for key in $matching_keys {
            let credentials = ($entries | get $key | get -o auth | default '')
            if $credentials != '' {
                return $credentials
            }
        }
    }

    ''
}

# Context fields: image, host, repository, origin, loopback, basic_auth.
# basic_auth holds encoded Basic credentials; anonymous contexts read no files.
export def registry-context [image: string, --anonymous] {
    let address = (parse-registry-address $image)
    let basic_auth = if $anonymous {
        ''
    } else {
        read-basic-credentials $address (authentication-files)
    }

    $address | insert basic_auth $basic_auth
}

def response-header [response: record, name: string] {
    $response.headers.response
    | where {|header| ($header.name | str lowercase) == $name }
    | get value
    | get -o 0
    | default ''
}

def request [
    method: string
    url: string
    headers: record
    body: string = ''
    media: string = 'application/json'
] {
    # Do not include HTTP error objects: they can contain authentication headers.
    try {
        if $method == 'GET' {
            (
                http get --raw --full --allow-errors
                    --redirect-mode manual
                    --max-time 60sec
                    --headers $headers
                    $url
            )
        } else {
            (
                http put --raw --full --allow-errors
                    --redirect-mode error
                    --max-time 60sec
                    --headers $headers
                    --content-type $media
                    $url $body
            )
        }
    } catch {
        error make {msg: $"registry ($method) transport failed"}
    }
}

def bearer-token [client: record, challenge: string, method: string] {
    let fields = (
        $challenge
        | parse --regex '(?<key>[a-z]+)="(?<value>[^"]*)"'
        | transpose --header-row --as-record
    )
    let realm = ($fields.realm | url parse)
    let supported_realm = (
        $realm.scheme == 'https'
        and $realm.host == ($client.origin | url parse).host
        and $realm.username == ''
        and $realm.password == ''
        and $realm.query == ''
    )
    if not $supported_realm {
        error make {
            msg: 'unsupported registry authentication realm; expected HTTPS on the registry host'
        }
    }

    let access = if $method == 'PUT' { 'pull,push' } else { 'pull' }
    let query = ({
        service: $fields.service
        scope: $"repository:($client.repository):($access)"
    } | url build-query)
    let headers = if $client.basic_auth == '' {
        {}
    } else {
        {Authorization: $"Basic ($client.basic_auth)"}
    }

    let response = (request 'GET' $"($fields.realm)?($query)" $headers)
    if $response.status != 200 {
        error make {msg: $"registry token request failed: HTTP ($response.status)"}
    }

    let payload = ($response.body | body-text | from json)
    let token = ($payload.token? | default ($payload.access_token? | default ''))
    if $token == '' {
        error make {msg: 'registry returned no bearer token'}
    }

    $token
}

def authorization-header [client: record, challenge: string, method: string] {
    let scheme = ($challenge | str lowercase)
    if ($scheme | str starts-with 'basic ') {
        if $client.basic_auth == '' {
            error make {msg: 'registry requires credentials; run podman login'}
        }
        return $"Basic ($client.basic_auth)"
    }

    if ($scheme | str starts-with 'bearer ') {
        return $"Bearer (bearer-token $client $challenge $method)"
    }

    error make {msg: 'unsupported registry authentication challenge'}
}

def registry-request [
    client: record
    method: string
    path: string
    body: string = ''
    media: string = 'application/json'
] {
    let url = $"($client.origin)/v2/($client.repository)/($path)"
    let headers = {Accept: ($manifest_media_types | str join ', ')}

    let response = (request $method $url $headers $body $media)
    if $response.status != 401 {
        return $response
    }

    let challenge = (response-header $response 'www-authenticate')
    let authorization = (authorization-header $client $challenge $method)
    let authenticated_headers = ($headers | insert Authorization $authorization)
    request $method $url $authenticated_headers $body $media
}

# Return null only for the registry's structured missing-manifest response.
# Successful results retain raw manifest bytes for digest-preserving promotion.
export def parse-manifest-response [response: record] {
    if $response.status == 404 {
        let codes = try {
            $response.body | body-text | from json | get errors.code
        } catch {
            []
        }
        if ($codes | length) == 1 and $codes.0 == 'MANIFEST_UNKNOWN' {
            return null
        }
    }
    if $response.status != 200 {
        error make {msg: $"registry manifest lookup failed: HTTP ($response.status)"}
    }

    let raw = ($response.body | body-text)
    let manifest = ($raw | from json)
    if $manifest.schemaVersion != 2 or $manifest.mediaType not-in $manifest_media_types {
        error make {msg: 'expected a single-platform OCI or Docker v2 image manifest'}
    }

    let digest = $"sha256:($raw | hash sha256)"
    let supplied_digest = (response-header $response 'docker-content-digest')
    if $supplied_digest != '' and $supplied_digest != $digest {
        error make {msg: 'registry manifest digest mismatch'}
    }

    {
        digest: $digest
        raw: $raw
        media: $manifest.mediaType
        config_digest: $manifest.config.digest
    }
}

export def read-manifest [client: record, reference: string] {
    if not ($reference =~ '^[a-zA-Z0-9_][a-zA-Z0-9_.:-]*$') {
        error make {msg: 'invalid manifest reference'}
    }

    let response = (registry-request $client 'GET' $"manifests/($reference)")
    parse-manifest-response $response
}

def read-image-config [client: record, digest: string] {
    if not ($digest =~ '^sha256:[0-9a-f]{64}$') {
        error make {msg: 'invalid config digest'}
    }

    mut response = (registry-request $client 'GET' $"blobs/($digest)")
    if $response.status in [302 307] {
        let location = (response-header $response 'location')
        if ($location | url parse).scheme != 'https' {
            error make {msg: 'insecure registry blob redirect'}
        }
        # Blob storage uses signed URLs; never forward registry credentials there.
        $response = (request 'GET' $location {})
    }

    if $response.status != 200 {
        error make {msg: $"registry config lookup failed: HTTP ($response.status)"}
    }
    if $"sha256:($response.body | hash sha256)" != $digest {
        error make {msg: 'registry config digest mismatch'}
    }

    $response.body | body-text | from json
}

export def lookup-artifact [client: record, reference: string] {
    let manifest = (read-manifest $client $reference)
    if $manifest == null {
        return null
    }

    let config = (read-image-config $client $manifest.config_digest)
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
    # Retag the exact remote manifest bytes, avoiding conversion or recompression.
    let response = (
        registry-request $client 'PUT' $"manifests/($tag)" $artifact.raw $artifact.media
    )
    if $response.status != 201 {
        error make {msg: $"registry alias update failed: HTTP ($response.status)"}
    }

    verify-manifest $client $tag $artifact.digest
}

export def verify-manifest [client: record, tag: string, digest: string] {
    let manifest = (read-manifest $client $tag)
    if $manifest == null or $manifest.digest != $digest {
        error make {msg: $"published tag ($tag) does not resolve to ($digest)"}
    }
}
