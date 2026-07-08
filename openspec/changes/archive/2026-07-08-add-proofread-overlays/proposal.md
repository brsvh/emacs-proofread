## Why

Diagnostics need a proofread-owned visual representation before navigation,
description, and suggestion application can build on them. Adding overlay
management now keeps display concerns isolated from other spelling or diagnostic
tools and prevents overlays from becoming the only source of diagnostic state.

## What Changes

- Define `proofread-face` and `proofread-current-face` for diagnostics and the
  current diagnostic.
- Create proofread-owned overlays with a private `proofread-overlay` category.
- Store the corresponding diagnostic on each overlay with the
  `proofread-diagnostic` property.
- Track proofread-owned overlays in buffer-local state.
- Implement `proofread-clear` so it deletes only proofread-owned overlays in the
  current buffer.
- Add cheap overlay modification handling that removes or invalidates owned
  overlays when their covered text changes.
- Do not add backend checking, automatic diagnostic generation, navigation,
  description, suggestion application, or ignore behavior.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Add requirements for proofread-owned overlay display,
  cleanup, theme-compatible faces, and edit invalidation.

## Impact

- Updates `lisp/proofread.el`.
- Extends existing diagnostic and buffer-local state behavior with a display
  layer.
- Adds no runtime dependency, network behavior, timers, or backend requests.
- Keeps integration isolated from other spelling and diagnostic packages by
  using proofread-owned overlay metadata.
