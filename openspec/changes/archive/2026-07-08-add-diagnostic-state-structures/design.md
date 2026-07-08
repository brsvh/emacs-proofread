## Context

The package skeleton currently exposes `proofread-mode` and placeholder public
commands, but it has no internal model for diagnostics or per-buffer state.
Later changes will add overlays, visible range scheduling, backend requests,
caching, navigation, and suggestion application. Those features need a shared
state model before they can interact safely.

This change introduces only internal data and lifecycle helpers. It does not
create visible diagnostics, start background work, or perform proofreading.

## Goals / Non-Goals

**Goals:**

- Represent diagnostics as plain plists with the minimum common fields.
- Add buffer-local state containers for diagnostics, overlays, pending ranges,
  requests, and cache.
- Initialize proofread-owned buffer state when `proofread-mode` is enabled.
- Clear only proofread-owned buffer state when `proofread-mode` is disabled.

**Non-Goals:**

- No overlay creation or faces.
- No request dispatch, timers, backend integration, or cache lookup behavior.
- No navigation, description UI, suggestion application, or ignore behavior.
- No persistence of diagnostics or state outside the buffer.

## Decisions

- Use plists for diagnostics.

  - Rationale: plists are idiomatic for lightweight Emacs Lisp structured data,
    easy to extend, and do not require a new struct API before the diagnostic
    shape stabilizes.
  - Alternative considered: `cl-defstruct`. That can be introduced later if
    validation or performance needs justify a stricter representation.

- Use `defvar-local` for buffer-owned state.

  - Rationale: proofread diagnostics and request state belong to the buffer
    being checked. Buffer-local variables avoid cross-buffer contamination and
    match how minor modes usually manage per-buffer state.
  - Alternative considered: one global hash table keyed by buffer. That would
    add cleanup complexity and make killed-buffer handling easier to get wrong
    before global scheduling exists.

- Keep cleanup limited to proofread-owned state.

  - Rationale: the mode must coexist with spelling and diagnostics packages.
    This change should not inspect or delete unrelated overlays or variables.
  - Alternative considered: proactively remove any visually similar diagnostics.
    That is out of scope and unsafe without overlay ownership metadata.

## Risks / Trade-offs

- Diagnostic plists may allow malformed data. -> Mitigate with small helper
  functions and tests that cover the required fields.
- State variables exist before they have behavior. -> Mitigate by keeping the
  initialization simple and not creating overlays, timers, or requests.
- Clearing cache state on mode disable may discard reusable data. -> Accept for
  now; cache policy is specified in a later change.
