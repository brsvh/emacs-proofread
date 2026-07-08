## ADDED Requirements

### Requirement: Ollama backend configuration

The system SHALL provide configuration for using Ollama as a proofread backend.

#### Scenario: Ollama backend can be selected

- **WHEN** the user sets `proofread-backend` to `ollama`
- **THEN** proofread treats `ollama` as a supported backend value

#### Scenario: Ollama backend has local default endpoint

- **WHEN** the package is loaded
- **THEN** `proofread-ollama-base-url` defaults to the local Ollama API endpoint

#### Scenario: Ollama backend has configurable model

- **WHEN** the user changes `proofread-ollama-model`
- **THEN** subsequent Ollama backend requests use the configured model name

#### Scenario: Ollama backend has configurable options and timeout

- **WHEN** the user configures Ollama options or timeout
- **THEN** subsequent Ollama backend requests use those settings

### Requirement: Ollama backend availability

The system SHALL report Ollama backend availability through the existing backend
availability API.

#### Scenario: Ollama backend reports available when configured

- **WHEN** `proofread-backend-available-p` is called for `ollama`
- **AND** the Ollama backend has the required configuration
- **THEN** the function reports that the backend can accept requests

#### Scenario: Ollama backend reports unavailable when model is missing

- **WHEN** `proofread-backend-available-p` is called for `ollama`
- **AND** no Ollama model is configured
- **THEN** the function reports that the backend cannot accept requests

### Requirement: Ollama backend dispatch

The system SHALL submit request-ready chunks to Ollama asynchronously.

#### Scenario: Ollama request uses filtered chunk text

- **WHEN** proofread dispatches a request-ready chunk to the Ollama backend
- **THEN** the HTTP request body contains the request plist's `:text`
- **AND** the backend does not rescan buffer text outside the request plist

#### Scenario: Ollama request uses configured model

- **WHEN** proofread dispatches a request-ready chunk to the Ollama backend
- **THEN** the HTTP request body contains `proofread-ollama-model`

#### Scenario: Ollama request is non-streaming

- **WHEN** proofread dispatches a request-ready chunk to the Ollama backend
- **THEN** the HTTP request body requests non-streaming generation

#### Scenario: Ollama callback is asynchronous

- **WHEN** `proofread-backend-check` is called with the Ollama backend
- **THEN** the backend callback is not invoked inline before
  `proofread-backend-check` returns

### Requirement: Ollama backend success handling

The system SHALL convert successful Ollama responses into existing proofread
backend success results.

#### Scenario: Successful Ollama response returns diagnostics

- **WHEN** Ollama returns a successful response containing valid proofread
  diagnostics
- **THEN** proofread invokes the backend callback with status `ok`
- **AND** the result contains diagnostics in the existing proofread diagnostic
  plist shape

#### Scenario: Ollama diagnostics enter existing overlay pipeline

- **WHEN** a fresh Ollama success result is handled
- **THEN** proofread applies diagnostics through the existing backend result
  handling path
- **AND** stale result rejection still runs before overlays are created

### Requirement: Ollama backend error handling

The system SHALL convert Ollama failures into existing proofread backend error
results without modifying source buffers.

#### Scenario: HTTP error preserves buffer text

- **WHEN** Ollama returns an HTTP error response
- **THEN** proofread invokes the backend callback with status `error`
- **AND** source buffer text remains unchanged
- **AND** active request state is cleared

#### Scenario: Connection failure preserves buffer text

- **WHEN** the Ollama service cannot be reached
- **THEN** proofread invokes the backend callback with status `error`
- **AND** source buffer text remains unchanged
- **AND** active request state is cleared

#### Scenario: Timeout preserves buffer text

- **WHEN** an Ollama request exceeds the configured timeout
- **THEN** proofread invokes the backend callback with status `error`
- **AND** source buffer text remains unchanged
- **AND** active request state is cleared

#### Scenario: Invalid Ollama response preserves buffer text

- **WHEN** Ollama returns a response that cannot be converted to proofread
  diagnostics
- **THEN** proofread invokes the backend callback with status `error`
- **AND** source buffer text remains unchanged
- **AND** active request state is cleared
