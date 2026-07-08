## ADDED Requirements

### Requirement: Ollama JSON diagnostic prompt contract

The system SHALL ask Ollama for diagnostics in a JSON format that proofread can
parse and validate.

#### Scenario: Prompt requests JSON diagnostics

- **WHEN** proofread builds an Ollama prompt for a backend request
- **THEN** the prompt requests JSON diagnostics rather than free-form prose

#### Scenario: Prompt describes required diagnostic fields

- **WHEN** proofread builds an Ollama prompt for a backend request
- **THEN** the prompt describes diagnostic fields for kind, message, original
  text, chunk-relative range, suggestions, and confidence

#### Scenario: Prompt contract participates in cache invalidation

- **WHEN** the Ollama prompt contract changes
- **THEN** `proofread-prompt-version` can be changed so old cache entries no
  longer match new requests

### Requirement: Ollama JSON diagnostic parsing

The system SHALL parse Ollama response text into candidate diagnostics only when
a JSON diagnostic payload can be identified.

#### Scenario: Valid JSON response parses diagnostics

- **WHEN** Ollama returns valid JSON containing diagnostics
- **THEN** proofread extracts candidate diagnostics from the JSON payload

#### Scenario: Extra text with one JSON payload can parse

- **WHEN** Ollama returns extra text around one identifiable JSON diagnostic
  payload
- **THEN** proofread may extract and parse that JSON payload

#### Scenario: Non-JSON response is a backend error

- **WHEN** Ollama returns response text from which no JSON diagnostic payload
  can be parsed
- **THEN** proofread treats the response as a backend error

#### Scenario: Invalid JSON response is a backend error

- **WHEN** Ollama returns malformed JSON
- **THEN** proofread treats the response as a backend error

### Requirement: Ollama diagnostic validation

The system SHALL validate candidate Ollama diagnostics before converting them to
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

#### Scenario: Invalid suggestions are dropped or normalized conservatively

- **WHEN** a candidate diagnostic contains suggestions
- **THEN** proofread keeps only string suggestions
- **AND** proofread preserves the order of kept suggestions

#### Scenario: Invalid optional fields do not create unsafe diagnostics

- **WHEN** a candidate diagnostic contains invalid optional fields such as
  confidence or source
- **THEN** proofread either omits those fields or drops the candidate diagnostic
  conservatively

#### Scenario: Invalid candidate does not discard valid candidates

- **WHEN** a parsed response contains both valid and invalid candidate
  diagnostics
- **THEN** proofread converts the valid candidates
- **AND** proofread does not create diagnostics for the invalid candidates

### Requirement: Ollama diagnostics preserve existing safety boundaries

The system SHALL apply parsed Ollama diagnostics only through the existing
proofread backend result handling path.

#### Scenario: Parsed diagnostics still require stale validation

- **WHEN** proofread handles parsed Ollama diagnostics
- **THEN** stale request validation still runs before overlays are created

#### Scenario: Parsed diagnostics do not modify buffer text

- **WHEN** proofread displays parsed Ollama diagnostics
- **THEN** source buffer text remains unchanged

#### Scenario: Suggestions keep model order

- **WHEN** a valid Ollama diagnostic contains multiple string suggestions
- **THEN** the resulting proofread diagnostic stores those suggestions in the
  same order
