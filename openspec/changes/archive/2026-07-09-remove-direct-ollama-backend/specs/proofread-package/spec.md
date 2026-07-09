## ADDED Requirements

### Requirement: Provider-based real model backend

The system SHALL use the `llm` backend as the only supported real-model backend
path.

#### Scenario: Direct Ollama backend is unavailable

- **WHEN** backend availability is queried for the `ollama` backend
- **THEN** `proofread-backend-available-p` reports the backend as unavailable

#### Scenario: Direct Ollama backend is unsupported

- **WHEN** `proofread-backend-check` is called explicitly with the `ollama`
  backend
- **THEN** proofread does not dispatch an HTTP request to Ollama
- **AND** proofread returns through the unsupported backend error path

#### Scenario: Ollama uses LLM provider backend

- **WHEN** a user wants to use Ollama after direct backend removal
- **THEN** the supported path is to set `proofread-backend` to `llm`
- **AND** configure `proofread-llm-provider` with an Ollama provider from the
  `llm` package

#### Scenario: DeepSeek uses LLM provider backend

- **WHEN** a user wants to use DeepSeek
- **THEN** the supported path is to set `proofread-backend` to `llm`
- **AND** configure `proofread-llm-provider` with a DeepSeek provider from the
  `llm` package

### Requirement: Provider-agnostic JSON diagnostic prompt contract

The system SHALL keep a JSON diagnostic prompt contract that is independent of
any direct transport backend.

#### Scenario: LLM prompt requests JSON diagnostics

- **WHEN** proofread builds an `llm` prompt for a backend request
- **THEN** the prompt requests JSON diagnostics rather than free-form prose

#### Scenario: LLM prompt describes required diagnostic fields

- **WHEN** proofread builds an `llm` prompt for a backend request
- **THEN** the prompt describes diagnostic fields for kind, message, original
  text, chunk-relative range, suggestions, and confidence

#### Scenario: Prompt contract participates in cache invalidation

- **WHEN** the JSON prompt contract changes
- **THEN** `proofread-prompt-version` can be changed so old cache entries no
  longer match new requests

### Requirement: Provider-agnostic JSON diagnostic parsing

The system SHALL parse model response text into candidate diagnostics only when
a JSON diagnostic payload can be identified.

#### Scenario: Valid JSON response parses diagnostics

- **WHEN** an `llm` provider returns valid JSON containing diagnostics
- **THEN** proofread extracts candidate diagnostics from the JSON payload

#### Scenario: Extra text with one JSON payload can parse

- **WHEN** an `llm` provider returns extra text around one identifiable JSON
  diagnostic payload
- **THEN** proofread may extract and parse that JSON payload

#### Scenario: Non-JSON response is a backend error

- **WHEN** an `llm` provider returns response text from which no JSON diagnostic
  payload can be parsed
- **THEN** proofread treats the response as a backend error

#### Scenario: Invalid JSON response is a backend error

- **WHEN** an `llm` provider returns malformed JSON
- **THEN** proofread treats the response as a backend error

### Requirement: Provider-agnostic diagnostic validation

The system SHALL validate candidate diagnostics before converting them to
proofread diagnostic plists.

#### Scenario: Valid diagnostic becomes absolute diagnostic

- **WHEN** a candidate diagnostic has a chunk-relative range inside the request
  text
- **AND** the candidate original text exactly matches the request substring at
  that range
- **THEN** proofread converts it to a diagnostic with absolute `:beg` and `:end`
  positions

#### Scenario: Out-of-range diagnostic is dropped

- **WHEN** a candidate diagnostic range is outside the request chunk text
- **THEN** proofread does not create a proofread diagnostic for that candidate

#### Scenario: Text mismatch diagnostic is dropped

- **WHEN** a candidate diagnostic original text does not match the request
  substring at its range
- **THEN** proofread does not create a proofread diagnostic for that candidate

#### Scenario: Suggestions preserve string order

- **WHEN** a valid candidate diagnostic contains multiple string suggestions
- **THEN** the resulting proofread diagnostic stores those suggestions in the
  same order

#### Scenario: Invalid candidate does not discard valid candidates

- **WHEN** a parsed response contains both valid and invalid candidate
  diagnostics
- **THEN** proofread converts the valid candidates
- **AND** proofread does not create diagnostics for the invalid candidates

### Requirement: Provider-agnostic diagnostics preserve safety boundaries

The system SHALL apply parsed model diagnostics only through the existing
proofread backend result handling path.

#### Scenario: Parsed diagnostics still require stale validation

- **WHEN** proofread handles parsed diagnostics from an `llm` provider
- **THEN** stale request validation still runs before overlays are created

#### Scenario: Parsed diagnostics do not modify buffer text

- **WHEN** proofread displays parsed diagnostics from an `llm` provider
- **THEN** source buffer text remains unchanged

#### Scenario: Parsed diagnostics enter existing overlay pipeline

- **WHEN** a fresh `llm` backend result contains valid parsed diagnostics
- **THEN** proofread applies diagnostics through the existing backend result
  handling path
- **AND** proofread writes accepted diagnostics to the diagnostic cache

## REMOVED Requirements

### Requirement: Direct Ollama transition compatibility

**Reason**: The transition period is over; direct Ollama is no longer kept as a
parallel backend now that the `llm` provider backend exists.

**Migration**: Use `proofread-backend` value `llm` with an Ollama provider
object in `proofread-llm-provider`.

### Requirement: Ollama backend configuration

**Reason**: Proofread no longer owns provider-specific Ollama HTTP
configuration.

**Migration**: Configure Ollama through an `llm` package provider instead of
`proofread-ollama-*` variables.

### Requirement: Ollama backend availability

**Reason**: Direct Ollama availability no longer exists as a proofread backend
concern.

**Migration**: Use `proofread-backend-available-p` for the `llm` backend after
configuring `proofread-llm-provider`.

### Requirement: Ollama backend dispatch

**Reason**: Proofread no longer dispatches provider-specific HTTP requests to
Ollama.

**Migration**: Dispatch through the `llm` backend, which calls `llm-chat-async`.

### Requirement: Ollama backend success handling

**Reason**: Direct Ollama response wrapping is removed; successful model
responses now enter proofread through `llm` backend callbacks.

**Migration**: Keep using the generic JSON diagnostic parser through the `llm`
backend.

### Requirement: Ollama backend error handling

**Reason**: Direct Ollama HTTP, connection, timeout, and response-buffer error
handling is removed with the direct transport.

**Migration**: Provider errors are converted through the `llm` backend error
callback path.

### Requirement: Ollama JSON diagnostic prompt contract

**Reason**: The JSON diagnostic prompt contract is still required, but it is no
longer direct-Ollama-specific.

**Migration**: Use the provider-agnostic JSON diagnostic prompt contract.

### Requirement: Ollama JSON diagnostic parsing

**Reason**: The JSON parser is still required, but it is no longer
direct-Ollama-specific.

**Migration**: Use provider-agnostic JSON diagnostic parsing for `llm` response
text.

### Requirement: Ollama diagnostic validation

**Reason**: Diagnostic validation is still required, but it is no longer tied to
direct Ollama responses.

**Migration**: Use provider-agnostic diagnostic validation.

### Requirement: Ollama diagnostics preserve existing safety boundaries

**Reason**: Safety boundaries are still required, but parsed diagnostics now
enter through the generic `llm` backend.

**Migration**: Use provider-agnostic diagnostics through the existing backend
result handling path.
