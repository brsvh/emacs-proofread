## Context

`add-visible-region-discovery` establishes normalized visible ranges in
`proofread--pending-ranges`. The next step is to turn those ranges into bounded
request units while preserving enough metadata for asynchronous result
validation. The current package already has `proofread-max-chunk-size`,
`proofread-context-size`, `proofread-language`, and `buffer-chars-modified-tick`
is available from Emacs.

This change should remain an internal preparation step. It creates chunks but
does not dispatch backend requests, schedule timers, cache results, or map
backend diagnostics back into overlays.

## Goals / Non-Goals

**Goals:**

- Split visible ranges into paragraph-level chunks.
- Skip empty and whitespace-only text.
- Bound every chunk by `proofread-max-chunk-size`.
- Preserve exact absolute buffer boundaries and chunk text content.
- Include metadata needed by later asynchronous stale-result checks:
  `major-mode`, configured language, context, and `buffer-chars-modified-tick`.
- Avoid modifying buffer text or text properties.

**Non-Goals:**

- No sentence-level chunking.
- No language-specific tokenization or Chinese word segmentation.
- No complex position mapping inside backend results.
- No backend request creation, request queueing, timers, cache writes, or
  diagnostic overlays.
- No whole-buffer chunking outside the supplied visible ranges.

## Decisions

- Represent chunks as plists.

  Each chunk should be a plist with `:beg`, `:end`, `:text`, `:major-mode`,
  `:language`, `:context-before`, `:context-after`, and `:modified-tick`. Plists
  match the existing diagnostic representation style and keep metadata easy for
  later request scheduling code to extend. The alternative of a struct would add
  more machinery before the data shape has settled.

- Use simple paragraph spans inside each visible range.

  Chunking should treat paragraphs as nonblank runs separated by one or more
  blank lines. This avoids language-specific parsing and is stable in tests. The
  alternative of relying on major-mode paragraph motion could make chunk
  boundaries vary by mode before this package has a richer parsing policy.

- Split oversized paragraph spans by absolute buffer position.

  If a paragraph span is longer than `proofread-max-chunk-size`, split it into
  contiguous subspans no larger than the limit. This is deterministic and keeps
  chunk text equal to the buffer text between each recorded boundary. The
  alternative of splitting on words or sentences is better for readability, but
  it introduces parsing policy that is explicitly out of scope.

- Collect context separately from chunk text.

  Context should be gathered from up to `proofread-context-size` characters
  before and after the chunk, clipped to buffer boundaries. It is metadata and
  must not alter `:beg`, `:end`, or `:text`. Later request code can decide how
  to send context to a backend.

- Use no-properties string extraction.

  Chunk and context strings should use character content from the buffer without
  copying text properties. The chunking operation must not mutate buffer text or
  properties, and tests should verify the character content is exactly equal to
  the recorded buffer span.

## Risks / Trade-offs

- Paragraph definition is intentionally simple -> Tests document the blank-line
  separator behavior; richer mode-aware paragraph handling can be introduced in
  a later change.
- Splitting an oversized paragraph by character count may split words -> This
  honors the configured size limit and keeps the change deterministic; smarter
  splitting is a later concern.
- Context may include invisible or whitespace text near visible ranges ->
  Context size is bounded by `proofread-context-size`, and this change does not
  use context to expand the chunk's authoritative boundaries.
- Buffer edits after chunk construction can stale results -> Each chunk records
  `buffer-chars-modified-tick` so later result handling can reject stale
  diagnostics.
