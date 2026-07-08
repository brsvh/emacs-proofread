## Context

`proofread-mode` already has a loadable package surface, diagnostic plist
helpers, and buffer-local state for diagnostics and overlays. The next step is
to render diagnostics in the buffer while preserving the separation between
diagnostic data and its visual representation.

This change is limited to display ownership and lifecycle. It must not start
backend work, schedule timers, create cache behavior, or implement navigation
and suggestion commands beyond the new `proofread-clear` behavior.

## Goals / Non-Goals

**Goals:**

- Add proofread-owned faces and overlay metadata for displayed diagnostics.
- Keep overlays as a disposable view of diagnostics, not as the canonical
  diagnostic store.
- Ensure `proofread-clear` and edit invalidation affect only overlays owned by
  `proofread-mode`.
- Keep overlay modification handling cheap and local to the edited overlay.

**Non-Goals:**

- Do not generate diagnostics from a backend.
- Do not schedule automatic checks or asynchronous requests.
- Do not implement diagnostic navigation, description, suggestion application,
  or ignore behavior.
- Do not integrate with other spelling or diagnostic packages.

## Decisions

- Use private overlay ownership metadata.

  Proofread overlays will have category `proofread-overlay` and a
  `proofread-diagnostic` property. Ownership checks should use this metadata
  before deleting or mutating an overlay. This avoids deleting overlays from
  other packages and keeps proofread behavior independent from their categories,
  keymaps, faces, and modification hooks.

- Keep diagnostic state separate from overlay state.

  The existing `proofread--diagnostics` buffer-local state remains the
  diagnostic source. `proofread--overlays` tracks display objects so they can be
  cleaned up efficiently, but an overlay is not the only place where a
  diagnostic exists.

- Delete or invalidate proofread overlays on text modification.

  Each proofread overlay should install a small modification hook that checks
  whether the changed overlay is proofread-owned and then removes or marks that
  overlay invalid. The hook must not trigger backend requests, rescan the
  buffer, or inspect unrelated overlays.

- Define theme-compatible proofread faces.

  `proofread-face` and `proofread-current-face` should be package-owned faces
  with no hard-coded color values. They may use color-free attributes or inherit
  from generic built-in faces, but must not reuse another spelling or diagnostic
  package's face as the proofread face.

## Risks / Trade-offs

- Stale overlay references after edits -> Filter `proofread--overlays` when
  clearing or creating overlays so dead overlays do not accumulate.
- Modification hooks can be called frequently -> Keep the hook constant-time for
  the overlay being modified and avoid backend or buffer-wide work.
- Face defaults may look different across themes -> Avoid fixed colors and rely
  on theme-compatible attributes so users can customize the package faces.
