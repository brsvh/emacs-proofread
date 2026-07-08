## Why

`proofread` can already cache diagnostics by backend identity, but future real
backends need to distinguish model, endpoint, prompt contract, and important
options. Without a model-aware identity, switching from one model to another
could incorrectly reuse cached diagnostics produced under different behavior.

## What Changes

- Add a backend identity helper for cache keys and request metadata.
- Make backend identity stable and model-aware, covering backend name, model
  name, endpoint, prompt version, and relevant backend options.
- Add configuration surface for future real backends to expose model name,
  endpoint, and options without implementing transport yet.
- Preserve the current mock backend behavior and cache compatibility.
- Keep stale result validation and text matching as mandatory checks before any
  cached or backend diagnostic is displayed.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Backend identity and diagnostic cache behavior become
  model-aware so changing model, endpoint, prompt version, or relevant options
  invalidates previous cache entries.

## Impact

- Affects `lisp/proofread.el` backend identity, request construction, and
  diagnostic cache key helpers.
- Adds ERT coverage in `test/proofread-tests.el` for model-aware identity, cache
  invalidation, and mock backend compatibility.
- Adds no network, subprocess, HTTP, CLI, authentication, or real model
  integration.
