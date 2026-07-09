## Why

Scrolling, window changes, and idle scheduling can revisit the same unchanged
visible text repeatedly. A diagnostic cache reduces duplicate backend requests
while preserving the same stale-result and text-matching safeguards used for
asynchronous backend results.

## What Changes

- Add helpers for cache keys and cache read/write.
- Include chunk text hash, language, `major-mode`, backend name, prompt version,
  and relevant configuration version data in cache keys.
- Store diagnostics in a chunk-relative shape where possible, avoiding volatile
  absolute buffer positions in cache values.
- Use cached diagnostics when unchanged visible text is seen again.
- Invalidate cache hits when backend name, prompt version, language,
  `major-mode`, chunk text, or relevant configuration version changes.
- Route cached diagnostics through the same current-buffer text validation used
  before creating overlays.
- Do not add persistent cache storage or cross-project cache sharing.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Add an in-memory diagnostic cache for unchanged
  request-ready chunks without bypassing stale-result validation.

## Impact

- Affects `lisp/proofread.el` cache state, request dispatch, successful result
  handling, and cached diagnostic application.
- Adds ERT coverage in `test/proofread-tests.el` for cache hits, cache misses,
  backend/prompt/config invalidation, and cached diagnostic validation before
  overlay creation.
- Depends on `add-idle-timer-scheduling` so repeated visible checks from
  scrolling and window activity can reuse cached diagnostics.
- Adds no persistent cache, disk format, project-wide cache, or shared cache
  service.
