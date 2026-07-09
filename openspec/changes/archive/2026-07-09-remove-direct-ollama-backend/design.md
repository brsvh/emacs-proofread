## Context

`proofread` currently has two real-model paths:

- direct Ollama HTTP transport selected with `proofread-backend` value `ollama`;
- provider-based transport selected with `proofread-backend` value `llm`.

The direct Ollama path owns HTTP request construction, URL buffer management,
timeout behavior, connection/error conversion, response parsing, and request
handle cleanup. The `llm` path already provides a provider abstraction that can
use Ollama through `make-llm-ollama` and other providers such as DeepSeek
through `make-llm-deepseek`.

The JSON diagnostic prompt and parser were introduced with the Ollama work, but
they are not inherently Ollama-specific. They are the proofread contract between
any model provider and the editor safety pipeline.

## Goals / Non-Goals

**Goals:**

- Remove direct Ollama transport and configuration from `proofread`.
- Keep real model calls on the `llm` backend only.
- Preserve the proofread JSON diagnostic contract, parser, validation, stale
  rejection, cache, and overlay behavior.
- Rename or reframe Ollama-specific parser/test names to generic JSON or LLM
  diagnostic names where the behavior is provider-agnostic.
- Keep tests offline and deterministic.

**Non-Goals:**

- Add a new UI for selecting `llm` providers.
- Implement migration commands or aliases for old `proofread-ollama-*`
  variables.
- Keep direct Ollama as a compatibility backend.
- Add new network-backed tests.
- Change the `llm` package provider configuration API.

## Decisions

### Decision: Remove direct Ollama instead of deprecating it in-place

The `llm` backend is now the intended provider abstraction, and keeping direct
Ollama would require maintaining duplicate transport, timeout, and error code.
Removing it now keeps the codebase smaller before additional provider-specific
behavior accumulates.

Alternative considered: keep direct Ollama as a legacy backend with warnings.
That reduces breakage but preserves the duplicate implementation surface and
keeps users on a path that the package no longer wants to extend.

### Decision: Treat `ollama` as unsupported after removal

After removal, `proofread-backend-available-p` should not report `ollama` as
available, and `proofread-backend-check` should fall through to the existing
unsupported-backend error path if called with `ollama` explicitly.

Alternative considered: special-case `ollama` with a migration error message.
That adds user-facing migration behavior, which is outside this cleanup's scope.

### Decision: Keep JSON diagnostics provider-agnostic

The JSON prompt contract, response-format, parser, and diagnostic validation
should remain available to the `llm` backend. Implementation should remove
direct HTTP/Ollama response wrapping, while keeping generic helpers that parse
model response text into proofread diagnostics.

Alternative considered: delete all `ollama`-prefixed JSON helpers and recreate
parser behavior inside the `llm` backend. That risks accidental behavior drift
and makes the removal larger than necessary.

### Decision: Convert tests before deleting transport tests

Tests that cover direct HTTP mechanics should be removed. Tests that cover JSON
payload extraction, bad ranges, text mismatch, suggestion ordering, stale
rejection, and overlay pipeline should survive with generic names and generic
helpers.

Alternative considered: delete all Ollama tests first and rely on `llm` tests.
That would lose coverage for the model-output contract that still matters.

## Risks / Trade-offs

- Breaking existing direct Ollama user configuration -> Document the migration
  path in the spec and final implementation notes: use `proofread-backend` value
  `llm` with `make-llm-ollama`.
- Accidentally deleting parser behavior still required by `llm` -> Separate
  provider-agnostic JSON helpers from direct transport helpers before removing
  transport code.
- Cache churn after renaming backend identity -> Expected for removed direct
  backend; `llm` cache identity remains provider-based.
- Test churn from renaming Ollama parser tests -> Keep assertions focused on
  behavior, not old helper names.

## Migration Plan

1. Rename or introduce generic JSON diagnostic helper names while preserving
   current parser behavior.
2. Update `llm` backend to call generic JSON helpers.
3. Remove direct Ollama defcustoms, availability branch, dispatch branch, HTTP
   helpers, timeout handling, and response-buffer cleanup code.
4. Remove direct Ollama HTTP tests and rename reusable JSON parser tests.
5. Validate with Emacs 30/31 tests, byte compilation, formatter, and diff
   checks.

Rollback strategy: revert this change to restore the direct Ollama backend.
Because no persistent data migration is performed, rollback only affects code
and user configuration.

## Open Questions

None. The change intentionally does not provide compatibility aliases or a
migration command.
