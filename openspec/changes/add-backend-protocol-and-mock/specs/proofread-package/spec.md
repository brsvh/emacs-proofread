## ADDED Requirements

### Requirement: Backend protocol

The system SHALL define a chunk-oriented backend protocol for proofreading
requests and asynchronous completion callbacks.

#### Scenario: Backend availability is queryable

- **WHEN** the package is loaded
- **THEN** `proofread-backend-available-p` can be called for a backend
- **AND** it reports whether that backend can accept proofreading requests

#### Scenario: Backend receives request plist

- **WHEN** proofread dispatches a chunk to a backend
- **THEN** `proofread-backend-check` receives a request plist
- **AND** the request plist contains the buffer, range boundaries, text,
  context, language, `major-mode`, and `buffer-chars-modified-tick`
- **AND** the request represents a region or chunk rather than a single word

#### Scenario: Successful backend callback returns diagnostics

- **WHEN** a backend completes a request successfully
- **THEN** it invokes the callback with a result that identifies successful
  completion
- **AND** the result includes the original request
- **AND** the result includes a diagnostics list

#### Scenario: Backend error callback returns error result

- **WHEN** a backend fails a request
- **THEN** it invokes the callback with a result that identifies error
  completion
- **AND** the result includes the original request
- **AND** the result includes error information

### Requirement: Asynchronous mock backend

The system SHALL provide a mock backend that follows the backend protocol and
completes asynchronously.

#### Scenario: Mock backend is available

- **WHEN** backend availability is queried for the mock backend
- **THEN** the mock backend reports available

#### Scenario: Mock backend success is asynchronous

- **WHEN** `proofread-backend-check` is called with the mock backend and a
  successful request
- **THEN** the callback is not invoked inline before `proofread-backend-check`
  returns
- **AND** the callback is invoked asynchronously with a successful result

#### Scenario: Mock backend error is asynchronous

- **WHEN** `proofread-backend-check` is called with the mock backend and a
  request configured to fail
- **THEN** the callback is not invoked inline before `proofread-backend-check`
  returns
- **AND** the callback is invoked asynchronously with an error result

### Requirement: Backend request cleanup

The system SHALL remove active request state after backend completion without
modifying buffer text on errors.

#### Scenario: Successful callback clears active request

- **WHEN** an active backend request completes successfully
- **THEN** that request is removed from proofread active request state

#### Scenario: Error callback clears active request without modifying buffer

- **WHEN** an active backend request completes with an error
- **THEN** that request is removed from proofread active request state
- **AND** the buffer text remains unchanged
- **AND** no stale request entry remains for that failed request
