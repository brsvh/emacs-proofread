## 1. Filter Configuration

- [x] 1.1 Add `proofread-ignored-faces` as a user option for face-based
  pre-request filtering.
- [x] 1.2 Add `proofread-ignored-properties` as a user option for
  text-property-based pre-request filtering.
- [x] 1.3 Document option behavior so ignored faces and properties are matched
  through public Emacs text properties only.

## 2. Ignored Range Detection

- [x] 2.1 Add conservative ignored-range detection for `http://` and `https://`
  URLs inside chunk boundaries.
- [x] 2.2 Add conservative ignored-range detection for email addresses inside
  chunk boundaries.
- [x] 2.3 Add ignored-range detection for configured faces, supporting symbol
  and list values in the `face` text property.
- [x] 2.4 Add ignored-range detection for configured text properties with
  non-nil values.
- [x] 2.5 Add default ignored-range detection for non-nil `invisible` text
  properties.
- [x] 2.6 Normalize ignored ranges so overlapping or adjacent filtered spans are
  merged before splitting chunks.

## 3. Request-Ready Chunk Filtering

- [x] 3.1 Add an internal helper that filters paragraph chunks into
  request-ready chunks before cache/backend input.
- [x] 3.2 Split chunks around ignored ranges and drop empty or whitespace-only
  retained spans.
- [x] 3.3 Preserve retained chunks' absolute `:beg`, `:end`, exact `:text`,
  context, `:major-mode`, language, and `:modified-tick` metadata.
- [x] 3.4 Ensure filtered text is absent from request-ready chunk text while
  ordinary text outside filtered spans remains eligible.

## 4. Cache/Backend Boundary

- [x] 4.1 Ensure any current chunk-to-cache or chunk-to-backend entry point
  consumes request-ready filtered chunks rather than raw paragraph chunks.
- [x] 4.2 If cache/backend entry points are not implemented yet, expose a single
  internal request-ready chunk helper as the required future boundary.
- [x] 4.3 Add tests or focused helper assertions proving filtering happens
  before cache/backend input text is produced.

## 5. Tests

- [x] 5.1 Add ERT coverage that URL text is excluded and surrounding text
  remains request-ready.
- [x] 5.2 Add ERT coverage that email address text is excluded and surrounding
  text remains request-ready.
- [x] 5.3 Add ERT coverage for `proofread-ignored-faces`.
- [x] 5.4 Add ERT coverage for `proofread-ignored-properties`.
- [x] 5.5 Add ERT coverage for invisible text filtering.
- [x] 5.6 Add ERT coverage that retained filtered chunks preserve exact buffer
  text and stale-result metadata.

## 6. Validation

- [x] 6.1 Run the project proofread ERT test package through the flake-provided
  Emacs test command.
- [x] 6.2 Run OpenSpec status or validation for `add-pre-request-filtering` and
  confirm the change is apply-ready.
