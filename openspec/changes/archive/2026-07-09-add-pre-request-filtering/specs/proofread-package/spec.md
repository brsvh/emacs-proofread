## ADDED Requirements

### Requirement: Pre-request chunk filtering

The system SHALL exclude ignored text from proofreading chunks before cache
lookup or backend request construction.

#### Scenario: URL text is excluded by default

- **WHEN** request-ready chunks are built from a paragraph chunk containing an
  `http://` or `https://` URL
- **THEN** no request-ready chunk text contains that URL
- **AND** ordinary text outside the URL remains eligible for proofreading

#### Scenario: Email address text is excluded by default

- **WHEN** request-ready chunks are built from a paragraph chunk containing an
  email address
- **THEN** no request-ready chunk text contains that email address
- **AND** ordinary text outside the email address remains eligible for
  proofreading

#### Scenario: Ignored face text is excluded

- **WHEN** `proofread-ignored-faces` contains a face used by text inside a
  paragraph chunk
- **THEN** request-ready chunks exclude the text with that face
- **AND** filtering uses public text properties rather than another package's
  private state

#### Scenario: Ignored property text is excluded

- **WHEN** `proofread-ignored-properties` contains a text property with a
  non-nil value inside a paragraph chunk
- **THEN** request-ready chunks exclude the text carrying that property
- **AND** ordinary text outside that property span remains eligible for
  proofreading

#### Scenario: Invisible text is excluded by default

- **WHEN** request-ready chunks are built from a paragraph chunk containing text
  with a non-nil `invisible` property
- **THEN** no request-ready chunk text contains the invisible text
- **AND** ordinary visible text in the same paragraph remains eligible for
  proofreading

#### Scenario: Filtering happens before cache and backend input

- **WHEN** chunks are prepared for cache lookup or backend request construction
- **THEN** the filtering stage runs before cache lookup
- **AND** the filtering stage runs before backend request construction
- **AND** filtered spans are absent from the cache/backend input text

#### Scenario: Filtering preserves retained chunk metadata

- **WHEN** filtering splits a paragraph chunk around ignored text
- **THEN** each retained request-ready chunk records absolute `:beg` and `:end`
  buffer positions
- **AND** each retained chunk `:text` exactly matches the buffer text between
  `:beg` and `:end`
- **AND** each retained chunk preserves stale-result metadata needed for later
  validation
