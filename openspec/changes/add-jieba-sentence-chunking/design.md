## Context

Proofread currently builds request-ready work from visible ranges by finding
nonblank paragraph spans and splitting only when a paragraph exceeds
`proofread-max-chunk-size`. For Chinese prose, a paragraph shorter than that
limit can still contain many sentences and produce a large `Text:` payload for
the configured LLM backend.

The project already has `emacs-jieba-rs` available through the flake
environment, and that package exposes sentence movement commands such as
`jieba-rs-forward-sentence`. Those commands provide enough boundary behavior for
a first sentence-level chunking pass without changing the backend protocol or
diagnostic parser.

## Goals / Non-Goals

**Goals:**

- Split Chinese paragraph spans into smaller sentence-level chunk spans before
  request-ready filtering and backend dispatch.
- Preserve exact buffer ranges and chunk text for stale-result validation.
- Keep `proofread-max-chunk-size` as the hard upper bound for every chunk,
  including oversized single sentences.
- Keep existing request, cache, JSON diagnostic, stale rejection, and overlay
  behavior unchanged.
- Fall back to existing paragraph chunking if sentence boundary support is not
  available or does not produce useful spans.
- Keep tests offline and independent from real LLM providers.

**Non-Goals:**

- No cross-chunk diagnostic merging.
- No approximate or fuzzy diagnostic range recovery.
- No complex NLP sentence parser beyond the `emacs-jieba-rs` sentence boundary
  behavior.
- No English-specific sentence splitting in this change.
- No change to the LLM prompt contract or response schema.

## Decisions

- Use sentence spans inside paragraph spans.

  The outer paragraph logic remains responsible for skipping blank text and
  keeping chunks inside visible ranges. Sentence splitting refines each
  paragraph span into smaller authoritative ranges before request-ready
  filtering runs. This keeps the current architecture:

  ```text
  visible ranges
    -> paragraph spans
    -> sentence spans
    -> max-size bounded spans
    -> request-ready filtering
    -> backend dispatch/cache
  ```

  Splitting only oversized paragraphs was rejected because a paragraph can be
  below `proofread-max-chunk-size` while still being too long for small local
  models to proofread accurately.

- Use a small proofread-owned wrapper around `jieba-rs-forward-sentence`.

  The wrapper should call the sentence movement function only when it is
  available and should convert point movement into absolute buffer spans. If the
  function is unavailable, fails, does not move point, or produces no useful
  boundaries, proofread should use the existing paragraph span as the fallback
  input.

  Directly depending on native word segmentation output was rejected because
  proofread needs sentence boundaries, not word lists, and diagnostic ranges
  must remain exact buffer positions.

- Keep dependency behavior conservative.

  Package metadata and Nix environments should include `jieba-rs` so normal
  package/test runs have the sentence boundary provider. Runtime code should
  still avoid throwing from idle hooks when the provider is absent or broken.
  This supports development, partial installations, and future non-Chinese
  fallback behavior.

- Preserve the existing chunk plist contract.

  The sentence chunk should still be represented as the same plist shape used by
  paragraph chunks. No downstream code should need to know whether a chunk
  originated from a paragraph span or a sentence span.

- Treat context as metadata only.

  `proofread-context-size` still controls surrounding context. Context must not
  expand the authoritative `:beg`, `:end`, or `:text` range used for
  stale-result validation and chunk-relative diagnostics.

## Risks / Trade-offs

- Sentence boundary behavior is simple and Chinese-oriented -> Tests should
  document the supported punctuation and newline behavior, and paragraph
  fallback remains available.
- More chunks can increase request count -> Existing idle scheduling, cache, and
  backend availability checks still apply; future work can add throttling or
  request coalescing if needed.
- A sentence can still be too long -> Keep `proofread-max-chunk-size` hard
  splitting as the final bounding step.
- `jieba-rs` may be unavailable or fail to load in some environments -> Boundary
  lookup must be defensive and fall back to paragraph chunking without changing
  buffer state.
- Smaller chunks change cache keys because chunk text changes -> This is
  expected and prevents old paragraph-level cache entries from being reused for
  sentence-level requests.
