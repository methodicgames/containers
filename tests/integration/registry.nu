#!/usr/bin/env -S nu --no-config-file

use std/assert
use ../../bin/publication.nu *
use ../../bin/registry.nu *
use ../support.nu *

const registry_image = 'docker.io/library/registry:3.0.0@sha256:5b12b22f21522fe69443079df04c0f3f42cb9977857f3c20404386652a6c6d8e'

def wait-for-registry [binding: string, expected_status: int] {
    for attempt in 0..<50 {
        let response = try {
            http get --allow-errors --full --max-time 1sec $"http://($binding)/v2/"
        } catch {
            {status: 0}
        }
        if $response.status == $expected_status {
            return
        }

        sleep 100ms
    }

    error make {msg: 'disposable registry did not become ready'}
}

# The operation receives the loopback binding. Always remove a started registry.
def with-registry [options: list<string>, expected_status: int, operation: closure] {
    let container_id = (
        ^podman run --detach --rm --publish 127.0.0.1::5000 ...$options $registry_image
        | str trim
    )
    let failure = try {
        let binding = (^podman port $container_id 5000/tcp | str trim)
        wait-for-registry $binding $expected_status
        do $operation $binding
        null
    } catch {|err|
        $err
    }

    ^podman rm --force --ignore $container_id | ignore
    if $failure != null {
        error make {msg: $failure.rendered}
    }
}

def publication-fixture [image: string, directory: path] {
    let client = (registry-context $image --anonymous)
    let revision = ('a' | fill --width 40 --character a)
    let expected = {
        image: $image
        variant: 'base'
        version: '2026.09.01-2'
        revision: $revision
    }

    let containerfile = ($directory | path join 'Containerfile')
    [
        'FROM scratch'
        'LABEL org.opencontainers.image.source="https://github.com/methodicgames/containers"'
        $'LABEL org.opencontainers.image.revision="($revision)"'
        'ARG VERSION'
        'LABEL org.opencontainers.image.version="${VERSION}"'
        'LABEL games.methodic.containers.variant="base"'
    ] | str join (char newline) | save $containerfile

    let state_file = ($directory | path join 'state.json')
    {failure: '', creates: 0, promotions: 0} | to json | save $state_file
    let backend = {
        lookup: {|tag| lookup-artifact $client $tag }
        create: {|tag|
            (
                ^podman build --layers=false --no-cache
                    --platform linux/amd64
                    --file $containerfile
                    --build-arg $"VERSION=($tag | str replace 'base-' '')"
                    --tag $"($image):($tag)"
                    $directory
                | ignore
            )
            let digestfile = ($directory | path join 'digest')
            (
                ^podman push --quiet --tls-verify=false
                    --digestfile $digestfile
                    $"($image):($tag)"
                | ignore
            )
            verify-manifest $client $tag (open --raw $digestfile | str trim)

            let count = (open $state_file | get creates)
            open $state_file | update creates ($count + 1) | save --force $state_file
            if (open $state_file | get failure) == 'create' {
                open $state_file | update failure '' | save --force $state_file
                error make {msg: 'injected interruption after release upload'}
            }

            lookup-artifact $client $tag
        }
        smoke: {|artifact|
            let image_ref = $"($image)@($artifact.digest)"
            ^podman pull --quiet --tls-verify=false $image_ref | ignore
            let details = (^podman image inspect $image_ref | from json | first)
            assert equal $details.Architecture 'amd64'
        }
        promote: {|tag, artifact|
            promote-manifest $client $tag $artifact

            let count = (open $state_file | get promotions)
            open $state_file | update promotions ($count + 1) | save --force $state_file
            if (open $state_file | get failure) == $tag {
                open $state_file | update failure '' | save --force $state_file
                error make {msg: 'injected interruption after alias upload'}
            }
        }
        verify: {|tag, digest| verify-manifest $client $tag $digest }
        receipt: {|receipt|
            $receipt | to json | save --force ($directory | path join 'receipt.json')
        }
    }

    {expected: $expected, backend: $backend, client: $client, state_file: $state_file}
}

def publication-recovery [fixture: record] {
    let expected = $fixture.expected
    let backend = $fixture.backend
    let state_file = $fixture.state_file
    assert equal (lookup-artifact $fixture.client 'base-2026.09.01-2') null

    # Lose the runner immediately after the immutable manifest reaches the registry.
    open $state_file | update failure 'create' | save --force $state_file
    rejects { publish-release $expected $backend } 'injected interruption'
    let first_digest = (read-manifest $fixture.client 'base-2026.09.01-2').digest

    # Then interrupt after each alias upload; every retry must reuse the release.
    for tag in ['base-2026.09.01' 'base'] {
        open $state_file | update failure $tag | save --force $state_file
        rejects { publish-release $expected $backend } 'injected interruption'
    }

    let receipt = (publish-release $expected $backend)
    assert equal $receipt.digest $first_digest
    assert equal (open $state_file | get creates) 1
    assert equal (open $state_file | get promotions) 2

    # A fresh invocation recovers using registry state alone.
    publish-release $expected $backend | ignore
    assert equal (open $state_file | get creates) 1
    assert equal (open $state_file | get promotions) 2
}

