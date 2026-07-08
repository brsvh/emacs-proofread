## Context

`add-paragraph-chunking` establishes paragraph chunks with exact buffer
boundaries, text, context, and stale-result metadata. Before those chunks are
used for cache lookup or backend request construction, proofread needs a
conservative filter that excludes text users do not want checked and text that
commonly creates low-value diagnostics.

The current package does not yet have a full backend request pipeline, so this
change should introduce the request-ready filtering stage and make that stage
the boundary future cache and backend code must consume.

## Goals / Non-Goals

**Goals:**

- Add user options for ignored faces and ignored text properties.
- Exclude URLs, email addresses, and invisible text by default.
- Filter paragraph chunks before cache lookup or backend request input.
- Keep surrounding ordinary text eligible by splitting chunks around filtered
  ranges.
- Preserve absolute buffer positions and stale-result metadata on produced
  request-ready chunks.
- Keep matching conservative and independent of private state from other
  packages.

**Non-Goals:**

- No project dictionary support.
- No syntax-tree, tree-sitter, or major-mode-specific structural filtering.
- No Chinese part-of-speech filtering or word segmentation.
- No broad natural-language classifier for uncheckable text.
- No dependency on another package's private variables or overlays.

## Decisions

- Filter by splitting chunks around ignored intervals.

  The filter should compute ignored intervals within each paragraph chunk, then
  produce new request-ready chunk plists for the remaining contiguous spans.
  This guarantees filtered text never appears in request input while preserving
  exact buffer boundaries for each retained span. The alternative of replacing
  ignored text with placeholders would require extra position mapping and could
  still send private or noisy content to a backend.

- Keep ignored-face and ignored-property checks buffer-local and property-based.

  Face filtering should inspect the buffer's `face` text property and treat both
  symbol and list face values as candidates. Property filtering should skip text
  where any configured property has a non-nil value. This relies only on public
  Emacs text properties and avoids reading private state from font-lock, org,
  markdown, or other packages.

- Use conservative built-in regex filters for URLs and email addresses.

  URL filtering should target well-bounded scheme URLs such as `http://` and
  `https://`; email filtering should target ordinary address shapes with local
  part, `@`, and a dotted domain. The filter should prefer missing unusual cases
  over matching large natural-language spans.

- Treat `invisible` text as ignored by default.

  Any non-nil `invisible` property inside a chunk should be excluded from
  request-ready chunks. This matches the visible-first workflow and avoids
  sending folded, hidden, or concealed content to a backend.

- Preserve chunk metadata when splitting.

  Request-ready chunks should retain or recompute `:major-mode`, `:language`,
  `:modified-tick`, and bounded context consistently with paragraph chunking.
  Their `:beg`, `:end`, and `:text` must describe the retained buffer span
  exactly. Later cache and backend code can key or validate results using the
  same metadata shape.

## Risks / Trade-offs

- Filtering can split a sentence into small fragments -> Drop whitespace-only
  fragments after filtering and leave richer reconstruction for later request
  scheduling.
- URL and email regexes may miss unusual forms -> Keep patterns conservative to
  avoid deleting large ordinary text spans.
- Face properties can be complex -> Support common symbol and list forms, and
  document broader display-derived filtering as out of scope.
- Cache/backend code may not exist yet -> Add a single request-ready filtering
  helper and make future cache/backend entry points consume it before lookup or
  dispatch.
