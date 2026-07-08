## Why

Paragraph chunks will become the unit sent to proofreading backends and cache
lookups, so unsuitable text must be removed before those paths see it. Adding a
conservative pre-request filter now reduces backend cost and avoids predictable
false positives for links, addresses, hidden text, and user-marked regions.

## What Changes

- Add customizable `proofread-ignored-faces` for skipping text with configured
  faces.
- Add customizable `proofread-ignored-properties` for skipping text with
  configured text properties.
- Add built-in filtering for URLs, email addresses, and invisible text.
- Add an internal filtering stage for paragraph chunks before they become cache
  lookup or backend request input.
- Preserve conservative behavior: filter only well-bounded matches or explicitly
  configured faces/properties.
- Do not add project dictionaries, syntax-tree filtering, Chinese part-of-speech
  filtering, or dependencies on private state from other packages.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Add pre-request filtering so filtered text is excluded
  before chunk content reaches cache lookup or backend request construction.

## Impact

- Affects `lisp/proofread.el` chunk filtering helpers and the future
  chunk-to-cache/backend path.
- Adds ERT coverage in `test/proofread-tests.el` for URL, email,
  `proofread-ignored-faces`, `proofread-ignored-properties`, invisible text, and
  ordering before cache/backend input.
- Depends on `add-paragraph-chunking` for chunk metadata and exact buffer
  boundaries.
- Adds no runtime dependency, project dictionary behavior, tree-sitter parsing,
  or language-specific token filtering.
