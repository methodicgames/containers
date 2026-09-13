# Small test utilities shared by the standalone std/assert suites.

use std/assert

export def test-directory [suite: string] {
    let directory = ('.tmp' | path join $suite (random uuid) | path expand)
    mkdir $directory
    $directory
}

export def rejects [operation: closure, message: string] {
    let failure = try {
        do $operation
        null
    } catch {|err|
        $err.rendered
    }

    assert ($failure != null) $"expected failure: ($message)"
    assert ($failure | str contains $message) $"unexpected failure: ($failure)"
}

# Each named case is a zero-argument closure. Stop at the first failed assertion.
export def run-tests [suite: string, cases: record] {
    for case in ($cases | transpose name run) {
        print $"Testing ($suite): ($case.name)"
        do $case.run
    }

    print $"Passed ($cases | columns | length) ($suite) scenarios."
}
