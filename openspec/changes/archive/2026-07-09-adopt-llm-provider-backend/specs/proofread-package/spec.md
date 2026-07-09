## ADDED Requirements

### Requirement: LLM provider backend availability

The system SHALL provide a `llm` backend that is available only when a valid
`llm` provider has been configured for proofread.

#### Scenario: LLM backend unavailable without provider

- **WHEN** backend availability is queried for the `llm` backend
- **AND** `proofread-llm-provider` is nil
- **THEN** `proofread-backend-available-p` reports the `llm` backend as
  unavailable

#### Scenario: LLM backend available with provider

- **WHEN** backend availability is queried for the `llm` backend
- **AND** `proofread-llm-provider` contains a configured `llm` provider object
- **THEN** `proofread-backend-available-p` reports the `llm` backend as
  available

### Requirement: LLM provider backend dispatch

The system SHALL dispatch request-ready proofreading chunks through
`llm-chat-async` when the selected backend is `llm`.

#### Scenario: LLM backend submits asynchronous chat request

- **WHEN** `proofread-backend-check` is called for the `llm` backend
- **AND** `proofread-llm-provider` is configured
- **THEN** proofread submits the request through `llm-chat-async`
- **AND** proofread does not invoke the backend callback inline before
  `proofread-backend-check` returns

#### Scenario: LLM prompt contains proofread request fields

- **WHEN** proofread builds an `llm` prompt for a backend request
- **THEN** the prompt includes the request text
- **AND** the prompt includes allowed context before and after the request text
- **AND** the prompt includes the request language and `major-mode` metadata
- **AND** proofread does not rescan the buffer to build additional request text

#### Scenario: LLM prompt requests JSON diagnostics

- **WHEN** proofread builds an `llm` prompt for a backend request
- **THEN** the prompt requests JSON diagnostics with chunk-relative ranges
- **AND** proofread asks `llm` for JSON output with `response-format` or an
  equivalent JSON schema when supported

### Requirement: LLM provider callback conversion

The system SHALL convert `llm` success and error callbacks into existing
proofread backend result shapes.

#### Scenario: LLM success callback enters parser pipeline

- **WHEN** `llm-chat-async` completes successfully with response text
- **THEN** proofread parses the response text as a proofread JSON diagnostic
  payload
- **AND** proofread validates candidate diagnostics before creating proofread
  diagnostic plists
- **AND** proofread invokes the backend callback with a successful proofread
  result containing the validated diagnostics

#### Scenario: LLM error callback becomes backend error

- **WHEN** `llm-chat-async` completes with an error
- **THEN** proofread invokes the backend callback with an error result
- **AND** the error result includes the original request
- **AND** the source buffer text remains unchanged

#### Scenario: LLM invalid response becomes backend error

- **WHEN** `llm-chat-async` completes successfully with response text that
  cannot be parsed as a proofread JSON diagnostic payload
- **THEN** proofread invokes the backend callback with an error result
- **AND** proofread does not create overlays from that response

### Requirement: LLM diagnostics preserve safety boundaries

The system SHALL apply diagnostics from the `llm` backend only through the
existing stale result, cache, and overlay safety boundaries.

#### Scenario: LLM stale result is dropped

- **WHEN** an `llm` backend result returns after the source buffer is killed,
  `proofread-mode` is disabled, the modification tick changes, or the request
  text no longer matches
- **THEN** proofread drops the result
- **AND** proofread does not create overlays from that result
- **AND** proofread does not write diagnostics from that result to the cache

#### Scenario: LLM fresh result can create overlays

- **WHEN** an `llm` backend result returns for a fresh request
- **AND** the response contains valid diagnostics
- **THEN** proofread creates proofread-owned overlays through the existing
  diagnostic application path
- **AND** proofread writes accepted diagnostics to the diagnostic cache

#### Scenario: LLM backend error clears active request

- **WHEN** an active `llm` backend request completes with an error result
- **THEN** proofread removes that request from active request state
- **AND** no stale active request remains for that failed request

### Requirement: LLM provider cache identity

The system SHALL build stable cache identities for the `llm` backend without
embedding live provider objects or secrets in cache keys.

#### Scenario: LLM cache key excludes provider object

- **WHEN** proofread builds a cache key for a request using the `llm` backend
- **THEN** the cache key contains a stable provider identity
- **AND** the cache key does not contain the raw `proofread-llm-provider` object
- **AND** the cache key does not contain callbacks, buffers, request ids,
  timers, process objects, or API keys

#### Scenario: LLM provider identity change invalidates cache

- **WHEN** the stable `llm` provider identity changes for otherwise identical
  request text, language, `major-mode`, prompt version, and configuration
  version
- **THEN** proofread builds a different cache key
- **AND** old cache entries are not reused for the new provider identity

#### Scenario: LLM unchanged provider identity allows cache hit

- **WHEN** the stable `llm` provider identity and request text remain unchanged
- **AND** the diagnostic cache contains a matching entry
- **THEN** proofread may reuse cached diagnostics without calling
  `llm-chat-async`
- **AND** cached diagnostics still pass through current buffer text validation
  before overlays are created

### Requirement: Direct Ollama transition compatibility

The system SHALL keep the existing direct Ollama backend available while adding
the `llm` provider backend.

#### Scenario: Direct Ollama backend remains selectable

- **WHEN** a user selects the existing `ollama` backend
- **THEN** proofread continues to dispatch through the direct Ollama backend
  path
- **AND** the addition of the `llm` backend does not remove direct Ollama public
  configuration variables

#### Scenario: LLM backend does not use direct Ollama configuration

- **WHEN** a user selects the `llm` backend
- **THEN** proofread uses `proofread-llm-provider` for provider configuration
- **AND** proofread does not require `proofread-ollama-model`,
  `proofread-ollama-base-url`, or `proofread-ollama-options` to be set
