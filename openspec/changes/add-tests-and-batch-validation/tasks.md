## 1. Test Infrastructure

- [x] 1.1 Audit existing `test/proofread-tests.el` helpers and identify reusable
  fixtures for temporary buffers, visible windows, overlays, async waits, and
  mock backend calls.
- [x] 1.2 Add or extend a bounded async wait helper for timers and backend
  callbacks so failed async tests time out predictably.
- [x] 1.3 Add test helpers for installing a mock backend, recording requests,
  returning diagnostics, and returning backend errors.
- [x] 1.4 Add cleanup helpers or fixture patterns that clear proofread mode
  state, active requests, overlays, cache entries, ignore entries, idle timers,
  and temporary windows after each test.
- [x] 1.5 Ensure the test suite can run in batch Emacs with a clean init
  directory and without network access.

## 2. Pipeline Coverage

- [x] 2.1 Add or complete ERT coverage for ordinary paragraph chunking.
- [x] 2.2 Add or complete ERT coverage proving whitespace-only text produces no
  chunks.
- [x] 2.3 Add or complete ERT coverage proving oversized paragraphs split into
  bounded, stable chunks.
- [x] 2.4 Add assertions that every chunk's `:text` exactly matches the recorded
  absolute buffer range.
- [x] 2.5 Add or complete ERT coverage for URL and email pre-request filtering.
- [x] 2.6 Add or complete ERT coverage for ignored face, ignored property, and
  invisible text pre-request filtering.
- [x] 2.7 Add assertions proving filtered text is removed before cache lookup
  and backend dispatch.

## 3. Async Dispatch and Stale Rejection

- [x] 3.1 Add tests proving backend dispatch records active requests and clears
  them after success callbacks.
- [x] 3.2 Add tests proving backend error callbacks preserve buffer text and
  clear active requests.
- [x] 3.3 Add tests proving callbacks for killed buffers do not create overlays
  or mutate proofread state.
- [x] 3.4 Add tests proving callbacks after `proofread-mode` is disabled do not
  create overlays or mutate proofread state.
- [x] 3.5 Add tests proving tick changes reject stale results.
- [x] 3.6 Add tests proving chunk text mismatches reject stale results.
- [x] 3.7 Add assertions that stale results never create proofread-owned
  overlays.

## 4. Overlay and Cache Coverage

- [x] 4.1 Add or complete tests for `proofread-clear` deleting proofread-owned
  overlays while preserving unrelated overlays.
- [x] 4.2 Add or complete tests for edit invalidation of affected
  proofread-owned overlays.
- [x] 4.3 Add or complete tests for disabling `proofread-mode` clearing
  proofread-owned overlays and buffer-local state.
- [x] 4.4 Add tests proving unchanged visible text can reuse cached diagnostics
  without another backend call.
- [x] 4.5 Add tests proving cache misses call the backend.
- [x] 4.6 Add tests proving backend name, prompt version, and relevant filtering
  configuration changes invalidate old cache entries.
- [x] 4.7 Add tests proving cached diagnostics still pass current text and stale
  result validation before overlay creation.

## 5. Diagnostic Interaction Coverage

- [x] 5.1 Add tests for diagnostic sorting used by navigation.
- [x] 5.2 Add tests for `proofread-next` and `proofread-previous` point movement
  and boundary feedback.
- [x] 5.3 Add tests for empty diagnostic navigation behavior.
- [x] 5.4 Add tests for `proofread-describe` on a diagnostic, with no diagnostic
  at point, and with multiple suggestions.
- [x] 5.5 Add assertions that description UI does not modify source buffer text.
- [x] 5.6 Add tests for applying a single suggestion and choosing among multiple
  suggestions.
- [x] 5.7 Add tests proving stale overlays or original-text mismatches reject
  suggestion application.
- [x] 5.8 Add tests proving suggestion application creates a clear undo step and
  removes or invalidates affected proofread overlays.
- [x] 5.9 Add tests for `proofread-ignore` exact text/kind matching, different
  kind behavior, unrelated diagnostics, and overlay removal.

## 6. Validation Commands

- [x] 6.1 Document the preferred batch ERT command, including
  `nix run .#emacs30-run-proofread-tests`.
- [x] 6.2 Verify or document the Emacs 31 batch ERT command when available,
  including `nix run .#emacs31-run-proofread-tests`.
- [x] 6.3 Add or document a clean batch byte-compilation command for
  `lisp/proofread.el`.
- [x] 6.4 Ensure byte-compilation validation fails on missing proofread-owned
  functions or variables.
- [x] 6.5 Document or preserve the existing formatting validation command or
  hook for changed package files.
- [x] 6.6 Ensure validation documentation distinguishes ERT, byte-compilation,
  and formatting failures.

## 7. Final Verification

- [x] 7.1 Run the documented batch ERT command and confirm it passes offline.
- [x] 7.2 Run byte-compilation validation and confirm no missing function or
  variable warnings remain for `proofread.el`.
- [x] 7.3 Run formatting validation and confirm it passes.
- [x] 7.4 Run `openspec status --change "add-tests-and-batch-validation"` and
  confirm the change is complete.
- [x] 7.5 Run
  `openspec instructions apply --change "add-tests-and-batch-validation" --json`
  and confirm the apply workflow is ready.
- [x] 7.6 Run
  `git diff --check -- openspec/changes/add-tests-and-batch-validation` and
  confirm there are no whitespace errors in the change artifacts.
