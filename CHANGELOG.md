# ChangeLog

This file records notable user-visible changes to `proofread` and
`proofread-popup`. For detailed development history, see the Git log.

## Unreleased

### `proofread`

#### Added

- Add a local LanguageTool backend with asynchronous HTTP requests, safe UTF-16
  offset conversion, configurable language and rule selection, request timeouts,
  and optional management of a session-local LanguageTool server. LanguageTool
  remains an optional runtime dependency used only by this backend.
- Add a backend registry with lazy loading, backend-specific cache identities,
  and backend-specific request cancellation.

#### Changed

- Move the package sources into `lisp/proofread/` and split the implementation
  into `proofread.el`, `proofread-llm.el`, and `proofread-languagetool.el`. Move
  the optional popup package into `lisp/proofread-popup/`.
- Keep backend-private functions and variables under their feature namespaces,
  and centralize shared callback scheduling and position conversion in the core
  library.
- Split core, LLM, and LanguageTool tests into independent suites, and align
  backend test symbols with their feature namespaces.
- Stop loading GNU ELPA `llm` from the core library until the LLM backend is
  selected or required explicitly.

### Packaging

#### Changed

- Include all three Proofread source files in Make and Nix package builds,
  source archives, strict byte compilation, and clean-install verification.
- Provide the pinned Nixpkgs LanguageTool HTTP server, with a local sentence
  cache, only in repository development shells, test runners, and Emacs
  launchers; keep the Emacs package independent of Nix and Java runtimes.

## v0.1.0 - 2026-07-13

Initial release.

### `proofread`

#### Added

- Provide asynchronous, context-aware proofreading through provider objects from
  the GNU ELPA `llm` package.
- Support provider-enforced JSON schema responses and prompt-only JSON
  responses, with automatic selection based on provider capabilities.
- Check visible text automatically after idle time, and provide explicit
  commands for checking the text at point, the active region, the accessible
  buffer, or all visible ranges.
- Select ordinary text, comments, or docstrings with mode-aware defaults, while
  excluding URLs, email addresses, invisible text, configured faces, and
  configured text properties.
- Split prose into bounded, sentence-aware requests with configurable
  surrounding context.
- Display diagnostics with overlays and provide commands for navigation,
  detailed descriptions, and a tabulated buffer-wide diagnostic list.
- Correct individual diagnostics or scoped groups of diagnostics. Batch
  corrections are applied atomically as one undo step and roll back on failure.
- Ignore semantically identical diagnostics for the current Emacs session.
- Cache diagnostics per buffer, queue requests behind a configurable concurrency
  limit, reject stale results after edits, and preserve usable results when only
  part of a check fails.
- Record and inspect complete request lifecycles on demand, including queued,
  active, completed, failed, and stale requests.

### `proofread-popup`

#### Added

- Provide an optional Posframe frontend that displays the diagnostic at point in
  a child frame.
- Follow `proofread-mode` automatically while allowing popup display to be
  disabled per buffer.
- Support customizable popup width, text appearance, and border appearance.

### Packaging

#### Added

- Provide independently buildable, ELPA-compatible source archives for
  `proofread` and `proofread-popup`.
- Provide Nix packages, development environments, and clean batch test runners
  for supported Emacs versions.
- Require GNU Emacs 30.1 and `llm` 0.31.1 for `proofread`; additionally require
  `proofread` 0.1.0 and `posframe` 1.5.2 for `proofread-popup`.
