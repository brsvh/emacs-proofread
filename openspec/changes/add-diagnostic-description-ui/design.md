## Context

Navigation gives users a way to reach proofread-owned diagnostics in the current
buffer, but the overlay itself does not expose enough information to decide
whether a suggestion is useful. The package already represents diagnostics as
plists with fields such as `:kind`, `:message`, `:text`, `:suggestions`,
`:confidence`, and `:source`.

This change adds a lightweight description command for the diagnostic at point.
It should display stable, backend-independent diagnostic fields and avoid
modifying the source buffer.

## Goals / Non-Goals

**Goals:**

- Find the proofread-owned diagnostic covering point.
- Implement `proofread-describe` as an interactive command.
- Display kind, message, original text, suggestions, confidence, and source when
  present.
- Preserve suggestion order exactly as stored in the diagnostic.
- Handle missing optional fields without errors.
- Keep the source buffer text and proofread diagnostic state unchanged.

**Non-Goals:**

- No list buffer showing all diagnostics.
- No batch report export.
- No suggestion application.
- No ignore workflow.
- No backend-specific rendering based on private backend data.

## Decisions

- Use proofread-owned diagnostics as the lookup source.

  The lookup helper should inspect `proofread--diagnostics`, not arbitrary
  overlays. This matches navigation and avoids describing foreign overlays or
  stale display objects.

- Use a stable point lookup rule.

  A diagnostic covers point when point is within its `:beg` and `:end` range. If
  multiple proofread diagnostics cover point, choose the first diagnostic in
  navigation order: sorted by `:beg`, then `:end`. This keeps overlap behavior
  deterministic without adding UI for selecting among overlapping diagnostics.

- Use a help-buffer style display.

  A help buffer handles multi-line text and multiple suggestions cleanly while
  keeping the source buffer read-only. The formatter can be tested separately
  from the interactive display by producing plain text sections.

- Render only stable diagnostic plist fields.

  The description should depend on package-level fields: `:kind`, `:message`,
  `:text`, `:suggestions`, `:confidence`, and `:source`. Missing optional fields
  should be omitted or shown with a neutral placeholder, but must not signal an
  error.

- Report absence at point consistently.

  If no proofread-owned diagnostic covers point, `proofread-describe` should
  report that there is no proofread diagnostic at point and leave point and
  buffer text unchanged.

## Risks / Trade-offs

- Overlapping diagnostics can hide another diagnostic's detail -> Use the same
  deterministic order as navigation; a later richer UI can expose alternatives.
- Help-buffer output may be harder to assert than return values -> Keep a
  formatter helper that returns text for focused tests.
- Optional fields can be absent or nil -> Render conditionally and test missing
  fields explicitly.
- Source values may be symbols or strings -> Format with generic Emacs printing
  rather than relying on backend-private structures.
