## ADDED Requirements

### Requirement: Diagnostic cache keys

The system SHALL build deterministic cache keys for request-ready proofreading
chunks.

#### Scenario: Cache key includes text and environment identity

- **WHEN** proofread builds a cache key for a request-ready chunk
- **THEN** the key contains a hash of the chunk text
- **AND** the key contains the chunk language
- **AND** the key contains the chunk `major-mode`
- **AND** the key contains the selected backend identity
- **AND** the key contains the prompt version
- **AND** the key contains relevant configuration version data

#### Scenario: Backend identity change invalidates cache

- **WHEN** the selected backend identity changes for otherwise identical chunk
  text and metadata
- **THEN** proofread builds a different cache key
- **AND** the old cache entry is not used for the new backend identity

#### Scenario: Prompt version change invalidates cache

- **WHEN** the prompt version changes for otherwise identical chunk text and
  metadata
- **THEN** proofread builds a different cache key
- **AND** the old cache entry is not used for the new prompt version

#### Scenario: Configuration version change invalidates cache

- **WHEN** relevant proofreading configuration version data changes for
  otherwise identical chunk text and metadata
- **THEN** proofread builds a different cache key
- **AND** the old cache entry is not used for the new configuration version data

### Requirement: Diagnostic cache lookup and write

The system SHALL reuse cached diagnostics for unchanged visible text and avoid
duplicate backend requests on cache hits.

#### Scenario: Cache hit skips backend dispatch

- **WHEN** proofread checks a request-ready visible chunk whose cache key
  matches an existing cache entry
- **THEN** proofread reads diagnostics from the cache
- **AND** proofread does not dispatch a backend request for that chunk

#### Scenario: Cache miss dispatches backend request

- **WHEN** proofread checks a request-ready visible chunk whose cache key does
  not match an existing cache entry
- **THEN** proofread dispatches a backend request for that chunk through the
  backend protocol

#### Scenario: Fresh successful result writes cache

- **WHEN** a fresh successful backend result is accepted for a request-ready
  chunk
- **THEN** proofread writes diagnostics for that chunk to the cache
- **AND** the cache value stores diagnostics in chunk-relative form

#### Scenario: Stale or error result is not cached

- **WHEN** a backend result is stale or has error status
- **THEN** proofread does not write diagnostics from that result to the cache

### Requirement: Cached diagnostic application safety

The system SHALL validate cached diagnostics against the current buffer text
before creating overlays or mutating diagnostic state.

#### Scenario: Cached diagnostics validate current text

- **WHEN** proofread reads diagnostics from the cache for a request-ready chunk
- **THEN** proofread validates that the current buffer text for the chunk range
  still equals the chunk text associated with the cache hit
- **AND** proofread applies diagnostics only after that validation succeeds

#### Scenario: Cached diagnostics use current absolute positions

- **WHEN** proofread applies chunk-relative diagnostics from a cache hit
- **THEN** proofread converts those diagnostics to absolute positions for the
  current request range
- **AND** proofread creates overlays only at those current absolute positions

#### Scenario: Text mismatch rejects cached diagnostics

- **WHEN** proofread reads diagnostics from the cache
- **AND** the current buffer text at the request range does not equal the cached
  chunk text
- **THEN** proofread drops the cached diagnostics
- **AND** proofread does not create overlays from that cache entry
- **AND** proofread does not treat that cache entry as a fresh backend result
