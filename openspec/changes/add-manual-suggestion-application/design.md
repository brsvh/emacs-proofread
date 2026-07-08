## Context

Diagnostics can now be navigated and described, giving users enough information
to decide whether a suggestion is acceptable. The next step is a manual command
that applies one chosen suggestion to the diagnostic at point while preserving
the user's control over all text changes.

This command must be conservative. Diagnostics can become stale after edits or
overlay invalidation, so application must re-check the proofread-owned
diagnostic, its overlay state, and the current buffer text before replacing
anything.

## Goals / Non-Goals

**Goals:**

- Implement `proofread-apply-suggestion` as an explicitly invoked interactive
  command.
- Use the proofread-owned diagnostic at point as the target.
- Select among multiple suggestions with completion.
- Validate that the target overlay/diagnostic is still valid before modifying
  text.
- Validate that current buffer text at the diagnostic range equals the
  diagnostic original text.
- Replace only the diagnostic range.
- Create undo boundaries compatible with normal Emacs undo.
- Delete or invalidate affected proofread-owned overlays after replacement.

**Non-Goals:**

- No automatic correction.
- No batch apply.
- No project-wide application.
- No application outside the diagnostic range.
- No backend-specific suggestion semantics.

## Decisions

- Use diagnostic-at-point lookup as the target source.

  The description UI establishes the rule for finding a proofread-owned
  diagnostic at point. Application should use the same rule so users apply the
  diagnostic they can inspect and navigate to.

- Require explicit command invocation for every modification.

  Suggestions should never be applied from backend callbacks, idle timers,
  overlay modification hooks, or navigation. The only mutation entry point in
  this change is `proofread-apply-suggestion`.

- Use completion for multiple suggestions.

  If a diagnostic has more than one suggestion, the command should prompt with
  `completing-read` or equivalent completion. For one suggestion, the command
  can use that suggestion directly after the explicit command invocation. For no
  suggestions, it should report that no suggestion is available.

- Validate stale state before replacement.

  Before editing, confirm the selected diagnostic still has a live
  proofread-owned overlay, the range remains valid, and the text in that range
  equals the diagnostic's original `:text`. Any failure should abort with a
  clear reason and no buffer modification.

- Bound the edit and undo history deliberately.

  Replacement should happen between explicit undo boundaries so a user can undo
  the suggestion as a coherent operation. The command should not merge the
  replacement into unrelated prior edits.

- Invalidate affected proofread overlays after replacement.

  Once the source text changes, any proofread-owned overlay intersecting the
  replaced range should be deleted or marked invalid. This prevents stale
  diagnostics from remaining visible after the user accepts a suggestion.

## Risks / Trade-offs

- Single-suggestion direct application can surprise users who expected a second
  prompt -> The explicit command invocation is the confirmation for one
  suggestion; multiple suggestions still require completion.
- Overlay and diagnostic state can diverge -> Require a live proofread-owned
  overlay before applying, and reject stale state conservatively.
- Undo boundary behavior can be subtle -> Add tests that exercise `undo` after
  application.
- Replacement can trigger overlay modification hooks -> Treat hook-driven
  overlay deletion as acceptable, while still explicitly cleaning affected
  proofread overlays after the edit.
