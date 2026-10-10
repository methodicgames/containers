#!/usr/bin/env -S nu --no-config-file
# SPDX-FileCopyrightText: 2026 Methodic Games LLC
# SPDX-License-Identifier: 0BSD

use std/assert
use ../bin/registry.nu *
use support.nu *

def image-addresses [] {
    assert equal (registry-context ghcr.io/methodicgames/archlinux) {
        image: 'ghcr.io/methodicgames/archlinux'
        loopback: false
        anonymous: false
    }
    assert (registry-context 127.0.0.1:5000/test --anonymous).anonymous
    assert (registry-context localhost:5000/test).loopback
    # Plain HTTP requires an explicit loopback port.
    assert not (registry-context localhost/test).loopback
    assert not (registry-context 127.0.0.1.example.test:5000/test).loopback

    for image in ['archlinux' 'ghcr.io/methodicgames/archlinux:dev'] {
        rejects { registry-context $image } 'fully qualified registry/repository'
    }
}

def manifest-identity [] {
    let raw = ({
        schemaVersion: 2
        mediaType: 'application/vnd.oci.image.manifest.v1+json'
        config: {digest: $"sha256:('config' | hash sha256)"}
    } | to json)
    assert equal (parse-manifest $raw) {digest: $"sha256:($raw | hash sha256)"}

    let index = ($raw | from json | update mediaType 'application/vnd.oci.image.index.v1+json')
    rejects { parse-manifest ($index | to json) } 'single-platform'
    rejects { parse-manifest ($index | reject mediaType | to json) } 'single-platform'
}

def main [] {
    run-tests 'registry' {
        'image addresses': { image-addresses }
        'manifest identity': { manifest-identity }
    }
}
