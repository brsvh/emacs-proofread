## Why

Visible range discovery gives the proofreading flow a user-relevant input set,
but backend work still needs bounded request units with enough metadata to
validate asynchronous results. Paragraph-level chunking provides that request
unit without introducing sentence parsing, language-specific tokenization, or
complex position mapping.

## What Changes

- Add internal paragraph-level chunk construction for normalized visible ranges.
- Represent each chunk with absolute buffer boundaries, exact buffer text,
  `major-mode`, configured language, surrounding context, and
  `buffer-chars-modified-tick`.
- Skip empty chunks and chunks whose text is only whitespace.
- Split paragraphs larger than `proofread-max-chunk-size` into stable bounded
  chunks.
- Preserve buffer text and text properties while chunking.
- Do not add backend dispatch, sentence-level chunking, Chinese word
  segmentation, or complex result position mapping.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Add paragraph chunk construction from visible ranges so
  later request scheduling can send bounded chunks with stale-result metadata.

## Impact

- Affects `lisp/proofread.el` internal range-to-chunk helpers.
- Adds ERT coverage in `test/proofread-tests.el` for ordinary paragraphs,
  whitespace-only paragraphs, oversized paragraphs, exact chunk text, and chunk
  metadata.
- Depends on `add-visible-region-discovery` for normalized visible range input.
- Adds no runtime dependency, backend request behavior, timers, cache behavior,
  or text modification.
