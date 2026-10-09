<!--
SPDX-FileCopyrightText: 2026 Methodic Games LLC
SPDX-License-Identifier: 0BSD
-->

# Goal

Provide small, reproducible OCI image families for personal development
and automation use. Each published image must be traceable to immutable
upstream inputs and the repository revision that produced it.

Users can select a documented image variant, reproduce its inputs, and
verify its expected platform, metadata, packages, and runtime behavior.
Contributors can validate a change without learning workflow-specific
implementation details.

## Priorities

1. Keep upstream operating-system state reproducible and intentionally
   updateable.
2. Keep image families narrow, documented, and validated as a coherent
   set.
3. Make local and hosted automation use the same public commands.
4. Publish immutable references alongside convenient moving aliases.
5. Preserve rootless operation, least privilege, and accurate licensing
   boundaries.

## Non-Goals

- Host-oriented interactive tooling. Images provide tools for builds
  and non-interactive jobs.
- Platforms that some upstream input or validation path does not
  support.
- A Development Container for working on this repository. The published
  `dev` image serves downstream development and Actions jobs.
