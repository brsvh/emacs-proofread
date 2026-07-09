## Context

Proofread currently builds visible text into paragraph spans, refines Chinese
paragraphs into sentence-level chunks when `jieba-rs-forward-sentence` is
available, filters ignored text before backend dispatch, and sends each
request-ready chunk with `:context-before` and `:context-after`. The
authoritative `:text` field already remains the exact buffer substring for the
chunk range, and diagnostic ranges are validated relative to that text.

The remaining mismatch is context construction. Request-ready context is still a
bounded character window around the chunk, so ordinary Chinese context can start
or end in the middle of a sentence even though the chunk itself is
sentence-level. The new behavior should make context more natural for LLMs
without introducing normalized text, source maps, display-line offsets, or
changes to backend/parser/overlay contracts.

## Goals / Non-Goals

**Goals:**

- Build request-ready `:context-before` and `:context-after` from configurable
  logical sentence windows.
- Default to one logical sentence before and one logical sentence after each
  request-ready chunk.
- Keep `proofread-context-size` as the maximum character budget per side and as
  the bounded fallback limit.
- Preserve exact request `:text`, `:beg`, and `:end` semantics.
- Keep ignored URL, email, invisible, ignored-face, and ignored-property text
  out of context.
- Stop sentence-window context at blank lines and supported structural
  boundaries such as Org headings, metadata, lists, tables, and blocks.
- Ensure visual wrapping and window width do not affect context semantics.
- Make context strategy, configuration, or selected content participate in cache
  identity.
- Keep tests offline with stubbed sentence movement where fallback paths need
  deterministic coverage.

**Non-Goals:**

- No backend protocol, JSON diagnostic schema, token map shape, stale rejection,
  or overlay behavior changes.
- No offset source map, normalized authoritative text, or remapping across
  ignored ranges.
- No screen-line, visual-line, or window-column based sentence boundaries.
- No cross-heading or cross-paragraph discourse reconstruction.
- No real LLM provider, DeepSeek, Ollama, or network tests.

## Decisions

### Decision: Apply sentence-window context only at request-ready construction

The request-ready chunk is the boundary consumed by cache lookup and backend
dispatch, after ignored spans have been removed from the authoritative request
unit. The existing `proofread--request-ready-context-before` and
`proofread--request-ready-context-after` helpers should become the sentence
context entry points.

Alternative considered: change paragraph-level chunk context in
`proofread--make-chunk`. That metadata is intermediate and may not match the
retained request-ready spans after ignored text is removed.

### Decision: Select whole sentence spans inside a structural context region

For each side, first determine the nearest context search boundary. Blank lines
and recognized structural lines stop the search; the search also remains inside
the buffer limits. Within that bounded region, derive sentence spans using the
same proofread-owned sentence boundary wrapper used by chunking. Select the
nearest complete preceding or following spans according to
`proofread-context-sentences-before` and `proofread-context-sentences-after`.

Alternative considered: call a backward sentence movement function directly. The
current code only relies on forward sentence movement; collecting spans in a
bounded region keeps one defensive wrapper and avoids new movement assumptions.

### Decision: Treat a hard-wrap newline as prose, not a sentence boundary

Sentence context should not split a normal Chinese sentence at a single hard
wrap newline. If the underlying sentence movement reports such a newline as a
boundary, the context collector should merge adjacent spans when the boundary is
only a single newline and neither side is a structural stop. The newline itself
remains in the returned context text and in any authoritative chunk text.

Alternative considered: accept every newline boundary from the movement
function. That matches old sentence chunking tests but keeps producing unnatural
half-sentence context in hard-wrapped prose.

### Decision: Use `proofread-context-size` as budget and fallback

The sentence-count options choose the desired window size, but
`proofread-context-size` remains the maximum number of characters returned per
side. When the complete selected sentence window is too long, reduce the number
of included sentences until the result fits. If the nearest single sentence is
still longer than the budget, use the existing bounded character-window fallback
for that side.

Alternative considered: truncate the selected sentence window to the character
budget. That would reintroduce partial ordinary sentences in the common case.

### Decision: Filter ignored text after selecting context spans

Context selection should operate on buffer positions so sentence and structural
boundaries are found in the real buffer. Once a span is selected, reuse the
existing ignored-range filtering helpers to remove URL, email, invisible,
ignored-face, and ignored-property text from the returned context string.

Alternative considered: filter the region first and then find sentence
boundaries in the filtered string. That requires source maps for reliable
position handling and creates the offset drift this change is explicitly
avoiding.

### Decision: Cache identity must include context-affecting state

The prompt includes context, so cache entries cannot be keyed only by chunk text
and backend identity. Add a stable context identity, content hash, or both to
cache keys. The key should distinguish sentence-context strategy, before and
after counts, `proofread-context-size`, and selected context content while
continuing to exclude buffer objects, callback objects, provider objects,
tokens, and secrets.

Alternative considered: bump `proofread-cache-configuration-version` manually.
That is useful as an escape hatch but is too coarse and too easy to forget when
users change sentence context settings.

## Risks / Trade-offs

- Sentence movement can be unavailable or fail -> Catch errors and fall back to
  the existing bounded character context behavior for that side.
- Structural-boundary detection can be incomplete -> Start with conservative
  blank-line and Org line predicates, and avoid crossing only boundaries that
  are easy to identify deterministically.
- Filtering ignored text from a selected sentence can leave adjacent retained
  fragments -> This is acceptable for context because ignored text must not be
  sent, and authoritative `:text` remains unchanged.
- More context-sensitive cache keys reduce hit rate -> This is required because
  context is part of the model prompt.
- Existing tests assume `proofread-context-size` alone controls context ->
  Update tests to set sentence counts or assert the new sentence-window behavior
  explicitly.

## Migration Plan

1. Add the new defcustoms with default value `1` and `natnum` types.
2. Add internal helpers for structural context boundaries, sentence span
   collection, hard-wrap newline merging, budget selection, and bounded
   character fallback.
3. Switch request-ready context helpers to sentence-window context while
   preserving exact chunk `:text`.
4. Add context identity/content to cache keys without adding volatile values.
5. Add focused offline ERT coverage for context windows, configuration, hard
   wrap behavior, visual-line independence, structural stops, ignored filtering,
   fallback, cache misses, and diagnostic/overlay stability.
6. Validate with the repository's clean Emacs flake test commands.

Rollback strategy: set both sentence-count options to `0` to suppress context,
or temporarily route the request-ready helpers back to the bounded character
window fallback while keeping the public custom variables.

## Open Questions

- Whether Org structural stops should be implemented with simple line predicates
  first or delegate to Org APIs when `org-mode` is active.
- Whether sentence-window context should apply only when `proofread-language` is
  Chinese or also for any mode where the sentence boundary wrapper returns
  useful spans.
