## Why

Chinese sentence chunks already give proofread a stable request unit, but the
surrounding `context-before` and `context-after` fields are still character
windows. That can send half-sentence context to the LLM, making prompts less
natural while adding noise that does not help chunk-relative diagnostics.

## What Changes

- Add configurable sentence-window context counts:
  `proofread-context-sentences-before` and `proofread-context-sentences-after`,
  both defaulting to `1`.
- Generate request-ready `:context-before` and `:context-after` from complete
  logical sentence windows by default.
- Keep `proofread-context-size` as the maximum per-side context character budget
  and as the bounded fallback limit.
- Use existing sentence boundary support defensively, with the old character
  window behavior as fallback when sentence boundaries are unavailable or fail.
- Keep hard-wrapped prose newlines in `:text` and context, but do not treat a
  single hard-wrap newline as a sentence boundary for ordinary prose.
- Stop context search at blank lines and supported structural boundaries such as
  Org headings, metadata, lists, tables, and blocks.
- Continue excluding ignored URL, email, invisible, ignored-face, and
  ignored-property text from context.
- Include context strategy, configuration, or content in cache identity so
  context changes miss old diagnostics.
- Do not change backend protocol, JSON diagnostic parsing, token maps,
  diagnostic range semantics, stale rejection, or overlay behavior.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Request-ready chunks should build surrounding context
  from configurable logical sentence windows while preserving exact chunk text,
  filtering ignored context text, and invalidating cache entries when context
  behavior changes.

## Impact

- Affects request-ready context helpers, sentence boundary wrappers, cache key
  construction, and Org/context boundary helpers in `lisp/proofread.el`.
- Adds ERT coverage in `test/proofread-tests.el` for default one-sentence
  context, configured counts, disabled context, hard wrap behavior, visual-line
  independence, structural boundaries, ignored filtering, oversized
  single-sentence fallback, character-window fallback, cache misses, and
  unchanged overlay/range behavior.
- No backend API, provider object, JSON schema, token map shape, or overlay
  contract changes.
