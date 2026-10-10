# SPDX-FileCopyrightText: 2026 Methodic Games LLC
# SPDX-License-Identifier: 0BSD

# Command-boundary failures end the command with a one-line diagnostic that
# callers and subprocess tests can match. Nushell wraps long `error make`
# messages across lines, so use `error make` only for failures that a caller may
# catch or that stay short; exported helpers that call this end the process.
export def fail [message: string, code: int = 1] {
    print --stderr $"error: ($message)"
    exit $code
}
