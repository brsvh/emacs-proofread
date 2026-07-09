## Context

The first proofreading workflow now has enough moving pieces that unit-style
coverage alone is not sufficient. The behavior depends on buffer-local state,
visible range chunking, pre-request filtering, asynchronous backend callbacks,
stale result checks, diagnostic cache keys, proofread-owned overlays, navigation
commands, ignore state, and manual text replacement.

The repository already has an ERT test file at `test/proofread-tests.el` and
flake applications such as `nix run .#emacs30-run-proofread-tests` and
`nix run .#emacs31-run-proofread-tests`. Those commands run batch Emacs with a
temporary init directory, which matches the requirement that validation be
offline and repeatable.

## Goals / Non-Goals

**Goals:**

- Cover the first complete diagnostic workflow with focused ERT tests.
- Keep tests deterministic and offline by using mock backend behavior.
- Validate asynchronous paths with bounded waits instead of synchronous
  shortcuts.
- Validate `lisp/proofread.el` through byte compilation in batch Emacs.
- Preserve the existing formatting validation path and document the command
  developers should run.
- Keep validation commands runnable from the repository root.

**Non-Goals:**

- Do not test real HTTP, CLI, local model, or hosted model backends.
- Do not add integration tests that require network access or external services.
- Do not add screenshot, redisplay pixel, or UI automation tests.
- Do not add persistent cache fixtures or project-wide shared test state.

## Decisions

1. Use ERT as the primary test framework.

   ERT is already used by the project and runs cleanly in batch Emacs. Extending
   `test/proofread-tests.el` keeps the validation surface small and avoids
   introducing another dependency. The alternative would be a separate test
   harness, but that would add setup cost without improving coverage for this
   package-level behavior.

2. Test asynchronous behavior with bounded wait helpers.

   Mock backend callbacks, idle scheduling, and request dispatch must remain
   asynchronous in tests. The test suite should use small bounded helpers around
   `accept-process-output` or timer processing so a failing test times out
   predictably instead of hanging. The alternative of calling callbacks directly
   would make tests simpler but would miss the class of bugs caused by stale
   buffers, disabled modes, and delayed callbacks.

3. Keep test fixtures buffer-local and disposable.

   Each test should create temporary buffers, enable `proofread-mode` only where
   required, and clean up windows, timers, overlays, active requests, cache
   state, and ignore state. This matches how the package isolates runtime state.
   Shared global fixtures would reduce boilerplate but make cache and ignore
   tests order-dependent.

4. Use the mock backend for all backend-facing tests.

   The mock backend is sufficient to verify request shape, callback timing,
   stale rejection, cache reuse, and error handling. Real backend tests belong
   to later backend-specific changes because they require protocol details and
   external process or network behavior.

5. Treat validation commands as part of the deliverable.

   Developers need a stable command path for tests, byte compilation, and
   formatting. The existing flake-provided test applications should stay the
   preferred path because they run with a clean init directory. If byte
   compilation or formatting does not already have a flake application, this
   change can add one or document a batch command that has the same clean-init
   property.

## Risks / Trade-offs

- Timer-based tests can become flaky -> Keep wait durations bounded, avoid
  depending on wall-clock precision, and assert state changes rather than exact
  timing.
- Cache tests can become order-dependent -> Clear buffer-local and global
  proofread state in each test fixture before assertions.
- Byte compilation can surface warnings from optional APIs -> Require or declare
  the package-owned symbols needed by `proofread.el`, and keep the validation
  focused on missing functions or variables.
- Validation commands can drift from documentation -> Put the commands in one
  documented location or flake app and reference that path from tasks.
- Broad tests can slow iteration -> Prefer small behavior-focused tests with
  local buffers over large end-to-end scenarios.
