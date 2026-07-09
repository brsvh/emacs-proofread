## ADDED Requirements

### Requirement: Offline batch validation commands

The project SHALL provide documented commands that validate the proofread
package from the repository root without requiring network access or external
model services.

#### Scenario: Batch ERT command runs offline

- **WHEN** a developer runs the documented batch ERT command from the repository
  root
- **THEN** Emacs loads `test/proofread-tests.el` in batch mode
- **AND** the tests use local fixtures or the mock backend
- **AND** the command does not require a real backend, network access, or model
  service

#### Scenario: Batch ERT command uses clean Emacs state

- **WHEN** the documented batch ERT command starts Emacs
- **THEN** Emacs uses a temporary or otherwise clean init directory
- **AND** user init files are not required for the tests to pass

#### Scenario: Byte compilation validates package symbols

- **WHEN** the documented byte-compilation validation is run for
  `lisp/proofread.el`
- **THEN** byte compilation finishes successfully
- **AND** the output contains no warnings indicating missing functions or
  missing variables owned by the proofread package

#### Scenario: Formatting validation remains runnable

- **WHEN** the documented formatting validation command or hook is run
- **THEN** formatting validation completes successfully for the changed
  proofread package files

### Requirement: Core proofreading behavior test coverage

The project SHALL include ERT coverage for the first complete proofread
diagnostic workflow.

#### Scenario: Chunking behavior is covered

- **WHEN** the ERT suite runs
- **THEN** it verifies ordinary paragraph chunking
- **AND** it verifies whitespace-only text produces no chunks
- **AND** it verifies oversized paragraphs split into bounded chunks
- **AND** it verifies chunk text exactly matches the recorded buffer range

#### Scenario: Pre-request filtering behavior is covered

- **WHEN** the ERT suite runs
- **THEN** it verifies URL filtering before backend requests
- **AND** it verifies email filtering before backend requests
- **AND** it verifies ignored face filtering before backend requests
- **AND** it verifies ignored property filtering before backend requests
- **AND** it verifies invisible text filtering before backend requests

#### Scenario: Asynchronous stale result rejection is covered

- **WHEN** the ERT suite runs
- **THEN** it verifies stale results from killed buffers do not create overlays
- **AND** it verifies stale results after `proofread-mode` is disabled do not
  create overlays or modify buffer state
- **AND** it verifies stale results after buffer tick changes are rejected
- **AND** it verifies stale results after chunk text mismatches are rejected

#### Scenario: Overlay lifecycle behavior is covered

- **WHEN** the ERT suite runs
- **THEN** it verifies `proofread-clear` removes proofread-owned overlays
- **AND** it verifies proofread cleanup preserves unrelated overlays
- **AND** it verifies editing covered text invalidates affected proofread
  overlays
- **AND** it verifies disabling `proofread-mode` clears proofread-owned overlays

#### Scenario: Diagnostic cache behavior is covered

- **WHEN** the ERT suite runs
- **THEN** it verifies unchanged visible text can reuse cached diagnostics
- **AND** it verifies cache misses call the backend
- **AND** it verifies backend name or prompt version changes invalidate old
  cache entries
- **AND** it verifies cached diagnostics still pass text and stale-result
  validation before overlay creation

#### Scenario: Diagnostic interaction behavior is covered

- **WHEN** the ERT suite runs
- **THEN** it verifies `proofread-next` and `proofread-previous` ordering and
  boundary behavior
- **AND** it verifies `proofread-describe` reports diagnostic details without
  modifying source buffer text
- **AND** it verifies `proofread-apply-suggestion` handles single suggestions,
  multiple suggestions, stale overlays, and undo
- **AND** it verifies `proofread-ignore` uses exact text and kind matching,
  removes only matching proofread-owned overlays, and preserves unrelated
  diagnostics

### Requirement: Validation commands are deterministic

The project SHALL keep local validation commands stable and repeatable for
developers and CI-style batch runs.

#### Scenario: Validation commands run from repository root

- **WHEN** a developer follows the documented validation instructions
- **THEN** the test command, byte-compilation command, and formatting command
  can be run from the repository root

#### Scenario: Validation commands leave no persistent runtime state

- **WHEN** validation commands finish
- **THEN** they leave no required running backend process
- **AND** they leave no persistent cache or model-service state needed by later
  test runs

#### Scenario: Validation failure identifies the failing layer

- **WHEN** validation fails
- **THEN** the failing command distinguishes whether the failure came from ERT,
  byte compilation, or formatting validation
