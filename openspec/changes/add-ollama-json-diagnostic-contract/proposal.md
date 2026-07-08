## Why

The Ollama backend can submit chunks to a real model, but model prose is not
safe enough to drive overlays. Qwen3-style models may also emit reasoning or
extra text, so proofread needs a strict prompt contract and conservative parser
that only accepts diagnostics which can be located and verified against the
original chunk.

## What Changes

- Define the Ollama diagnostic prompt contract for JSON diagnostics.
- Define the expected diagnostic object shape: kind, message, original text,
  chunk-relative range, suggestions, confidence, and optional source.
- Convert chunk-relative diagnostics to absolute buffer diagnostics.
- Validate offsets, original text matching, suggestions, and optional fields
  before creating proofread diagnostic plists.
- Drop invalid diagnostics while preserving valid diagnostics from the same
  parsed response.
- Treat wholly unparsable or non-JSON responses as backend errors.
- Preserve suggestion order exactly as returned by the model.
- Ensure prompt version changes invalidate diagnostic cache entries.
- Do not implement complex location mapping, automatic fixes, batch retries, or
  model quality evaluation.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: The Ollama backend gains a JSON diagnostic contract and
  parser so only verifiable chunk-relative diagnostics can enter the existing
  proofread overlay pipeline.

## Impact

- Affects `lisp/proofread.el` Ollama prompt construction, response parsing,
  diagnostic conversion, and cache prompt-version behavior.
- Adds ERT coverage in `test/proofread-tests.el` for valid JSON, extra text,
  invalid JSON, bad offsets, text mismatch, optional fields, and suggestion
  ordering.
- Depends on `add-ollama-backend`, which provides the Ollama transport and
  backend callback integration.
- Adds no new network behavior beyond the existing Ollama backend.
