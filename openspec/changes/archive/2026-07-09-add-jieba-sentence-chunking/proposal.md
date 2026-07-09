## Why

Paragraph-level chunks can still send long Chinese prose blocks to local LLMs,
which increases latency and makes chunk-relative diagnostic ranges harder for
small models to return accurately. Sentence-level chunks give proofread a
smaller request unit while preserving the existing stale-result, cache, parser,
and overlay pipeline.

## What Changes

- Add sentence-level chunk construction inside existing paragraph spans.
- Use the `emacs-jieba-rs` package's Chinese sentence boundary behavior, via
  `jieba-rs-forward-sentence` or an equivalent wrapper, when available.
- Keep paragraph chunking as the fallback when sentence boundary support is not
  available or does not produce useful boundaries.
- Keep `proofread-max-chunk-size` as a hard upper bound: a single oversized
  sentence is still split into stable bounded chunks.
- Keep the chunk plist shape unchanged, including `:beg`, `:end`, `:text`,
  `:major-mode`, `:language`, `:context-before`, `:context-after`, and
  `:modified-tick`.
- Do not change backend dispatch, LLM prompt structure, JSON diagnostic parsing,
  cache value shape, stale-result rejection, or overlay behavior.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Request chunk construction should split Chinese visible
  paragraph text into sentence-level chunks before backend dispatch, with
  paragraph chunking as a safe fallback.

## Impact

- Affects chunking helpers in `lisp/proofread.el`.
- Adds or uses the `jieba-rs` Emacs Lisp package dependency in package metadata
  and Nix Emacs package/test environments.
- Adds ERT coverage in `test/proofread-tests.el` for sentence chunking, fallback
  behavior, oversized sentence splitting, metadata/context preservation,
  filtering compatibility, and request dispatch using smaller chunks.
