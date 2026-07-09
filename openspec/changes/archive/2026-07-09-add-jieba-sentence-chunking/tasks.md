## 1. Dependency and Configuration

- [x] 1.1 Add `jieba-rs` to proofread package dependency metadata when it is not
  already declared.
- [x] 1.2 Ensure Nix Emacs package and test environments include `jieba-rs`.
- [x] 1.3 Load or soft-load the `jieba-rs` Emacs Lisp package so sentence
  boundary functions can be used without forcing native word segmentation work
  during proofread startup.
- [x] 1.4 Add an internal availability/helper boundary so proofread can detect
  whether sentence boundary support is usable.

## 2. Sentence Span Construction

- [x] 2.1 Add a proofread-owned helper that converts `jieba-rs-forward-sentence`
  movement into absolute sentence spans inside a supplied paragraph span.
- [x] 2.2 Ensure the helper treats no movement, errors, unavailable functions,
  empty spans, and out-of-range movement as unusable boundary output.
- [x] 2.3 Ensure unavailable or unusable sentence boundary output falls back to
  the original paragraph span.
- [x] 2.4 Ensure sentence spans are sorted, non-empty, bounded by the original
  paragraph span, and do not overlap.
- [x] 2.5 Ensure sentence span construction does not modify buffer text, point
  position, mark state, text properties, overlays, timers, cache, or requests.

## 3. Chunking Pipeline Integration

- [x] 3.1 Insert sentence span construction between paragraph span discovery and
  max-size bounding.
- [x] 3.2 Keep `proofread-max-chunk-size` as the final hard limit for every
  sentence span.
- [x] 3.3 Preserve the existing chunk plist fields and metadata for chunks
  produced from sentence spans.
- [x] 3.4 Keep `proofread-context-size` behavior unchanged and separate from
  authoritative chunk `:beg`, `:end`, and `:text`.
- [x] 3.5 Keep request-ready filtering after sentence splitting, before cache
  lookup and backend request construction.
- [x] 3.6 Ensure cache keys naturally use the smaller sentence chunk text and do
  not reuse old paragraph-level entries for different chunk text.
- [x] 3.7 Keep backend dispatch, stale-result rejection, JSON parser, diagnostic
  cache value shape, and overlay application behavior unchanged.

## 4. Tests

- [x] 4.1 Add ERT coverage that a Chinese paragraph with multiple sentence
  punctuation marks produces multiple sentence-level chunks.
- [x] 4.2 Add ERT coverage that newline sentence boundaries can split visible
  text into separate chunks.
- [x] 4.3 Add ERT coverage that every sentence chunk's `:text` exactly matches
  the recorded buffer range.
- [x] 4.4 Add ERT coverage that sentence chunks preserve `major-mode`, proofread
  language, context, and modified tick metadata.
- [x] 4.5 Add ERT coverage that a single oversized sentence is split into
  contiguous chunks bounded by `proofread-max-chunk-size`.
- [x] 4.6 Add ERT coverage that unavailable or failing `jieba-rs` sentence
  boundary support falls back to paragraph chunking without signaling.
- [x] 4.7 Add ERT coverage that request-ready filtering still excludes ignored
  URL, email, invisible, ignored-face, and ignored-property text after sentence
  splitting.
- [x] 4.8 Add ERT coverage that visible check dispatch sends the smaller
  sentence-level request chunks to the backend.
- [x] 4.9 Add ERT coverage that chunking itself does not create diagnostics,
  overlays, timers, cache entries, or backend requests.

## 5. Validation

- [x] 5.1 Run `openspec status --change "add-jieba-sentence-chunking"` and
  ensure artifacts are complete.
- [x] 5.2 Run
  `openspec instructions apply --change "add-jieba-sentence-chunking" --json`
  and ensure implementation instructions are available.
- [x] 5.3 Run `nix run .#emacs31-run-proofread-tests`.
- [x] 5.4 Run `nix run .#emacs31-byte-compile-proofread`.
- [x] 5.5 Run `nix run .#emacs30-run-proofread-tests`.
- [x] 5.6 Run `nix run .#emacs30-byte-compile-proofread`.
- [x] 5.7 Run
  `nix fmt -- --fail-on-change lisp/proofread.el test/proofread-tests.el flake.nix tool/flake-module.nix`
  or the narrowed equivalent for files changed during implementation.
- [x] 5.8 Run
  `git diff --check -- lisp/proofread.el test/proofread-tests.el flake.nix tool/flake-module.nix openspec/changes/add-jieba-sentence-chunking`.