def alias-ordering [fixture: record] {
    let expected = $fixture.expected
    let backend = $fixture.backend
    let client = $fixture.client
    publish-release $expected $backend | ignore

    let newer = ($expected | update version '2026.09.01-10')
    let newer_receipt = (publish-release $newer $backend)
    let late_receipt = (publish-release $expected $backend)
    assert equal ($late_receipt.aliases | get action) ['retained' 'retained']
    verify-manifest $client 'base' $newer_receipt.digest

    let future = ($expected | update version '2026.10.01-1')
    let repair = ($expected | update version '2026.09.01-11')
    let future_receipt = (publish-release $future $backend)
    let repair_receipt = (publish-release $repair $backend)
    assert equal ($repair_receipt.aliases | get action) ['promote' 'retained']
    verify-manifest $client 'base' $future_receipt.digest
    verify-manifest $client 'base-2026.09.01' $repair_receipt.digest
}

def authentication [source_image: string, directory: path] {
    let authdir = ($directory | path join 'auth' | path expand)
    mkdir $authdir
    # Public fixture credentials: tester / publication-test. Never a real account.
    'tester:$2b$12$j2ClrOzSSqLnNeUerXAyCeHB5nvye41HVJ74bspOWvNg18yKrlE8i'
    | save ($authdir | path join 'htpasswd')
    let authfile = ($authdir | path join 'client.json')
    let options = [
        '--env' 'REGISTRY_AUTH=htpasswd'
        '--env' 'REGISTRY_AUTH_HTPASSWD_REALM=Publication Tests'
        '--env' 'REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd'
        '--volume' $"($authdir):/auth:ro"
    ]

    with-registry $options 401 {|binding|
        let image = $"($binding)/authenticated-test"
        (
            'publication-test'
            | ^podman login --tls-verify=false --authfile $authfile
                    --username tester --password-stdin $binding
            | ignore
        )

        with-env {REGISTRY_AUTH_FILE: $authfile} {
            let client = (registry-context $image)
            assert ($client.basic_auth != '') 'Podman login credentials were not loaded'
            assert equal (lookup-artifact $client 'base-2026.09.01-2') null

            (
                ^podman push --quiet --authfile $authfile --tls-verify=false
                    $"($source_image):base-2026.09.01-2" $"($image):base-2026.09.01-2"
                | ignore
            )
            let artifact = (lookup-artifact $client 'base-2026.09.01-2')
            promote-manifest $client 'base' $artifact
            verify-manifest $client 'base' $artifact.digest

            rejects {
                lookup-artifact (registry-context $image --anonymous) 'base'
            } 'registry requires credentials'

            let wrong = ($client | update basic_auth ('tester:incorrect' | encode base64))
            rejects { lookup-artifact $wrong 'base' } 'HTTP 401'
        }
    }
}

def remove-fixture-images [image: string] {
    let references = (
        ^podman images --format json
        | from json
        | each {|entry| ($entry.Names? | default []) ++ ($entry.RepoDigests? | default []) }
        | flatten
        | where {|name|
                ($name starts-with $"($image):") or ($name starts-with $"($image)@")
            }
        | uniq
    )

    for reference in $references {
        if (^podman image exists $reference | complete).exit_code == 0 {
            ^podman rmi $reference | ignore
        }
    }
}

# Each scenario gets its own registry, image names, and persisted backend state.
def with-publication-fixture [operation: closure] {
    let directory = (test-directory 'registry-tests')
    let image_file = ($directory | path join 'image.txt')
    let failure = try {
        with-registry [] 200 {|binding|
            let image = $"($binding)/publication-test-($directory | path basename)"
            $image | save $image_file
            let fixture = (publication-fixture $image $directory)

            do $operation $fixture $directory
        }
        null
    } catch {|err|
        $err
    }

    if ($image_file | path exists) {
        remove-fixture-images (open --raw $image_file)
    }
    if $failure != null {
        error make {msg: $failure.rendered}
    }
}

def main [] {
    run-tests 'registry integration' {
        'publication recovery': {
            with-publication-fixture {|fixture, directory|
                publication-recovery $fixture
            }
        }
        'alias ordering': {
            with-publication-fixture {|fixture, directory|
                alias-ordering $fixture
            }
        }
        'authentication and credential isolation': {
            with-publication-fixture {|fixture, directory|
                publish-release $fixture.expected $fixture.backend | ignore
                authentication $fixture.expected.image $directory
            }
        }
    }
}
