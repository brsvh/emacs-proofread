## Context

Proofread already builds request-ready chunks from visible text, refines Chinese
paragraphs into sentence-level chunks with `emacs-jieba-rs` sentence movement,
filters ignored text before backend dispatch, and validates model diagnostics
with chunk-relative ranges plus exact original text matching. This gives a safe
authoritative range boundary, but small or remote LLM providers can still return
imprecise offsets within a sentence.

`emacs-jieba-rs` also exposes word segmentation and part-of-speech tagging. Its
segmentation APIs return ordered words or tag plists, not explicit positions.
Positions can be reconstructed by walking the request-ready chunk text and
accumulating each returned word's character length. That makes token metadata
useful as an editor-side localization aid, provided proofread continues to treat
the request chunk text and validated range as authoritative.

## Goals / Non-Goals

**Goals:**

- Add word-level token metadata for Chinese request-ready chunks.
- Keep sentence text as the proofreading unit so LLM providers still receive
  local context.
- Include token maps in LLM prompts when available to improve diagnostic
  localization.
- Accept optional token locators in JSON diagnostics as consistency hints.
- Preserve range/text exact matching, stale rejection, cache, and overlay
  safety.
- Prefer token-boundary splits when bounding oversized single sentences.
- Keep tests offline with stubbed segmentation and `llm` callbacks.

**Non-Goals:**

- No per-token LLM dispatch.
- No dictionary-based spellchecker, low-frequency word detector, or local typo
  classifier.
- No fuzzy range recovery when model text does not match the request chunk.
- No cross-chunk diagnostic merge.
- No user-facing UI for tokens.
- No real network or provider-specific integration tests.

## Decisions

### Decision: Tokenize request-ready chunks, not raw sentence chunks

Tokenization runs after ignored URL, email, invisible, ignored-face, and
ignored-property text is removed. The token map must describe exactly the text
that will be sent to the backend, so token offsets remain chunk-relative and can
be checked against the request text without knowing about removed spans.

Alternative considered: tokenize before request-ready filtering and then remap
tokens. That adds offset translation across ignored spans and creates more
opportunities for stale or incorrect token positions.

### Decision: Keep sentence-level requests as the LLM unit

The backend continues to receive one request per request-ready sentence or
bounded sentence fragment. Token maps are metadata inside that request, not a
new dispatch granularity.

Alternative considered: send each token as a separate request. That would
increase request count, remove the sentence context required by many Chinese
typo decisions, and likely reduce diagnostic quality for ambiguous words.

### Decision: Reconstruct token positions defensively

`jieba-rs` segmentation output is converted to token plists with chunk-relative
`:index`, `:beg`, `:end`, and `:text`, plus optional `:category` when tag output
is available. Each token is kept only when its recorded `:text` exactly matches
the request chunk substring at `:beg` and `:end`. If segmentation fails or does
not cover the request text coherently, proofread drops token metadata and
continues with the existing prompt.

Alternative considered: trust the segmenter output lengths without substring
checks. That is simpler but would let normalization or unexpected segmenter
behavior create invalid token positions.

### Decision: Token fields are optional diagnostic hints

The JSON contract may allow `token_index` or `token_range`, but candidates still
need a valid chunk-relative `range` and exact original `text`. Token fields can
confirm consistency, reject explicit contradictions, or be ignored when absent.
They must not be used as the only source of position.

Alternative considered: allow token-only diagnostics. That would simplify model
output for some providers, but it weakens the existing safety boundary and makes
diagnostics depend on a token map that may vary with dictionaries or segmenter
settings.

### Decision: Tokenization identity participates in cache invalidation

When tokens are included in the prompt or otherwise affect backend output, the
cache key must include a stable tokenization identity. At minimum that identity
should cover whether token prompting is enabled, the segmentation mode, HMM
setting, prompt version, and any user dictionary identity proofread can
deterministically compute without storing secrets or provider objects.

Alternative considered: rely only on prompt version. That is workable for manual
invalidation but too coarse when users change tokenizer settings during
development.

### Decision: Use token boundaries for oversized sentence bounding

When a sentence exceeds `proofread-max-chunk-size` and tokenization is
available, proofread should split at token boundaries that keep each bounded
chunk within the size limit. Existing character-based bounded splitting remains
the fallback when tokenization is unavailable or a single token is too large.

Alternative considered: keep the current character split always. That preserves
today's behavior but can cut through Chinese words and makes subsequent token
localization less stable.

## Risks / Trade-offs

- Token maps make prompts longer -> Include tokens only for request-ready
  Chinese chunks and keep sentence chunking as the main prompt-size control.
- `jieba-rs` output may vary with HMM, dictionaries, or package version -> Add
  tokenization identity to cache keys and keep range/text validation
  authoritative.
- Token consistency rules could discard useful diagnostics if too strict ->
  Treat absent or malformed token fields as optional unless they explicitly
  contradict a valid range/text pair.
- More metadata increases test surface -> Add focused offline tests around token
  generation, prompt inclusion, parser consistency, cache identity, and fallback
  behavior.
- Token-boundary splitting can still encounter an oversized token -> Fall back
  to the existing bounded split for that token.

## Migration Plan

1. Add internal tokenization helpers and tests using stubbed `jieba-rs`
   functions.
2. Attach token metadata to request-ready Chinese chunks without changing
   backend dispatch behavior.
3. Include token maps in the `llm` JSON prompt and add tokenization identity to
   cache keys.
4. Extend JSON diagnostic parsing and validation for optional token fields.
5. Prefer token-boundary bounding for oversized sentences.
6. Validate with offline ERT tests, byte compilation, and Emacs 30/31 flake test
   packages.

Rollback strategy: disable token metadata and prompt inclusion while keeping
sentence chunking and existing range/text diagnostic validation.

## Open Questions

- Whether the first implementation should prefer precise segmentation or POS
  tagging by default. POS tags provide useful categories, but precise
  segmentation is enough for localization.
- Whether user dictionary identity should be based on file truename plus mtime,
  content hash, or a user-managed tokenizer configuration version.
