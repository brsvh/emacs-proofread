## ADDED Requirements

### Requirement: Token map construction for request-ready chunks

The system SHALL build optional word-level token maps for Chinese request-ready
chunks after ignored text filtering and before cache lookup or backend dispatch.

#### Scenario: Chinese request-ready chunk receives token metadata

- **WHEN** proofread builds a request-ready Chinese chunk and tokenization is
  available
- **THEN** the chunk or backend request contains token metadata
- **AND** each token records a stable chunk-local index
- **AND** each token records chunk-relative `beg` and `end` offsets
- **AND** each token records the token text

#### Scenario: Token text matches request chunk text

- **WHEN** proofread constructs a token for a request-ready chunk
- **THEN** the token text exactly equals the request chunk substring between the
  token's `beg` and `end` offsets
- **AND** the token offsets are relative to the request chunk text

#### Scenario: Token category is not required

- **WHEN** proofread constructs token metadata from segmentation output without
  category data
- **THEN** the token remains valid when its index, offsets, and text are valid
- **AND** diagnostic validation does not require a token category

#### Scenario: Tokenization runs after request filtering

- **WHEN** a sentence chunk contains ignored URL, email, invisible,
  ignored-face, or ignored-property text
- **AND** request-ready filtering removes that ignored text before backend
  construction
- **THEN** token metadata is built only for the retained request-ready chunk
  text
- **AND** no token spans ignored text that is not sent to the backend

#### Scenario: Tokenization failure falls back safely

- **WHEN** `jieba-rs` tokenization is unavailable, signals an error, or produces
  token output that cannot be mapped exactly to the request chunk
- **THEN** proofread continues without token metadata
- **AND** proofread does not signal an error from idle or visible-check paths
- **AND** existing sentence-level request construction remains available

### Requirement: Token-boundary bounding for oversized sentences

The system SHALL prefer token boundaries when splitting an oversized
sentence-level chunk into bounded request-ready chunks.

#### Scenario: Oversized sentence splits at token boundaries

- **WHEN** sentence chunking produces a sentence longer than
  `proofread-max-chunk-size`
- **AND** tokenization can map token boundaries for that sentence
- **THEN** proofread splits the sentence into chunks whose lengths are less than
  or equal to `proofread-max-chunk-size`
- **AND** split points occur at token boundaries when doing so can satisfy the
  size limit

#### Scenario: Oversized token falls back to existing bounded split

- **WHEN** one token is longer than `proofread-max-chunk-size`
- **THEN** proofread falls back to the existing bounded split behavior for that
  token text
- **AND** every produced chunk still exactly matches its recorded buffer range

### Requirement: Token-aware JSON prompt contract

The system SHALL include token metadata in the `llm` JSON diagnostic prompt when
token metadata is available for a backend request.

#### Scenario: Prompt includes original text and token list

- **WHEN** proofread builds an `llm` prompt for a request that contains token
  metadata
- **THEN** the prompt still includes the original request text
- **AND** the prompt includes a token list with token indexes, ranges, and texts
- **AND** the prompt requires diagnostics to continue using chunk-relative
  ranges and exact original text

#### Scenario: Prompt describes optional token locators

- **WHEN** proofread builds an `llm` prompt for a request that contains token
  metadata
- **THEN** the prompt describes optional diagnostic token locator fields such as
  `token_index` or `token_range`
- **AND** the prompt states that token locators are auxiliary to the required
  `range` and original `text` fields

#### Scenario: Prompt falls back without tokens

- **WHEN** proofread builds an `llm` prompt for a request that does not contain
  token metadata
- **THEN** the prompt remains a valid provider-agnostic JSON diagnostic prompt
- **AND** the prompt does not require token locator fields in model responses

### Requirement: Token-aware diagnostic validation

The system SHALL treat model-provided token locators as optional consistency
checks while keeping chunk-relative range and exact original text validation
authoritative.

#### Scenario: Valid token locator confirms diagnostic range

- **WHEN** a candidate diagnostic has a valid chunk-relative range
- **AND** the candidate original text exactly matches the request substring at
  that range
- **AND** the candidate contains a token locator that maps to the same range and
  text
- **THEN** proofread converts the candidate to a proofread diagnostic with
  absolute positions

#### Scenario: Missing token locator does not block valid diagnostic

- **WHEN** a candidate diagnostic has a valid chunk-relative range
- **AND** the candidate original text exactly matches the request substring at
  that range
- **AND** the candidate does not contain token locator fields
- **THEN** proofread converts the candidate to a proofread diagnostic with
  absolute positions

#### Scenario: Malformed token locator does not replace range validation

- **WHEN** a candidate diagnostic has a valid chunk-relative range
- **AND** the candidate original text exactly matches the request substring at
  that range
- **AND** the candidate contains a token locator that cannot be interpreted
- **THEN** proofread ignores the token locator
- **AND** proofread does not use that token locator as a position source

#### Scenario: Contradictory token locator rejects diagnostic

- **WHEN** a candidate diagnostic has a token locator that maps to a different
  request text range than the candidate's required `range`
- **THEN** proofread does not create a proofread diagnostic for that candidate
- **AND** other valid candidates in the same response can still be converted

#### Scenario: Token-only diagnostic is rejected

- **WHEN** a candidate diagnostic contains token locator fields but does not
  contain a valid chunk-relative `range` and exact original `text`
- **THEN** proofread does not create a proofread diagnostic for that candidate

### Requirement: Tokenization-aware cache identity

The system SHALL include stable tokenization identity in cache keys whenever
token metadata can affect backend prompts or accepted diagnostics.

#### Scenario: Tokenization identity change invalidates cache

- **WHEN** token-aware prompting is enabled for otherwise identical request text
  and metadata
- **AND** the tokenizer mode, HMM setting, token prompt enablement, prompt
  version, or deterministic user dictionary identity changes
- **THEN** proofread builds a different cache key
- **AND** the old cache entry is not used for the new tokenization identity

#### Scenario: Cache key excludes volatile objects and secrets

- **WHEN** proofread builds a cache key for a token-aware request
- **THEN** the cache key does not contain provider objects
- **AND** the cache key does not contain callback objects
- **AND** the cache key does not contain buffer objects
- **AND** the cache key does not contain API keys or other secrets

#### Scenario: Token fallback keeps existing cache behavior

- **WHEN** tokenization is unavailable and proofread builds a request without
  token metadata
- **THEN** cache lookup and write behavior remain based on the existing
  request-ready chunk identity
- **AND** stale-result validation still runs before cached or fresh diagnostics
  create overlays
