## ADDED Requirements

### Requirement: Model-aware backend identity

The system SHALL compute a stable backend identity for request metadata and
diagnostic cache keys.

#### Scenario: Mock backend keeps compatible identity

- **WHEN** proofread computes backend identity for the built-in mock backend
- **THEN** the identity remains compatible with existing mock cache behavior

#### Scenario: Model backend identity includes model configuration

- **WHEN** proofread computes backend identity for a configurable model backend
- **THEN** the identity includes the backend name
- **AND** the identity includes the configured model name
- **AND** the identity includes the configured endpoint
- **AND** the identity includes the prompt version
- **AND** the identity includes cache-relevant backend options

#### Scenario: Backend identity excludes volatile request state

- **WHEN** proofread computes backend identity for any backend
- **THEN** the identity does not include request id
- **AND** the identity does not include live buffer objects
- **AND** the identity does not include callback functions
- **AND** the identity does not include absolute buffer positions

### Requirement: Model-aware diagnostic cache invalidation

The system SHALL invalidate diagnostic cache entries when model-relevant backend
configuration changes.

#### Scenario: Changing model name misses old cache entry

- **WHEN** a diagnostic cache entry was written with one model name
- **AND** the user changes the configured model name
- **THEN** proofread does not reuse the old cache entry for the same chunk text

#### Scenario: Changing endpoint misses old cache entry

- **WHEN** a diagnostic cache entry was written with one backend endpoint
- **AND** the user changes the configured backend endpoint
- **THEN** proofread does not reuse the old cache entry for the same chunk text

#### Scenario: Changing prompt version misses old cache entry

- **WHEN** a diagnostic cache entry was written with one prompt version
- **AND** the user changes `proofread-prompt-version`
- **THEN** proofread does not reuse the old cache entry for the same chunk text

#### Scenario: Changing cache-relevant options misses old cache entry

- **WHEN** a diagnostic cache entry was written with one set of cache-relevant
  backend options
- **AND** the user changes those cache-relevant backend options
- **THEN** proofread does not reuse the old cache entry for the same chunk text

#### Scenario: Unchanged identity can reuse cache

- **WHEN** visible chunk text is unchanged
- **AND** backend identity is unchanged
- **AND** current buffer text still matches the cached request text
- **THEN** proofread may reuse cached diagnostics without dispatching another
  backend request

#### Scenario: Cache hit still requires stale validation

- **WHEN** proofread reads diagnostics from cache
- **THEN** proofread validates the current buffer text and request freshness
  before creating proofread-owned overlays
