#!/usr/bin/env -S nu --no-config-file

use std/assert
use ../bin/registry.nu *
use support.nu *

def credential-file [] {
    let directory = (test-directory 'registry-unit-tests')
    let file = ($directory | path join 'auth.json')
    {auths: {
        'example.test': {auth: 'host'}
        'example.test/team': {auth: 'team'}
        'example.test/team/image': {auth: 'image'}
    }} | to json | save $file

    $file
}

def manifest-responses [] {
    let missing = {status: 404, body: '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}'}
    assert equal (parse-manifest-response $missing) null

    for status in [401 403 429 500 503] {
        rejects {
            parse-manifest-response ($missing | update status $status)
        } $"HTTP ($status)"
    }

    for body in ['not JSON' '{"errors":[{"code":"NAME_UNKNOWN"}]}' '{"errors":[]}'] {
        rejects {
            parse-manifest-response ($missing | update body $body)
        } 'HTTP 404'
    }

    let config_digest = $"sha256:('config' | hash sha256)"
    let raw = ({
        schemaVersion: 2
        mediaType: 'application/vnd.oci.image.manifest.v1+json'
        config: {digest: $config_digest}
    } | to json)
    let response = {status: 200, body: $raw, headers: {response: []}}
    assert equal (parse-manifest-response $response).digest $"sha256:($raw | hash sha256)"

    let wrong_header = {name: 'Docker-Content-Digest', value: $config_digest}
    let conflicting = ($response | update headers.response [$wrong_header])
    rejects { parse-manifest-response $conflicting } 'digest mismatch'
}

def scoped-credentials [] {
    let file = (credential-file)
    with-env {REGISTRY_AUTH_FILE: $file} {
        assert equal (registry-context example.test/team/image).basic_auth 'image'
        assert equal (registry-context example.test/team/other).basic_auth 'team'
        assert equal (registry-context example.test/other/image).basic_auth 'host'
        assert equal (registry-context unrelated.test/team/image).basic_auth ''
        assert equal (registry-context example.test/team/image --anonymous).basic_auth ''
    }
}

def credential-filenames [] {
    let original = (credential-file)
    let directory = ($original | path dirname)

    for name in ['credentials' 'credentials.yaml'] {
        let file = ($directory | path join $name)
        cp $original $file

        with-env {REGISTRY_AUTH_FILE: $file} {
            assert equal (registry-context example.test/team/image).basic_auth 'image'
            assert equal (registry-context example.test/team/image --anonymous).basic_auth ''
        }
    }
}

def runtime-credentials [] {
    let original = (credential-file)
    let runtime = ($original | path dirname | path join 'runtime')
    mkdir ($runtime | path join 'containers')
    cp $original ($runtime | path join 'containers/auth.json')

    with-env {REGISTRY_AUTH_FILE: '', DOCKER_CONFIG: '', XDG_RUNTIME_DIR: $runtime} {
        assert equal (registry-context example.test/team/image).basic_auth 'image'
        assert equal (registry-context example.test/team/other).basic_auth 'team'
        assert equal (registry-context example.test/other/image).basic_auth 'host'
        assert equal (registry-context example.test/team/image --anonymous).basic_auth ''
    }
}

def config-home-credentials [] {
    let original = (credential-file)
    let directory = ($original | path dirname)
    let runtime = ($directory | path join 'runtime')
    let config = ($directory | path join 'config')
    mkdir $runtime ($config | path join 'containers')
    cp $original ($config | path join 'containers/auth.json')

    with-env {
        REGISTRY_AUTH_FILE: ''
        DOCKER_CONFIG: ''
        XDG_RUNTIME_DIR: $runtime
        XDG_CONFIG_HOME: $config
    } {
        assert equal (registry-context example.test/team/image).basic_auth 'image'
        assert equal (registry-context example.test/team/other).basic_auth 'team'
        assert equal (registry-context example.test/team/image --anonymous).basic_auth ''
    }
}

def credential-precedence [] {
    let original = (credential-file)
    let directory = ($original | path dirname)
    let runtime = ($directory | path join 'runtime')
    let config = ($directory | path join 'config')
    let docker = ($directory | path join 'docker')
    mkdir ($runtime | path join 'containers') ($config | path join 'containers') $docker
    cp $original ($runtime | path join 'containers/auth.json')
    cp $original ($config | path join 'containers/auth.json')
    {auths: {'example.test': {auth: 'docker'}}}
    | to json | save ($docker | path join 'config.json')

    with-env {
        REGISTRY_AUTH_FILE: ''
        DOCKER_CONFIG: $docker
        XDG_RUNTIME_DIR: $runtime
        XDG_CONFIG_HOME: $config
    } {
        assert equal (registry-context example.test/team/image).basic_auth 'docker'
        assert equal (registry-context example.test/team/image --anonymous).basic_auth ''

        with-env {REGISTRY_AUTH_FILE: $original} {
            assert equal (registry-context example.test/team/image).basic_auth 'image'
        }

        # An explicit Docker config is exclusive, even when fallback files have credentials.
        '{"auths":{}}' | save --force ($docker | path join 'config.json')
        assert equal (registry-context example.test/team/image).basic_auth ''
    }
}

def main [] {
    run-tests 'registry' {
        'manifest responses and digest integrity': { manifest-responses }
        'repository-scoped credentials': { scoped-credentials }
        'authentication filenames': { credential-filenames }
        'runtime credential discovery': { runtime-credentials }
        'config-home credential discovery': { config-home-credentials }
        'credential precedence and isolation': { credential-precedence }
    }
}
