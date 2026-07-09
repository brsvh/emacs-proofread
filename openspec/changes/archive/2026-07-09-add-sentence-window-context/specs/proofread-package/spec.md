## ADDED Requirements

### Requirement: Sentence-window request context

The system SHALL build request-ready `:context-before` and `:context-after` from
configurable logical sentence windows when sentence boundary support is
available.

#### Scenario: Default context uses one complete sentence before

- **WHEN** proofread builds a request-ready Chinese sentence chunk with a
  complete logical sentence immediately before it in the same context region
- **THEN** the chunk's `:context-before` is that complete preceding sentence
- **AND** the context does not begin in the middle of that ordinary sentence

#### Scenario: Default context uses one complete sentence after

- **WHEN** proofread builds a request-ready Chinese sentence chunk with a
  complete logical sentence immediately after it in the same context region
- **THEN** the chunk's `:context-after` is that complete following sentence
- **AND** the context does not end in the middle of that ordinary sentence

#### Scenario: Configured sentence counts change the context window

- **WHEN** `proofread-context-sentences-before` or
  `proofread-context-sentences-after` is set to a positive integer greater than
  `1`
- **THEN** proofread includes up to that many complete logical sentences in the
  corresponding context direction
- **AND** it preserves their original buffer order in the returned context
  string

#### Scenario: Zero sentence count disables a context direction

- **WHEN** `proofread-context-sentences-before` is `0`
- **THEN** request-ready chunks have empty `:context-before`
- **WHEN** `proofread-context-sentences-after` is `0`
- **THEN** request-ready chunks have empty `:context-after`

#### Scenario: Context size reduces sentence count before truncating

- **WHEN** the configured complete sentence window for a context side exceeds
  `proofread-context-size`
- **THEN** proofread reduces the number of included context sentences until the
  context fits the budget
- **AND** it does not truncate an ordinary included sentence when at least one
  complete sentence can fit

#### Scenario: Single oversized context sentence uses bounded fallback

- **WHEN** the nearest single logical context sentence exceeds
  `proofread-context-size`
- **THEN** proofread uses a bounded character-window fallback for that context
  side
- **AND** the fallback is limited by `proofread-context-size`
- **AND** the request chunk's `:text` remains the exact buffer substring between
  `:beg` and `:end`

### Requirement: Context sentence boundaries ignore visual wrapping

The system MUST derive sentence-window context from buffer text and logical
sentence boundaries, not from screen lines, visual lines, or window columns.

#### Scenario: Hard-wrapped prose keeps a single logical sentence

- **WHEN** ordinary Chinese prose contains a single hard-wrap newline inside a
  sentence and no sentence-ending punctuation at that newline
- **THEN** proofread does not treat that newline alone as a sentence boundary
- **AND** the newline is preserved in returned context when the containing
  sentence is selected
- **AND** authoritative chunk `:text` still preserves the real buffer newline

#### Scenario: Visual line mode does not change context

- **WHEN** proofread builds request-ready chunks for the same buffer range with
  `visual-line-mode` disabled and enabled
- **THEN** the chunk texts are the same
- **AND** each matching chunk has the same `:context-before`
- **AND** each matching chunk has the same `:context-after`

#### Scenario: Window width does not change context

- **WHEN** the same buffer text is displayed with different window widths or
  soft-wrap layouts
- **THEN** proofread produces the same sentence-window context for the same
  request-ready chunk ranges

### Requirement: Context search stops at unrelated structure

The system SHALL stop sentence-window context search at blank lines and
supported structural boundaries so unrelated document structure is not spliced
into request context.

#### Scenario: Blank line stops context search

- **WHEN** a blank line separates a request-ready chunk from text before or
  after it
- **THEN** proofread does not include sentences across that blank line in the
  corresponding context field

#### Scenario: Org heading stops context search

- **WHEN** an Org heading separates a request-ready chunk from surrounding text
- **THEN** proofread does not include sentences across that heading in
  `:context-before` or `:context-after`

#### Scenario: Org metadata stops context search

- **WHEN** an Org metadata line such as a keyword or property drawer separates a
  request-ready chunk from surrounding prose
- **THEN** proofread does not include context across that metadata boundary

#### Scenario: Org list table or block stops context search

- **WHEN** an Org list item, table row, block delimiter, or block content
  separates a request-ready chunk from surrounding prose
- **THEN** proofread does not include context across that structural boundary

### Requirement: Request context preserves request integrity and filtering

The system SHALL keep request `:text` and diagnostic ranges authoritative for
the request-ready chunk while applying existing ignored-text filtering to
context.

#### Scenario: Ignored text is excluded from context

- **WHEN** selected sentence-window context contains an ignored URL, email,
  invisible span, ignored face, or ignored property
- **THEN** the returned `:context-before` or `:context-after` excludes that
  ignored text
- **AND** request-ready chunk `:text` excludes ignored text only through the
  existing request-ready filtering stage

#### Scenario: Request text exactly matches buffer range

- **WHEN** proofread builds a request-ready chunk with sentence-window context
- **THEN** the chunk's `:text` exactly equals the buffer text between its
  recorded `:beg` and `:end`
- **AND** context text is not appended to or prepended to `:text`

#### Scenario: Diagnostics remain relative to request text

- **WHEN** a backend returns a diagnostic range for a request that includes
  sentence-window context fields
- **THEN** proofread interprets that range only relative to request `:text`
- **AND** a diagnostic range cannot point into `:context-before` or
  `:context-after`

#### Scenario: Overlay positions do not drift

- **WHEN** proofread accepts a diagnostic for a request-ready chunk whose
  context was generated from sentence windows
- **THEN** the created diagnostic and overlay positions map to the chunk's
  absolute `:beg` and `:end` range in the buffer
- **AND** context contents do not shift diagnostic positions

### Requirement: Context fallback and cache identity

The system SHALL fall back safely when sentence-window context cannot be
computed and SHALL distinguish context-affecting changes in diagnostic cache
keys.

#### Scenario: Sentence boundary unavailable falls back to character context

- **WHEN** sentence boundary support is unavailable, fails, does not move, or
  produces no useful context sentence spans
- **THEN** proofread uses the existing bounded character-window context behavior
  for that side
- **AND** proofread does not signal an error from chunk construction, visible
  checking, cache lookup, or backend dispatch

#### Scenario: Context strategy change misses old cache entries

- **WHEN** a cache entry was created with a different context strategy than the
  current request-ready chunk uses
- **THEN** proofread does not reuse that old cache entry for the current chunk

#### Scenario: Context configuration change misses old cache entries

- **WHEN** `proofread-context-sentences-before`,
  `proofread-context-sentences-after`, or `proofread-context-size` changes in a
  way that can affect request context
- **THEN** proofread does not reuse cache entries created under the old context
  configuration

#### Scenario: Context content change misses old cache entries

- **WHEN** two request-ready chunks have the same `:text` but different
  `:context-before` or `:context-after`
- **THEN** their diagnostic cache keys are different

#### Scenario: Context cache key excludes volatile and secret values

- **WHEN** proofread builds a cache key for a request-ready chunk with
  sentence-window context
- **THEN** the key does not include the buffer object
- **AND** the key does not include callback objects
- **AND** the key does not include provider objects
- **AND** the key does not include token lists
- **AND** the key does not include secrets
