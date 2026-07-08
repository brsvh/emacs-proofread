## 1. Cache Identity

- [ ] 1.1 Add prompt version and cache configuration version data used by cache
  key construction.
- [ ] 1.2 Add a helper that returns the selected backend identity for cache
  keys.
- [ ] 1.3 Add a helper that hashes request-ready chunk text for cache keys.
- [ ] 1.4 Add a cache key helper that includes text hash, language,
  `major-mode`, backend identity, prompt version, and configuration version
  data.
- [ ] 1.5 Add focused helper tests proving backend, prompt, configuration,
  language, mode, and text changes produce different keys.

## 2. Cache Storage Helpers

- [ ] 2.1 Add internal cache read and write helpers around the buffer-local
  cache table.
- [ ] 2.2 Ensure cache helpers initialize missing buffer-local cache state only
  for live `proofread-mode` buffers.
- [ ] 2.3 Ensure disabling `proofread-mode` clears in-memory cache state with
  the rest of proofread-owned buffer state.
- [ ] 2.4 Add tests for cache read/write hit and miss behavior.

## 3. Relative Diagnostics

- [ ] 3.1 Add a helper that converts accepted absolute diagnostics to
  chunk-relative diagnostics before cache write.
- [ ] 3.2 Add a helper that converts chunk-relative cached diagnostics back to
  absolute positions for a current request range.
- [ ] 3.3 Ensure cache values do not use absolute buffer positions as their
  canonical diagnostic ranges.
- [ ] 3.4 Add tests for exact relative-to-absolute diagnostic conversion.

## 4. Dispatch Integration

- [ ] 4.1 Check the diagnostic cache before dispatching a backend request for a
  request-ready chunk.
- [ ] 4.2 On cache hit, skip backend dispatch for that chunk.
- [ ] 4.3 On cache hit, route cached diagnostics through the same validation and
  application boundary used by backend success results.
- [ ] 4.4 On cache miss, preserve existing backend dispatch behavior.
- [ ] 4.5 Add tests proving unchanged visible text is not sent to the backend
  again after a cache entry exists.

## 5. Cache Write and Safety

- [ ] 5.1 Write diagnostics to the cache only after a fresh successful backend
  result has been accepted.
- [ ] 5.2 Ensure stale backend results are not written to cache.
- [ ] 5.3 Ensure backend error results are not written to cache.
- [ ] 5.4 Validate current buffer text before applying cached diagnostics.
- [ ] 5.5 Drop cached diagnostics without overlays or diagnostic-state changes
  when current buffer text mismatches the request range.

## 6. Invalidation Tests

- [ ] 6.1 Add ERT coverage that backend identity changes miss old cache entries.
- [ ] 6.2 Add ERT coverage that prompt version changes miss old cache entries.
- [ ] 6.3 Add ERT coverage that configuration version changes miss old cache
  entries.
- [ ] 6.4 Add ERT coverage that chunk text changes miss old cache entries.
- [ ] 6.5 Add ERT coverage that cached diagnostics still pass through text
  validation before overlay creation.

## 7. Validation

- [ ] 7.1 Run the project proofread ERT test package through the flake-provided
  Emacs test command.
- [ ] 7.2 Run OpenSpec status or validation for `add-diagnostic-cache` and
  confirm the change is apply-ready.
