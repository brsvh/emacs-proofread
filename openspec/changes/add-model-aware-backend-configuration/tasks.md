## 1. Configuration Surface

- [ ] 1.1 Audit current backend, request, and cache helpers in
  `lisp/proofread.el`.
- [ ] 1.2 Add public configuration variables for model backend name, endpoint,
  and backend options reserved for future real backends.
- [ ] 1.3 Add or document which backend options are cache-relevant and which
  runtime-only options are excluded from cache identity.

## 2. Backend Identity Helpers

- [ ] 2.1 Implement a helper that returns the canonical backend identity for a
  selected backend.
- [ ] 2.2 Preserve existing mock backend identity compatibility.
- [ ] 2.3 Implement structured identity for configurable model backends,
  including backend name, model name, endpoint, prompt version, and
  cache-relevant options.
- [ ] 2.4 Ensure backend identity excludes request id, buffer objects,
  callbacks, timers, and absolute buffer positions.

## 3. Request and Cache Integration

- [ ] 3.1 Store the computed backend identity in backend request metadata.
- [ ] 3.2 Update diagnostic cache key construction to use the computed backend
  identity consistently.
- [ ] 3.3 Ensure cache read, cache write, and backend dispatch use the same
  identity value for a chunk.
- [ ] 3.4 Preserve current stale result validation and text matching before
  applying cached diagnostics.

## 4. Tests

- [ ] 4.1 Add ERT coverage that mock backend cache behavior remains compatible.
- [ ] 4.2 Add ERT coverage for structured model backend identity fields.
- [ ] 4.3 Add ERT coverage proving model name changes cause cache misses.
- [ ] 4.4 Add ERT coverage proving endpoint changes cause cache misses.
- [ ] 4.5 Add ERT coverage proving prompt version changes cause cache misses.
- [ ] 4.6 Add ERT coverage proving cache-relevant backend option changes cause
  cache misses.
- [ ] 4.7 Add ERT coverage proving unchanged text and unchanged identity can
  still reuse cached diagnostics.
- [ ] 4.8 Add ERT coverage proving cache hits still pass current text and stale
  result validation before overlay creation.

## 5. Validation

- [ ] 5.1 Run the batch ERT command for Emacs 30 and confirm it passes.
- [ ] 5.2 Run the batch ERT command for Emacs 31 and confirm it passes.
- [ ] 5.3 Run byte-compilation validation for `lisp/proofread.el`.
- [ ] 5.4 Run formatting validation for changed files.
- [ ] 5.5 Run `openspec status --change "add-model-aware-backend-configuration"`
  and confirm the change is complete.
- [ ] 5.6 Run
  `openspec instructions apply --change "add-model-aware-backend-configuration" --json`
  and confirm the apply workflow is ready.
- [ ] 5.7 Run
  `git diff --check -- openspec/changes/add-model-aware-backend-configuration`
  and confirm there are no whitespace errors in the change artifacts.
