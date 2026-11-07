---
name: update-tested-versions
description: Keep the "Tested versions" table in README.md up to date. Use this skill before every release of the module (a new tag or version), after every live test in tests/live that used a Talos or Kubernetes version, and whenever the defaults talos_version or kubernetes_version in variables.tf change.
---

# Update the tested versions table

The root `README.md` has a section "Tested versions". The table in that section tells users which Talos and Kubernetes versions the module ran with on real Contabo instances. Users trust the table, so every row must come from a real live test run.

## When to update the table

- Before a release: every live test run since the last release must have a row. Replace `unreleased` in the "Module version" column with the new version, for example `v0.2.0`.
- After a live test in `tests/live` (for example `tests/live/cluster` or `tests/live/ha`) that passed or failed with a Talos or Kubernetes version.
- When the defaults `talos_version` or `kubernetes_version` in `variables.tf` change. Do not release a new default that has no "Passed" row.

## How to add a row

1. Read the versions from the test, for example from the `talos_version` and `kubernetes_version` variables of the test, or from `talosctl version` and `kubectl version` on the cluster.
2. Write one row per test run. Put the newest row at the top.
3. Fill in the columns:
   - "Module version": `unreleased` until the release, then the version tag.
   - "Talos" and "Kubernetes": one version, or "A to B" for an upgrade test.
   - "What the test did": one or two full sentences, for example "New cluster with three control plane nodes and Longhorn."
   - "Result": `Passed` or `Failed`.
   - "Date": the day of the test, in the form `2026-11-07`.
4. For a failed test, write the reason in "What the test did", for example "The upgrade failed, because talosctl removed the flag --legacy." Keep failed rows, so that users can avoid that combination.
5. Never delete old rows. When a row is wrong, fix the row and say why in the pull request.

## Rules for the text

Write the rows in simple English for a 9th grader, as the `writing-docs` skill describes. Use full sentences in the "What the test did" column. Never write real instance ids, private network ids or object storage ids into the table.
