## 1. Chunk Data Helpers

- [ ] 1.1 Add internal chunk plist construction with `:beg`, `:end`, `:text`,
  `:major-mode`, `:language`, `:context-before`, `:context-after`, and
  `:modified-tick`.
- [ ] 1.2 Add bounded context collection using `proofread-context-size`, clipped
  to buffer boundaries and kept separate from chunk `:text`.
- [ ] 1.3 Ensure chunk text and context are copied without text properties and
  chunking does not mutate buffer text or properties.

## 2. Paragraph Range Splitting

- [ ] 2.1 Add an internal helper that turns visible `(BEG . END)` ranges into
  nonblank paragraph spans using blank-line paragraph separators.
- [ ] 2.2 Skip empty spans and spans whose character content is only whitespace.
- [ ] 2.3 Split paragraph spans longer than `proofread-max-chunk-size` into
  stable contiguous subspans no larger than the configured limit.
- [ ] 2.4 Ensure every chunk's `:text` exactly matches the buffer character
  content between its recorded `:beg` and `:end`.

## 3. Integration Boundary

- [ ] 3.1 Add an internal helper that builds chunks from normalized visible
  ranges, suitable for later request scheduling.
- [ ] 3.2 Keep paragraph chunking from creating backend requests, timers, cache
  entries, diagnostics, overlays, or whole-buffer work.
- [ ] 3.3 Preserve existing `proofread-check-visible` visible-range collection
  behavior unless applying chunking there is explicitly required by the design.

## 4. Tests

- [ ] 4.1 Add ERT coverage for an ordinary paragraph producing one chunk with
  exact boundaries and text.
- [ ] 4.2 Add ERT coverage that empty and whitespace-only paragraphs produce no
  chunks.
- [ ] 4.3 Add ERT coverage that oversized paragraphs split into bounded,
  contiguous chunks.
- [ ] 4.4 Add ERT coverage for chunk metadata, including `major-mode`, proofread
  language, context, and `buffer-chars-modified-tick`.
- [ ] 4.5 Add ERT coverage that chunking preserves buffer contents, text
  properties, and proofread side-effect state.

## 5. Validation

- [ ] 5.1 Run the project proofread ERT test package through the flake-provided
  Emacs test command.
- [ ] 5.2 Run OpenSpec status or validation for `add-paragraph-chunking` and
  confirm the change is apply-ready.
