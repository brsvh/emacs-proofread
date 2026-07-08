## 1. Package Skeleton

- [ ] 1.1 Create `lisp/proofread.el` with package headers, copyright, lexical
  binding, commentary, code section, and `(provide 'proofread)`.
- [ ] 1.2 Define the `proofread` customization group and initial customization
  variables for language, idle delay, chunk size, context size, concurrency, and
  backend selection.
- [ ] 1.3 Define buffer-local `proofread-mode` without creating overlays,
  timers, requests, cache entries, hooks, or text changes.

## 2. Public Commands

- [ ] 2.1 Add placeholder interactive commands for `proofread-check-visible`,
  `proofread-check-buffer`, `proofread-next`, `proofread-previous`,
  `proofread-describe`, `proofread-apply-suggestion`, `proofread-ignore`, and
  `proofread-clear`.
- [ ] 2.2 Ensure placeholder commands report that behavior is not implemented
  yet and do not modify buffer text.

## 3. Validation

- [ ] 3.1 Verify `proofread.el` loads in batch Emacs with `lisp` on `load-path`.
- [ ] 3.2 Verify all public command symbols are interactive commands after
  loading the package.
- [ ] 3.3 Verify enabling and disabling `proofread-mode` in a temporary text
  buffer does not change text and does not create overlays.
