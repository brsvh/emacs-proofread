## 1. Token Metadata

- [ ] 1.1 Add internal helpers that detect whether Chinese tokenization is
  available without signalling from idle or visible-check paths.
- [ ] 1.2 Add a tokenization helper that converts `jieba-rs` segmentation output
  into chunk-relative token plists with index, `beg`, `end`, and `text`.
- [ ] 1.3 Add exact substring validation for every generated token and drop
  token metadata when mapping cannot be validated.
- [ ] 1.4 Preserve fallback behavior when `jieba-rs` is unavailable, errors, or
  returns unusable token output.

## 2. Chunk and Request Integration

- [ ] 2.1 Attach token metadata only after request-ready filtering has removed
  ignored URL, email, invisible, ignored-face, and ignored-property text.
- [ ] 2.2 Ensure backend requests can carry token metadata without changing the
  authoritative `:beg`, `:end`, and `:text` chunk fields.
- [ ] 2.3 Prefer token-boundary splitting for oversized sentences when token
  boundaries can satisfy `proofread-max-chunk-size`.
- [ ] 2.4 Preserve existing bounded character splitting when tokenization is
  unavailable or a single token exceeds `proofread-max-chunk-size`.

## 3. Prompt and Cache

- [ ] 3.1 Extend the provider-agnostic `llm` JSON prompt to include token
  indexes, ranges, and texts when token metadata is present.
- [ ] 3.2 Update the prompt contract text to describe optional `token_index` or
  `token_range` fields while keeping `range` and original `text` required.
- [ ] 3.3 Add a stable tokenization identity helper covering token prompt
  enablement, tokenizer mode, HMM setting, prompt version, and deterministic
  user dictionary identity where available.
- [ ] 3.4 Include tokenization identity in cache keys when token metadata can
  affect prompts or accepted diagnostics.
- [ ] 3.5 Verify cache keys still exclude provider objects, callback objects,
  buffer objects, API keys, and other secrets.

## 4. Diagnostic Validation

- [ ] 4.1 Extend candidate JSON parsing to preserve optional token locator
  fields without requiring them.
- [ ] 4.2 Validate token locators against request token metadata when locators
  are present and interpretable.
- [ ] 4.3 Accept valid `range` and exact `text` diagnostics when token locators
  are absent.
- [ ] 4.4 Ignore malformed token locators without using them as a position
  source.
- [ ] 4.5 Reject candidates whose token locator explicitly contradicts the
  required `range` and `text`.
- [ ] 4.6 Reject token-only candidates that lack a valid chunk-relative `range`
  and exact original `text`.
- [ ] 4.7 Ensure invalid token-aware candidates do not discard other valid
  candidates in the same response.

## 5. Tests

- [ ] 5.1 Add offline ERT coverage for token map generation with exact
  chunk-relative offsets.
- [ ] 5.2 Add coverage that tokenization runs after request-ready filtering and
  does not include ignored text.
- [ ] 5.3 Add fallback coverage for unavailable, failing, and invalid `jieba-rs`
  tokenization.
- [ ] 5.4 Add coverage for token-boundary oversized sentence splitting and
  oversized-token fallback splitting.
- [ ] 5.5 Add `llm` prompt tests showing original text and token lists are
  included when tokens are present.
- [ ] 5.6 Add JSON validation tests for valid token locators, missing locators,
  malformed locators, contradictory locators, and token-only candidates.
- [ ] 5.7 Add cache identity tests proving tokenization identity changes cause
  cache misses and volatile objects or secrets are excluded.
- [ ] 5.8 Add stale rejection coverage for token-aware successful results.

## 6. Validation

- [ ] 6.1 Run the Emacs 30 proofread test package through the project flake.
- [ ] 6.2 Run the Emacs 31 proofread test package through the project flake.
- [ ] 6.3 Run byte compilation or the existing batch validation target used by
  this repository.
- [ ] 6.4 Review the diff to confirm no per-token backend dispatch, no buffer
  mutation, no provider-specific network tests, and no new user-facing UI were
  introduced.
