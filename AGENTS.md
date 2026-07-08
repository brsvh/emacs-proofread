# README for Agents

## Commits

When creating a commit, use the `commit` skill. Load
`.agents/skills/commit/SKILL.md`, follow its required staged-diff inspection
workflow, and write the commit message in the required GNU-style format.

## Emacs Lisp

When writing, editing, reviewing, or refactoring `.el` files, use the
`emacs-lisp-coding` skill first. Load
`.agents/skills/emacs-lisp-coding/SKILL.md` and its referenced style guide, then
follow that workflow for style, formatting, and validation.

## Emacs Evaluation and Tests

When Nix is available, evaluate and test this project through the packages
provided by this project's flake so Emacs runs with a completely clean init
directory. Prefer commands such as
`nix run .#emacs30-with-proofread -- --batch --eval ...` for evaluation and
`nix run .#emacs30-run-proofread-tests` or
`nix run .#emacs31-run-proofread-tests` for tests.

When Nix is not available, fall back to the system `emacs`, still using batch
mode and a temporary clean init directory where possible.

## Nix Code

When writing, editing, reviewing, or refactoring `.nix` files, use the
`nix-coding` skill first. Load `.agents/skills/nix-coding/SKILL.md` and its
referenced style guide, then follow that workflow for style, formatting, and
validation.
