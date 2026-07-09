## Why

Chinese proofreading benefits from sentence context, but model-produced ranges
can still be imprecise inside a sentence. `emacs-jieba-rs` can provide a
word-level token map for each request-ready chunk, giving the model and parser a
more precise localization aid without splitting proofreading into contextless
per-word requests.

## What Changes

- Add optional token metadata to Chinese request-ready chunks after ignored text
  filtering.
- Build token maps from `emacs-jieba-rs` segmentation output using
  chunk-relative offsets and exact substring validation.
- Include token lists in the LLM JSON prompt when token metadata is available.
- Extend the JSON diagnostic contract with optional token locator fields while
  keeping `range` and original `text` as required authoritative fields.
- Validate token locators as consistency checks; never use token indexes as the
  only trusted source of position.
- Prefer token-boundary splits when an oversized sentence still exceeds
  `proofread-max-chunk-size`.
- Keep current sentence chunking, stale rejection, cache, parser, and overlay
  behavior when `jieba-rs` tokenization is unavailable.

## Capabilities

### New Capabilities

### Modified Capabilities

- `proofread-package`: Add token-aware request metadata and JSON diagnostic
  validation behavior for Chinese LLM proofreading chunks.

## Impact

- Affects `lisp/proofread.el` chunk construction, request metadata, LLM prompt
  construction, JSON diagnostic parsing/validation, cache key identity, and
  oversized sentence splitting.
- Affects `test/proofread-tests.el` with offline coverage for token maps,
  token-aware prompts, token validation, cache invalidation, fallback behavior,
  and stale-result safety.
- Adds no user-facing UI, no per-token backend dispatch, no buffer mutation, and
  no real-network tests.
