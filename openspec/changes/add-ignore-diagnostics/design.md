## Context

Manual application handles true positives, but users also need a low-friction
way to dismiss false positives. Ignoring must not become a hidden persistent
rewrite rule in this change; it is a session-local display decision based on
exact diagnostic identity.

The package already has diagnostic-at-point lookup, proofread-owned overlays,
and display/application paths. Ignore should reuse those ownership boundaries:
only proofread diagnostics are ignored, only proofread overlays are removed, and
ignored diagnostics are filtered before future overlays are created.

## Goals / Non-Goals

**Goals:**

- Implement `proofread-ignore` as an explicitly invoked interactive command.
- Store ignore entries in memory for the current Emacs session.
- Build ignore keys from exact diagnostic `:text` and `:kind`.
- Remove ignored proofread-owned overlays from the current buffer.
- Filter ignored diagnostics before creating proofread-owned overlays.
- Preserve unrelated diagnostics and foreign overlays.

**Non-Goals:**

- No persistent ignore storage.
- No project-level dictionary or word list.
- No fuzzy matching, regex ignore rules, or normalization beyond exact text and
  kind values.
- No automatic text changes.
- No deletion of overlays owned by other modes.

## Decisions

- Use a session-global in-memory ignore table.

  The requirement is session-scoped rather than buffer-scoped. A package-level
  hash table keyed by diagnostic identity lets the same false positive stay
  hidden when it is rediscovered in another window or buffer during the same
  Emacs session. Because it is not persisted, restarting Emacs clears the list.

- Define ignore identity as exact text plus kind.

  Text alone is too broad: the same text may have different diagnostic kinds.
  Kind alone is too broad: it would suppress unrelated text. The key should be a
  structured value derived only from `:text` and `:kind`; different kind or
  different text must miss.

- Add ignore filtering before overlay creation.

  Ignored diagnostics should be removed from the list that will be displayed
  before proofread creates overlays. This avoids creating an overlay only to
  delete it immediately and ensures backend/cache result application does not
  reintroduce ignored diagnostics visually.

- Keep command cleanup proofread-owned.

  `proofread-ignore` should add the key and delete or invalidate matching
  proofread-owned overlays in the current buffer. It must never delete foreign
  overlays. Unrelated proofread diagnostics with different ignore keys should
  remain available.

- Do not mutate source text.

  Ignore is a display/session-state operation. It should not edit the buffer,
  modify diagnostic text, or change backend/cache entries beyond display
  filtering.

## Risks / Trade-offs

- Session-global ignores may hide the same false positive in another buffer ->
  This matches the session-level intent and remains reversible by restarting
  Emacs until explicit unignore/persistence features exist.
- Exact matching may not suppress similar false positives -> Accept for safety;
  fuzzy/project rules are out of scope.
- Filtering before overlay creation can make ignored diagnostics hard to inspect
  later -> This is intended for ignored entries; future UI can add list/clear
  controls.
- Existing overlays might already exist when the user ignores -> Command cleanup
  must remove matching proofread-owned overlays in the current buffer after
  adding the ignore key.
