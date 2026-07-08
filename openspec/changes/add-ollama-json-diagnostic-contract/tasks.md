## 1. Prompt Contract

- [x] 1.1 Audit the Ollama prompt and payload helpers from `add-ollama-backend`.
- [x] 1.2 Define the Ollama diagnostic prompt template for JSON-only
  diagnostics.
- [x] 1.3 Define the expected diagnostic object fields: kind, message, original
  text, chunk-relative range, suggestions, confidence, and source.
- [x] 1.4 Ensure prompt text instructs the model to use chunk-relative offsets,
  not absolute buffer positions.
- [x] 1.5 Update or verify `proofread-prompt-version` when the prompt contract
  changes.

## 2. JSON Extraction and Parsing

- [x] 2.1 Add a parser for valid Ollama JSON diagnostic payloads.
- [x] 2.2 Support conservative extraction when response text contains exactly
  one identifiable JSON diagnostic payload surrounded by extra text.
- [x] 2.3 Treat non-JSON responses as backend errors.
- [x] 2.4 Treat malformed JSON responses as backend errors.
- [x] 2.5 Keep ambiguous extra-text extraction conservative and deterministic.

## 3. Diagnostic Validation and Conversion

- [x] 3.1 Validate that candidate ranges are integers within the request chunk
  text.
- [x] 3.2 Validate that candidate original text exactly matches the request
  substring at the candidate range.
- [x] 3.3 Convert valid chunk-relative ranges to absolute `:beg` and `:end`
  positions.
- [x] 3.4 Validate and normalize diagnostic kind and message fields.
- [x] 3.5 Keep only string suggestions and preserve their order.
- [x] 3.6 Validate optional confidence and source fields conservatively.
- [x] 3.7 Drop invalid candidate diagnostics without dropping valid candidates
  from the same parsed response.

## 4. Backend Pipeline Integration

- [x] 4.1 Connect the Ollama backend success path to the JSON diagnostic parser.
- [x] 4.2 Ensure wholly unparsable responses become backend error results.
- [x] 4.3 Ensure parsed diagnostics still enter the existing backend result
  handler.
- [x] 4.4 Preserve stale request validation before any parsed diagnostic creates
  an overlay.
- [x] 4.5 Ensure displaying parsed diagnostics never modifies source buffer
  text.
- [x] 4.6 Ensure prompt version changes still invalidate cached diagnostics.

## 5. Tests

- [x] 5.1 Add ERT coverage for prompt text requesting JSON diagnostics and
  chunk-relative ranges.
- [x] 5.2 Add ERT coverage for valid JSON responses producing absolute proofread
  diagnostics.
- [x] 5.3 Add ERT coverage for extra text around one JSON payload.
- [x] 5.4 Add ERT coverage for non-JSON responses producing backend errors.
- [x] 5.5 Add ERT coverage for malformed JSON responses producing backend
  errors.
- [x] 5.6 Add ERT coverage for out-of-range candidate diagnostics being dropped.
- [x] 5.7 Add ERT coverage for text mismatch candidate diagnostics being
  dropped.
- [x] 5.8 Add ERT coverage that one invalid candidate does not discard valid
  candidates from the same response.
- [x] 5.9 Add ERT coverage that suggestions preserve model order and non-string
  suggestions are ignored.
- [x] 5.10 Add ERT coverage for optional confidence and source field handling.
- [x] 5.11 Add ERT coverage that parsed diagnostics still pass stale validation
  before overlay creation.
- [x] 5.12 Add ERT coverage that prompt version changes cause cache misses.

## 6. Validation

- [x] 6.1 Run the batch ERT command for Emacs 30 and confirm it passes.
- [x] 6.2 Run the batch ERT command for Emacs 31 and confirm it passes.
- [x] 6.3 Run byte-compilation validation for `lisp/proofread.el`.
- [x] 6.4 Run formatting validation for changed files.
- [x] 6.5 Run `openspec status --change "add-ollama-json-diagnostic-contract"`
  and confirm the change is complete.
- [x] 6.6 Run
  `openspec instructions apply --change "add-ollama-json-diagnostic-contract" --json`
  and confirm the apply workflow is ready.
- [x] 6.7 Run
  `git diff --check -- openspec/changes/add-ollama-json-diagnostic-contract` and
  confirm there are no whitespace errors in the change artifacts.
