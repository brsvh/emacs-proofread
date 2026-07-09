## ADDED Requirements

### Requirement: Sentence-aware chunk construction

The system SHALL split Chinese paragraph text into sentence-level proofreading
chunks before cache lookup or backend request dispatch when sentence boundary
support is available.

#### Scenario: Chinese paragraph splits into sentence chunks

- **WHEN** proofread chunking receives a visible range containing one Chinese
  paragraph with multiple sentences separated by Chinese sentence punctuation
- **THEN** it produces separate chunks for those sentences
- **AND** each chunk records absolute `:beg` and `:end` buffer positions
- **AND** each chunk `:text` exactly matches the buffer text between `:beg` and
  `:end`

#### Scenario: Newline can end a sentence span

- **WHEN** proofread chunking receives a paragraph or visible span where the
  configured sentence boundary behavior treats a newline as a sentence boundary
- **THEN** proofread may split the text at that newline
- **AND** produced chunks still use exact absolute buffer ranges

#### Scenario: Sentence chunks preserve metadata and context

- **WHEN** proofread chunking produces a sentence-level chunk
- **THEN** the chunk preserves the existing chunk plist shape
- **AND** the chunk records the buffer's `major-mode`
- **AND** the chunk records the configured proofread language
- **AND** the chunk records bounded surrounding context
- **AND** the chunk records the buffer's `buffer-chars-modified-tick`

#### Scenario: Oversized sentence remains bounded

- **WHEN** sentence splitting produces a single sentence longer than
  `proofread-max-chunk-size`
- **THEN** proofread splits that sentence into multiple bounded chunks
- **AND** every produced chunk has text length less than or equal to
  `proofread-max-chunk-size`
- **AND** the chunks use stable, contiguous absolute buffer ranges for the
  original sentence text

#### Scenario: Sentence boundary unavailable falls back to paragraph chunking

- **WHEN** proofread chunking runs where `jieba-rs` sentence boundary support is
  unavailable, fails, or produces no useful sentence spans
- **THEN** proofread falls back to existing paragraph-level chunking
- **AND** chunking does not signal an error from idle or visible-check paths
- **AND** the buffer text and text properties remain unchanged

#### Scenario: Request filtering still applies after sentence splitting

- **WHEN** request-ready chunks are built from sentence-level chunks containing
  ignored URL, email, invisible, ignored-face, or ignored-property text
- **THEN** the filtering stage excludes ignored text before cache lookup
- **AND** the filtering stage excludes ignored text before backend request
  construction
- **AND** retained request-ready chunk text still exactly matches its recorded
  absolute buffer range

#### Scenario: Visible check dispatches sentence chunks

- **WHEN** `proofread-check-visible` is invoked in a buffer with
  `proofread-mode` enabled, an available backend configured, and visible Chinese
  text containing multiple sentence chunks
- **THEN** proofread dispatches backend requests for the request-ready sentence
  chunks
- **AND** backend requests continue to use chunk-relative diagnostic ranges
  through the existing backend protocol

#### Scenario: Chunking does not mutate buffer contents

- **WHEN** proofread sentence-aware chunking is run for visible ranges in a
  buffer
- **THEN** the buffer text remains unchanged
- **AND** existing text properties in the buffer remain unchanged
- **AND** no diagnostic or overlay is created by chunk construction itself
