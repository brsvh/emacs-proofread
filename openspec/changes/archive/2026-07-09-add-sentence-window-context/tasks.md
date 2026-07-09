## 1. Configuration and Existing Tests

- [x] 1.1 Add `proofread-context-sentences-before` and
  `proofread-context-sentences-after` defcustoms with default value `1`,
  `natnum` type, and documentation that `0` disables that direction.
- [x] 1.2 Audit existing context tests and update assertions or bindings so they
  intentionally exercise sentence-window context or bounded character fallback.
- [x] 1.3 Keep paragraph-level chunk metadata behavior compatible where it is
  still intermediate-only.

## 2. Context Boundary Helpers

- [x] 2.1 Add helpers that find the nearest context search stop before and after
  a request-ready chunk without using visual lines, screen lines, or window
  columns.
- [x] 2.2 Treat blank lines as context search stops.
- [x] 2.3 Add conservative Org structural stop detection for headings,
  keyword/metadata lines, property drawers, list items, table rows, and block
  delimiters/content.
- [x] 2.4 Add sentence span collection inside a bounded context region using the
  existing proofread-owned sentence boundary wrapper.
- [x] 2.5 Merge adjacent context spans when the only boundary between them is a
  single hard-wrap newline that is not also a structural stop.

## 3. Sentence-Window Context Generation

- [x] 3.1 Implement before-context selection from the nearest complete preceding
  logical sentences, preserving original buffer order.
- [x] 3.2 Implement after-context selection from the nearest complete following
  logical sentences.
- [x] 3.3 Honor `proofread-context-sentences-before` and
  `proofread-context-sentences-after`, including empty context when either value
  is `0`.
- [x] 3.4 Enforce `proofread-context-size` by reducing included sentence count
  before using any partial context.
- [x] 3.5 Use bounded character-window fallback when the nearest single context
  sentence exceeds `proofread-context-size`.
- [x] 3.6 Fall back to the existing bounded character-window behavior when
  sentence boundary support is unavailable, fails, does not move, or yields no
  useful context spans.
- [x] 3.7 Apply ignored URL, email, invisible, ignored-face, and
  ignored-property filtering to selected context spans without changing request
  `:text`.
- [x] 3.8 Route `proofread--request-ready-context-before` and
  `proofread--request-ready-context-after` through the new sentence-window
  helpers.

## 4. Request Integrity and Cache Identity

- [x] 4.1 Preserve exact request-ready `:text`, `:beg`, and `:end` behavior for
  all context strategies.
- [x] 4.2 Verify diagnostic ranges remain relative only to request `:text` and
  cannot address context fields.
- [x] 4.3 Add stable context identity or context content hashes to
  `proofread--cache-key`.
- [x] 4.4 Ensure cache keys distinguish context strategy, before/after sentence
  counts, `proofread-context-size`, and selected context content.
- [x] 4.5 Ensure context-aware cache keys continue to exclude buffer objects,
  callback objects, provider objects, token lists, and secrets.

## 5. Offline Test Coverage

- [x] 5.1 Add ERT coverage for default one-sentence `:context-before`.
- [x] 5.2 Add ERT coverage for default one-sentence `:context-after`.
- [x] 5.3 Add ERT coverage for configured before/after sentence counts greater
  than `1`.
- [x] 5.4 Add ERT coverage for `0` before or after sentence counts producing
  empty context.
- [x] 5.5 Add ERT coverage that hard-wrapped Chinese prose does not split
  context at a single non-structural newline and still preserves real newlines.
- [x] 5.6 Add ERT coverage that `visual-line-mode` and soft-wrap/window width
  changes do not alter context for the same buffer range.
- [x] 5.7 Add ERT coverage that blank lines stop context search.
- [x] 5.8 Add ERT coverage that Org headings, metadata, lists, tables, and
  blocks stop context search.
- [x] 5.9 Add ERT coverage that ignored URL, email, invisible, ignored-face, and
  ignored-property text is excluded from context.
- [x] 5.10 Add ERT coverage for oversized single-sentence context using bounded
  fallback without changing request `:text`.
- [x] 5.11 Add ERT coverage for sentence-boundary failure or unavailability
  falling back to character-window context.
- [x] 5.12 Add ERT coverage that context strategy, configuration, and content
  changes cause cache misses.
- [x] 5.13 Add ERT coverage that accepted diagnostics and overlays do not drift
  when context is present.

## 6. Validation

- [x] 6.1 Byte-compile or batch-load `lisp/proofread.el` in a clean Emacs
  environment.
- [x] 6.2 Run the repository's offline proofread ERT suite through the flake,
  preferring `nix run .#emacs30-run-proofread-tests`.
- [x] 6.3 Run the Emacs 31 proofread test package when available with
  `nix run .#emacs31-run-proofread-tests`.
- [x] 6.4 Confirm no tests require real LLM providers, DeepSeek, Ollama, or
  network access.
