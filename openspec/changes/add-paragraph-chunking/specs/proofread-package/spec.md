## ADDED Requirements

### Requirement: Paragraph chunk construction

The system SHALL construct bounded paragraph-level proofreading chunks from
visible buffer ranges.

#### Scenario: Ordinary paragraph creates a chunk

- **WHEN** proofread chunking receives a visible range containing one nonblank
  paragraph shorter than `proofread-max-chunk-size`
- **THEN** it produces one chunk for that paragraph
- **AND** the chunk records absolute `:beg` and `:end` buffer positions
- **AND** the chunk `:text` content exactly matches the buffer text between
  `:beg` and `:end`

#### Scenario: Whitespace-only paragraphs are skipped

- **WHEN** proofread chunking receives a visible range containing empty text or
  only whitespace paragraphs
- **THEN** it produces no chunks for that text

#### Scenario: Oversized paragraph is split into bounded chunks

- **WHEN** proofread chunking receives a paragraph longer than
  `proofread-max-chunk-size`
- **THEN** it splits that paragraph into multiple chunks
- **AND** every produced chunk has text length less than or equal to
  `proofread-max-chunk-size`
- **AND** the chunks use stable, contiguous absolute buffer ranges for the
  original paragraph text

#### Scenario: Chunk records asynchronous validation metadata

- **WHEN** proofread chunking produces a chunk
- **THEN** the chunk records the buffer's `major-mode`
- **AND** the chunk records the configured proofread language
- **AND** the chunk records bounded surrounding context
- **AND** the chunk records the buffer's `buffer-chars-modified-tick`

#### Scenario: Chunking does not mutate buffer contents

- **WHEN** proofread chunking is run for visible ranges in a buffer
- **THEN** the buffer text remains unchanged
- **AND** existing text properties in the buffer remain unchanged
- **AND** no backend request, timer, cache entry, diagnostic, or overlay is
  created by chunking
