## Why

The first proofreading workflow now spans asynchronous callbacks, overlay
lifecycle, cache reuse, navigation, ignores, and user-triggered edits. Those
paths need offline, repeatable validation before real backends and richer UI can
be added without regressing the core correctness guarantees.

## What Changes

- Expand ERT coverage for chunking, filtering, stale result rejection, overlay
  cleanup, cache reuse and invalidation, navigation, diagnostic description,
  ignore behavior, and manual suggestion application.
- Keep all tests offline by using the mock backend and local Emacs batch
  execution.
- Add or document stable batch validation commands for running the test suite
  from the repository root.
- Add byte-compilation validation for `lisp/proofread.el` so missing functions
  or variables are caught during local and CI-style checks.
- Keep the existing formatting hook or formatting command in the documented
  validation path.
- Do not add real network backend tests, live model tests, or persistent test
  services.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Add offline batch validation requirements for the first
  core proofreading workflow, including ERT coverage, byte compilation, and
  formatting checks.

## Impact

- Affects `test/proofread-tests.el` with focused tests for the core behavior
  added through the preceding changes.
- May affect `flake.nix`, documentation, or helper scripts to expose stable
  test, byte-compilation, and formatting validation commands.
- Depends on `add-ignore-diagnostics` so the tests cover the complete first
  diagnostic interaction loop.
- Adds no network dependency, live backend, persistent cache, or external model
  service requirement.
