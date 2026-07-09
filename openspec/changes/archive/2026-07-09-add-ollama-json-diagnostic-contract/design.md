## Context

The Ollama backend can deliver model responses through the existing backend
callback path. The remaining problem is trust: free-form model output is not a
safe source of overlay positions. A diagnostic must point to exact text in the
request chunk before proofread can display it, cache it, navigate to it, or let
the user apply a suggestion.

This change defines the first Ollama diagnostic contract. The prompt should ask
for JSON diagnostics, and the parser should accept only diagnostics whose
chunk-relative range and original text match the request chunk. The conversion
from chunk-relative ranges to absolute buffer ranges must happen inside
proofread, not inside the model.

## Goals / Non-Goals

**Goals:**

- Define an Ollama prompt template for JSON diagnostics.
- Define the expected JSON object structure for diagnostics.
- Parse Ollama response text into candidate diagnostics.
- Convert valid chunk-relative ranges into absolute proofread diagnostics.
- Validate offsets, text matching, suggestions, kind, confidence, and optional
  fields before creating diagnostic plists.
- Preserve valid diagnostics when other diagnostics in the same response are
  invalid.
- Treat wholly unparsable responses as backend errors.
- Ensure prompt version changes continue to invalidate cache entries.

**Non-Goals:**

- No complex position mapping beyond exact chunk-relative offsets.
- No sentence splitting, fuzzy matching, or approximate recovery when text does
  not match.
- No automatic fixing or batch suggestion application.
- No retry loop for malformed model output.
- No model quality evaluation or benchmark harness.
- No change to the Ollama HTTP transport beyond using the new prompt and parser.

## Decisions

- Use chunk-relative ranges as the model contract.

  The model should return offsets relative to the chunk text it received. The
  backend adapter converts those offsets to absolute buffer positions using the
  originating request. This avoids trusting the model with absolute buffer
  positions and keeps stale validation in the existing request pipeline.

- Require exact original text matching.

  A candidate diagnostic is valid only when the substring at its relative range
  exactly equals the model-provided original text. The alternative of fuzzy
  matching would introduce position ambiguity and belongs to a later mapping
  change if needed.

- Keep schema validation conservative.

  Each diagnostic must have a valid kind, message, original text, and range.
  Suggestions must be strings and must preserve model order. Confidence and
  source are optional, but when present they must have sane types. Invalid
  diagnostics are dropped before overlay creation.

- Separate whole-response parse errors from per-diagnostic validation errors.

  If no JSON payload can be parsed, the backend result should be an error. If a
  JSON payload is parsed and contains a diagnostics array, invalid entries
  should be dropped while valid entries continue. This lets the UI benefit from
  partially correct model output without trusting bad locations.

- Allow bounded extraction from extra text.

  Some models may include extra prose or reasoning despite the prompt. The
  parser may attempt a conservative extraction of one JSON object from the
  response text. If extraction is ambiguous or fails, the response is treated as
  unparsable. This behavior should be tested because it is easy to become too
  permissive.

- Keep prompt version as the cache contract boundary.

  The prompt template and response schema are part of the cache contract. When
  the prompt contract changes, `proofread-prompt-version` must change so cached
  diagnostics produced under the old contract do not apply to new behavior.

## Risks / Trade-offs

- [Risk] Strict exact matching may drop useful diagnostics. -> Mitigation:
  prefer false negatives over overlays on the wrong text; later changes can add
  explicit fuzzy mapping with tests.

- [Risk] Conservative JSON extraction may reject responses that humans could
  interpret. -> Mitigation: tune the prompt and keep parser behavior
  deterministic and testable.

- [Risk] Partial acceptance can hide parser/model quality problems. ->
  Mitigation: tests should cover dropped diagnostics and preserve a clear
  backend error path for wholly invalid responses.

- [Risk] Prompt changes without prompt-version updates can reuse stale cache. ->
  Mitigation: make prompt version invalidation explicit in tests and tasks.

## Migration Plan

No persistent migration is required. Existing in-memory cache entries are
already keyed by prompt version and backend identity. Implementation should
update the prompt version when the contract changes and keep stale request
validation unchanged.

## Open Questions

- Should diagnostic kind be limited to a fixed set of symbols, or should the
  parser accept backend-provided strings and normalize them?
- Should confidence values be required for Ollama diagnostics, or remain
  optional until model output quality is better understood?
