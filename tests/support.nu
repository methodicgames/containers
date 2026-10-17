# SPDX-FileCopyrightText: 2026 Methodic Games LLC
# SPDX-License-Identifier: 0BSD

# Small test utilities shared by the standalone std/assert suites.

use std/assert

export def test-directory [suite: string] {
    let directory = ('.tmp' | path join $suite (random uuid) | path expand)
    mkdir $directory
    $directory
}

# An error's own message and those of the errors nested inside it. Unlike the
# rendered error, these are not wrapped and exclude quoted source code.
def error-messages [details: record] {
    [$details.msg] ++ ($details.inner | each {|inner| error-messages $inner } | flatten)
}

export def rejects [operation: closure, message: string] {
    let failure = try {
        do $operation
        null
    } catch {|err|
        error-messages $err.details | str join (char newline)
    }

    assert ($failure != null) $"expected failure: ($message)"
    assert ($failure | str contains $message) $"expected failure: ($message); got: ($failure)"
}

# Subprocess results come from `complete`.
export def succeeds [result: record] {
    assert equal $result.exit_code 0 $"unexpected failure: ($result.stderr)"
}

# The context names the command when one scenario checks several.
export def fails [result: record, message: string, --context: string = ''] {
    let prefix = if $context == '' { '' } else { $"($context): " }
    assert ($result.exit_code != 0) $"($prefix)expected failure: ($message)"
    assert ($result.stderr | str contains $message) (
        $"($prefix)expected failure: ($message); got: ($result.stderr)"
    )
}

# Each named case is a zero-argument closure. Stop at the first failed assertion.
export def run-tests [suite: string, cases: record] {
    for case in ($cases | transpose name run) {
        print $"Testing ($suite): ($case.name)"
        do $case.run
    }

    print $"Passed ($cases | columns | length) ($suite) scenarios."
}
