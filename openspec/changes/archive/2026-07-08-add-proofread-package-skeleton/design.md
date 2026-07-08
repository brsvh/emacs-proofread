## Context

The repository needs a first Emacs Lisp entry point for a context-aware
proofreading minor mode. Later changes will add diagnostics, overlays, visible
range discovery, asynchronous backend requests, caching, navigation, and
correction commands. This change deliberately keeps the initial implementation
small so that later behavior can be reviewed independently.

The current scope is a loadable package skeleton only. It establishes the public
symbols and customization group without installing hooks, timers, overlays, or
request state.

## Goals / Non-Goals

**Goals:**

- Add `lisp/proofread.el` as a loadable Emacs Lisp package.
- Define the `proofread` customization group and initial customization
  variables.
- Define buffer-local `proofread-mode`.
- Provide placeholder interactive commands for the planned public command
  surface.
- Keep mode enable/disable side-effect free beyond toggling the mode variable.

**Non-Goals:**

- No diagnostics or diagnostic data structures.
- No overlays, faces, keymaps, or modification hooks.
- No idle timer scheduling.
- No backend protocol, mock backend, request dispatch, or network behavior.
- No cache or visible range processing.

## Decisions

- Keep all implementation in `lisp/proofread.el`.

  - Rationale: a single file is enough for the package skeleton and matches the
    small scope of the change.
  - Alternative considered: split customization, commands, and mode definition
    into separate files. That would add load-path and packaging complexity
    before the package has behavior worth separating.

- Make public commands interactive placeholders.

  - Rationale: users and later changes can rely on stable command names, while
    the first change avoids implementing behavior that belongs to later
    proposals.
  - Alternative considered: omit commands until each feature is implemented.
    That would make later specs less clear and would delay establishing the
    command surface.

- Require mode enable/disable to do no expensive work.

  - Rationale: the design goal is to keep editing responsive. The skeleton
    should not introduce hooks, timers, overlays, or asynchronous work before
    those behaviors have explicit specs.
  - Alternative considered: initialize future state eagerly. That is deferred to
    the diagnostic state change.

## Risks / Trade-offs

- Placeholder commands may be mistaken for implemented behavior. -> Mitigate by
  making each command report that it is not implemented yet.
- The initial customization variables may need refinement later. -> Keep them
  minimal and compatible with the planned pipeline.
- No formal ERT suite exists yet. -> Use a batch Emacs smoke check in this
  change and add broader ERT coverage in the later validation change.
