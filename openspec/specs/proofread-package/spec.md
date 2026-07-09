## Purpose

Define the initial loadable Emacs Lisp package surface for `proofread-mode`.

## Requirements

### Requirement: Loadable proofread package

The system SHALL provide a loadable Emacs Lisp package file at
`lisp/proofread.el`.

#### Scenario: Package loads in batch Emacs

- **WHEN** Emacs is run in batch mode with `lisp` on `load-path`
- **THEN** requiring `proofread` succeeds without errors

#### Scenario: Package provides feature

- **WHEN** `proofread.el` is loaded
- **THEN** the `proofread` feature is provided

### Requirement: Buffer-local proofread minor mode

The system SHALL define `proofread-mode` as a buffer-local minor mode.

#### Scenario: Enable mode in a text buffer

- **WHEN** `proofread-mode` is enabled in a buffer
- **THEN** the mode is active in that buffer

#### Scenario: Disable mode in a text buffer

- **WHEN** `proofread-mode` is disabled in a buffer where it is active
- **THEN** the mode is no longer active in that buffer

#### Scenario: Enabling mode has no proofreading side effects

- **WHEN** `proofread-mode` is enabled in a buffer containing text
- **THEN** the buffer text remains unchanged
- **AND** no proofread overlays, timers, requests, or cache entries are created

### Requirement: Public command surface

The system SHALL define interactive command entry points for the planned
proofreading workflow.

#### Scenario: Public commands are interactive

- **WHEN** the package is loaded
- **THEN** `proofread-check-visible`, `proofread-check-buffer`,
  `proofread-next`, `proofread-previous`, `proofread-describe`,
  `proofread-apply-suggestion`, `proofread-ignore`, and `proofread-clear` are
  interactive commands

#### Scenario: Placeholder commands do not modify text

- **WHEN** any placeholder command is invoked in a text buffer
- **THEN** the command reports that behavior is not implemented yet
- **AND** the buffer text remains unchanged

### Requirement: Diagnostic plist representation

The system SHALL represent proofread diagnostics as structured plist data that
can exist independently from overlay objects.

#### Scenario: Diagnostic contains required fields

- **WHEN** proofread code constructs a diagnostic
- **THEN** the diagnostic can contain `:beg`, `:end`, `:text`, `:kind`,
  `:message`, `:suggestions`, `:confidence`, and `:source`

#### Scenario: Diagnostic does not require overlay ownership

- **WHEN** a diagnostic is created before display behavior exists
- **THEN** the diagnostic remains usable without requiring an overlay object

### Requirement: Buffer-local proofread state

The system SHALL maintain proofread-owned state separately for each buffer where
`proofread-mode` is enabled.

#### Scenario: Enabling mode initializes proofread state

- **WHEN** `proofread-mode` is enabled in a buffer
- **THEN** proofread-owned buffer-local state is initialized for diagnostics,
  overlays, pending ranges, requests, and cache

#### Scenario: State does not leak across buffers

- **WHEN** `proofread-mode` is enabled in two buffers
- **THEN** each buffer has independent proofread-owned state

#### Scenario: Disabling mode clears proofread state

- **WHEN** `proofread-mode` is disabled in a buffer
- **THEN** proofread-owned buffer-local diagnostics, overlays, pending ranges,
  requests, and cache state are cleared in that buffer

#### Scenario: Disabling mode preserves unrelated state

- **WHEN** `proofread-mode` is disabled in a buffer that has unrelated mode
  state or overlays
- **THEN** only proofread-owned buffer-local state is cleared

### Requirement: Theme-compatible proofread faces

The system SHALL define package-owned faces for normal and current proofread
diagnostics without hard-coded color values or spelling-package face reuse.

#### Scenario: Proofread faces are available

- **WHEN** the package is loaded
- **THEN** `proofread-face` is a defined face
- **AND** `proofread-current-face` is a defined face

#### Scenario: Proofread faces avoid fixed colors

- **WHEN** the default face specifications are inspected
- **THEN** they do not hard-code color values
- **AND** they do not reuse another spelling or diagnostic package's face as the
  proofread face

### Requirement: Proofread-owned diagnostic overlays

The system SHALL display diagnostics using proofread-owned overlays that remain
separate from the canonical diagnostic data.

#### Scenario: Overlay stores diagnostic metadata

- **WHEN** proofread creates an overlay for a diagnostic
- **THEN** the overlay has category `proofread-overlay`
- **AND** the overlay stores the diagnostic in its `proofread-diagnostic`
  property
- **AND** the diagnostic remains available outside the overlay object

#### Scenario: Overlay display is isolated from other packages

- **WHEN** proofread creates an overlay
- **THEN** the overlay does not reuse another spelling or diagnostic package's
  category, keymap, face, or modification hook

### Requirement: Proofread overlay cleanup

The system SHALL clear only proofread-owned overlays in the current buffer.

#### Scenario: Clear deletes proofread overlays

- **WHEN** `proofread-clear` is invoked in a buffer containing proofread-owned
  overlays
- **THEN** proofread-owned overlays in that buffer are deleted
- **AND** proofread overlay state for that buffer is cleared

#### Scenario: Clear preserves unrelated overlays

- **WHEN** `proofread-clear` is invoked in a buffer containing overlays from
  another package or category
- **THEN** unrelated overlays remain live

### Requirement: Proofread overlay edit invalidation

The system SHALL remove or invalidate proofread-owned overlays when their
covered text is modified.

#### Scenario: Editing covered text invalidates proofread overlay

- **WHEN** text covered by a proofread-owned overlay is modified
- **THEN** that overlay is deleted or marked invalid
- **AND** no backend request is scheduled by the modification hook

#### Scenario: Editing covered text preserves unrelated overlays

- **WHEN** text covered by an unrelated overlay is modified
- **THEN** proofread overlay invalidation does not delete that unrelated overlay

### Requirement: Visible range discovery

The system SHALL collect normalized visible text ranges for the current buffer
when `proofread-check-visible` is invoked.

#### Scenario: Single visible window range is collected

- **WHEN** `proofread-check-visible` is invoked in a buffer displayed by one
  live window
- **THEN** proofread pending range state contains the visible range from that
  window
- **AND** no backend request, timer, cache entry, or diagnostic overlay is
  created

#### Scenario: Multiple visible window ranges are deduplicated

- **WHEN** `proofread-check-visible` is invoked in a buffer displayed by
  multiple live windows
- **THEN** proofread pending range state contains sorted visible ranges for that
  buffer
- **AND** overlapping or adjacent ranges are merged so the same text is not
  represented more than once

#### Scenario: No visible window produces no ranges

- **WHEN** `proofread-check-visible` is invoked in a buffer that is not
  displayed by any live window
- **THEN** proofread pending range state is empty
- **AND** the command does not fall back to the whole buffer

#### Scenario: Invisible buffer text is not scanned

- **WHEN** `proofread-check-visible` is invoked in a large buffer with only part
  of the buffer visible
- **THEN** proofread range discovery uses live window boundaries for the current
  buffer
- **AND** text outside the collected visible ranges is not traversed for
  proofreading work by this command

### Requirement: Paragraph chunk construction

The system SHALL construct bounded paragraph-level proofreading chunks from
visible buffer ranges.

#### Scenario: Ordinary paragraph creates a chunk

- **WHEN** proofread chunking receives a visible range containing one nonblank
  paragraph shorter than `proofread-max-chunk-size`
- **THEN** it produces one chunk for that paragraph
- **AND** the chunk records absolute `:beg` and `:end` buffer positions
- **AND** the chunk `:text` content exactly matches the buffer text between
  `:beg` and `:end`

#### Scenario: Whitespace-only paragraphs are skipped

- **WHEN** proofread chunking receives a visible range containing empty text or
  only whitespace paragraphs
- **THEN** it produces no chunks for that text

#### Scenario: Oversized paragraph is split into bounded chunks

- **WHEN** proofread chunking receives a paragraph longer than
  `proofread-max-chunk-size`
- **THEN** it splits that paragraph into multiple chunks
- **AND** every produced chunk has text length less than or equal to
  `proofread-max-chunk-size`
- **AND** the chunks use stable, contiguous absolute buffer ranges for the
  original paragraph text

#### Scenario: Chunk records asynchronous validation metadata

- **WHEN** proofread chunking produces a chunk
- **THEN** the chunk records the buffer's `major-mode`
- **AND** the chunk records the configured proofread language
- **AND** the chunk records bounded surrounding context
- **AND** the chunk records the buffer's `buffer-chars-modified-tick`

#### Scenario: Chunking does not mutate buffer contents

- **WHEN** proofread chunking is run for visible ranges in a buffer
- **THEN** the buffer text remains unchanged
- **AND** existing text properties in the buffer remain unchanged
- **AND** no backend request, timer, cache entry, diagnostic, or overlay is
  created by chunking

### Requirement: Pre-request chunk filtering

The system SHALL exclude ignored text from proofreading chunks before cache
lookup or backend request construction.

#### Scenario: URL text is excluded by default

- **WHEN** request-ready chunks are built from a paragraph chunk containing an
  `http://` or `https://` URL
- **THEN** no request-ready chunk text contains that URL
- **AND** ordinary text outside the URL remains eligible for proofreading

#### Scenario: Email address text is excluded by default

- **WHEN** request-ready chunks are built from a paragraph chunk containing an
  email address
- **THEN** no request-ready chunk text contains that email address
- **AND** ordinary text outside the email address remains eligible for
  proofreading

#### Scenario: Ignored face text is excluded

- **WHEN** `proofread-ignored-faces` contains a face used by text inside a
  paragraph chunk
- **THEN** request-ready chunks exclude the text with that face
- **AND** filtering uses public text properties rather than another package's
  private state

#### Scenario: Ignored property text is excluded

- **WHEN** `proofread-ignored-properties` contains a text property with a
  non-nil value inside a paragraph chunk
- **THEN** request-ready chunks exclude the text carrying that property
- **AND** ordinary text outside that property span remains eligible for
  proofreading

#### Scenario: Invisible text is excluded by default

- **WHEN** request-ready chunks are built from a paragraph chunk containing text
  with a non-nil `invisible` property
- **THEN** no request-ready chunk text contains the invisible text
- **AND** ordinary visible text in the same paragraph remains eligible for
  proofreading

#### Scenario: Filtering happens before cache and backend input

- **WHEN** chunks are prepared for cache lookup or backend request construction
- **THEN** the filtering stage runs before cache lookup
- **AND** the filtering stage runs before backend request construction
- **AND** filtered spans are absent from the cache/backend input text

#### Scenario: Filtering preserves retained chunk metadata

- **WHEN** filtering splits a paragraph chunk around ignored text
- **THEN** each retained request-ready chunk records absolute `:beg` and `:end`
  buffer positions
- **AND** each retained chunk `:text` exactly matches the buffer text between
  `:beg` and `:end`
- **AND** each retained chunk preserves stale-result metadata needed for later
  validation

### Requirement: Backend protocol

The system SHALL define a chunk-oriented backend protocol for proofreading
requests and asynchronous completion callbacks.

#### Scenario: Backend availability is queryable

- **WHEN** the package is loaded
- **THEN** `proofread-backend-available-p` can be called for a backend
- **AND** it reports whether that backend can accept proofreading requests

#### Scenario: Backend receives request plist

- **WHEN** proofread dispatches a chunk to a backend
- **THEN** `proofread-backend-check` receives a request plist
- **AND** the request plist contains the buffer, range boundaries, text,
  context, language, `major-mode`, and `buffer-chars-modified-tick`
- **AND** the request represents a region or chunk rather than a single word

#### Scenario: Successful backend callback returns diagnostics

- **WHEN** a backend completes a request successfully
- **THEN** it invokes the callback with a result that identifies successful
  completion
- **AND** the result includes the original request
- **AND** the result includes a diagnostics list

#### Scenario: Backend error callback returns error result

- **WHEN** a backend fails a request
- **THEN** it invokes the callback with a result that identifies error
  completion
- **AND** the result includes the original request
- **AND** the result includes error information

### Requirement: Asynchronous mock backend

The system SHALL provide a mock backend that follows the backend protocol and
completes asynchronously.

#### Scenario: Mock backend is available

- **WHEN** backend availability is queried for the mock backend
- **THEN** the mock backend reports available

#### Scenario: Mock backend success is asynchronous

- **WHEN** `proofread-backend-check` is called with the mock backend and a
  successful request
- **THEN** the callback is not invoked inline before `proofread-backend-check`
  returns
- **AND** the callback is invoked asynchronously with a successful result

#### Scenario: Mock backend error is asynchronous

- **WHEN** `proofread-backend-check` is called with the mock backend and a
  request configured to fail
- **THEN** the callback is not invoked inline before `proofread-backend-check`
  returns
- **AND** the callback is invoked asynchronously with an error result

### Requirement: Backend request cleanup

The system SHALL remove active request state after backend completion without
modifying buffer text on errors.

#### Scenario: Successful callback clears active request

- **WHEN** an active backend request completes successfully
- **THEN** that request is removed from proofread active request state

#### Scenario: Error callback clears active request without modifying buffer

- **WHEN** an active backend request completes with an error
- **THEN** that request is removed from proofread active request state
- **AND** the buffer text remains unchanged
- **AND** no stale request entry remains for that failed request

### Requirement: Request dispatch from visible chunks

The system SHALL dispatch request-ready visible chunks through the configured
backend protocol.

#### Scenario: Visible check dispatches request-ready chunks

- **WHEN** `proofread-check-visible` is invoked in a buffer with
  `proofread-mode` enabled and an available backend configured
- **THEN** proofread collects the current visible ranges
- **AND** proofread builds request-ready chunks from those ranges
- **AND** proofread dispatches chunk-level backend requests for those chunks

#### Scenario: Active requests are buffer-local

- **WHEN** proofread dispatches backend requests in a buffer
- **THEN** each in-flight request is recorded in that buffer's active request
  state
- **AND** active requests from another buffer are not mixed with that state

#### Scenario: Request snapshot records stale-check metadata

- **WHEN** proofread dispatches a backend request for a chunk
- **THEN** the request snapshot contains the buffer, range boundaries, chunk
  text, `major-mode`, language, and `buffer-chars-modified-tick`
- **AND** the snapshot is sufficient to validate the callback result before
  applying diagnostics

### Requirement: Fresh backend result application

The system SHALL apply backend diagnostics only after validating that the
request still matches the current buffer state.

#### Scenario: Fresh successful diagnostics are accepted

- **WHEN** a successful backend result containing diagnostics returns for a live
  buffer where `proofread-mode` is still enabled
- **AND** the buffer modified tick matches the request snapshot
- **AND** the request range is still valid
- **AND** the buffer text at the request range still equals the request text
- **THEN** proofread records the result diagnostics in proofread-owned state
- **AND** proofread creates proofread-owned overlays for those diagnostics

#### Scenario: Backend error result does not modify buffer text

- **WHEN** a backend request completes with an error result
- **THEN** proofread removes the active request entry for that request
- **AND** proofread does not modify buffer text
- **AND** proofread does not create diagnostic overlays from the error result

### Requirement: Stale backend result rejection

The system SHALL reject backend results that no longer match the originating
buffer state.

#### Scenario: Killed buffer rejects result

- **WHEN** a backend result returns after the originating buffer has been killed
- **THEN** proofread drops the result
- **AND** no proofread overlay is created
- **AND** no buffer-local proofread state is recreated for the killed buffer

#### Scenario: Disabled mode rejects result

- **WHEN** a backend result returns after `proofread-mode` has been disabled in
  the originating buffer
- **THEN** proofread drops the result
- **AND** no proofread overlay is created
- **AND** no proofread-owned buffer state is changed

#### Scenario: Modified tick rejects result

- **WHEN** a backend result returns after the originating buffer's
  `buffer-chars-modified-tick` differs from the request snapshot
- **THEN** proofread drops the result
- **AND** no proofread overlay is created
- **AND** proofread-owned diagnostic state is not updated from that result

#### Scenario: Text mismatch rejects result

- **WHEN** a backend result returns while the originating buffer is live and
  `proofread-mode` is enabled
- **AND** the buffer text at the request range no longer equals the request text
- **THEN** proofread drops the result
- **AND** no proofread overlay is created
- **AND** proofread-owned diagnostic state is not updated from that result

#### Scenario: Stale result cleanup removes active request

- **WHEN** proofread rejects a stale backend result for a live buffer
- **THEN** the active request entry for that request is removed
- **AND** no stale request entry remains for the rejected result

### Requirement: Idle scheduling for proofreading work

The system SHALL schedule visible proofreading work through idle timers instead
of running backend dispatch synchronously during user activity.

#### Scenario: Editing schedules without synchronous backend dispatch

- **WHEN** text is edited in a buffer where `proofread-mode` is enabled
- **THEN** proofread marks that buffer as having pending visible proofreading
  work
- **AND** proofread schedules or reuses an idle timer based on
  `proofread-idle-delay`
- **AND** proofread does not synchronously call the backend from the edit hook

#### Scenario: Window activity schedules visible check

- **WHEN** window activity affects a buffer where `proofread-mode` is enabled
- **THEN** proofread marks that buffer as having pending visible proofreading
  work
- **AND** proofread schedules or reuses an idle timer based on
  `proofread-idle-delay`
- **AND** proofread does not synchronously call the backend from the window
  activity hook

#### Scenario: Idle callback runs scheduled visible check

- **WHEN** the idle timer fires for a live buffer where `proofread-mode` is
  enabled and pending work remains
- **THEN** proofread clears the pending marker for that scheduled work
- **AND** proofread invokes the visible-check dispatch path for that buffer

### Requirement: Idle scheduling coalesces repeated activity

The system SHALL coalesce repeated activity during the idle delay into one
scheduled visible check per buffer.

#### Scenario: Consecutive edits reuse one scheduled timer

- **WHEN** multiple edits occur in the same `proofread-mode` buffer before the
  idle timer fires
- **THEN** proofread keeps a single pending scheduled check for that buffer
- **AND** proofread does not create one backend dispatch per edit
- **AND** the scheduled visible check runs once after the idle delay when the
  buffer is still eligible

#### Scenario: Activity after idle callback can schedule again

- **WHEN** a scheduled visible check has already run for a buffer
- **AND** later editing or window activity occurs in that buffer
- **THEN** proofread marks the buffer pending again
- **AND** proofread schedules or reuses an idle timer for the later work

### Requirement: Idle scheduling respects mode lifecycle

The system SHALL not process scheduled work for killed buffers or buffers where
`proofread-mode` is no longer enabled.

#### Scenario: Disabling mode clears pending work

- **WHEN** `proofread-mode` is disabled in a buffer with pending scheduled work
- **THEN** proofread clears that buffer's pending work state
- **AND** proofread cancels or invalidates the buffer's idle timer
- **AND** the disabled buffer is not processed by that scheduled work later

#### Scenario: Idle callback ignores killed buffer

- **WHEN** an idle timer callback runs after its target buffer has been killed
- **THEN** proofread drops the scheduled work
- **AND** proofread does not signal an error
- **AND** proofread does not recreate proofread-owned state for the killed
  buffer

#### Scenario: Idle callback rechecks mode state

- **WHEN** an idle timer callback runs for a live buffer where `proofread-mode`
  is no longer enabled
- **THEN** proofread drops the scheduled work
- **AND** proofread does not invoke the visible-check dispatch path
- **AND** proofread does not create backend requests for that buffer

### Requirement: Diagnostic cache keys

The system SHALL build deterministic cache keys for request-ready proofreading
chunks.

#### Scenario: Cache key includes text and environment identity

- **WHEN** proofread builds a cache key for a request-ready chunk
- **THEN** the key contains a hash of the chunk text
- **AND** the key contains the chunk language
- **AND** the key contains the chunk `major-mode`
- **AND** the key contains the selected backend identity
- **AND** the key contains the prompt version
- **AND** the key contains relevant configuration version data

#### Scenario: Backend identity change invalidates cache

- **WHEN** the selected backend identity changes for otherwise identical chunk
  text and metadata
- **THEN** proofread builds a different cache key
- **AND** the old cache entry is not used for the new backend identity

#### Scenario: Prompt version change invalidates cache

- **WHEN** the prompt version changes for otherwise identical chunk text and
  metadata
- **THEN** proofread builds a different cache key
- **AND** the old cache entry is not used for the new prompt version

#### Scenario: Configuration version change invalidates cache

- **WHEN** relevant proofreading configuration version data changes for
  otherwise identical chunk text and metadata
- **THEN** proofread builds a different cache key
- **AND** the old cache entry is not used for the new configuration version data

### Requirement: Diagnostic cache lookup and write

The system SHALL reuse cached diagnostics for unchanged visible text and avoid
duplicate backend requests on cache hits.

#### Scenario: Cache hit skips backend dispatch

- **WHEN** proofread checks a request-ready visible chunk whose cache key
  matches an existing cache entry
- **THEN** proofread reads diagnostics from the cache
- **AND** proofread does not dispatch a backend request for that chunk

#### Scenario: Cache miss dispatches backend request

- **WHEN** proofread checks a request-ready visible chunk whose cache key does
  not match an existing cache entry
- **THEN** proofread dispatches a backend request for that chunk through the
  backend protocol

#### Scenario: Fresh successful result writes cache

- **WHEN** a fresh successful backend result is accepted for a request-ready
  chunk
- **THEN** proofread writes diagnostics for that chunk to the cache
- **AND** the cache value stores diagnostics in chunk-relative form

#### Scenario: Stale or error result is not cached

- **WHEN** a backend result is stale or has error status
- **THEN** proofread does not write diagnostics from that result to the cache

### Requirement: Cached diagnostic application safety

The system SHALL validate cached diagnostics against the current buffer text
before creating overlays or mutating diagnostic state.

#### Scenario: Cached diagnostics validate current text

- **WHEN** proofread reads diagnostics from the cache for a request-ready chunk
- **THEN** proofread validates that the current buffer text for the chunk range
  still equals the chunk text associated with the cache hit
- **AND** proofread applies diagnostics only after that validation succeeds

#### Scenario: Cached diagnostics use current absolute positions

- **WHEN** proofread applies chunk-relative diagnostics from a cache hit
- **THEN** proofread converts those diagnostics to absolute positions for the
  current request range
- **AND** proofread creates overlays only at those current absolute positions

#### Scenario: Text mismatch rejects cached diagnostics

- **WHEN** proofread reads diagnostics from the cache
- **AND** the current buffer text at the request range does not equal the cached
  chunk text
- **THEN** proofread drops the cached diagnostics
- **AND** proofread does not create overlays from that cache entry
- **AND** proofread does not treat that cache entry as a fresh backend result

### Requirement: Diagnostic navigation ordering

The system SHALL provide deterministic ordering for proofread-owned diagnostics
in the current buffer.

#### Scenario: Diagnostics are sorted by range

- **WHEN** proofread sorts diagnostics for navigation
- **THEN** diagnostics are ordered by `:beg` position
- **AND** diagnostics with the same `:beg` are ordered by `:end` position

#### Scenario: Invalid ranges are ignored for navigation

- **WHEN** proofread prepares diagnostics for navigation
- **AND** a diagnostic has missing, invalid, or non-position range data
- **THEN** that diagnostic is not used as a navigation target
- **AND** navigation continues to use valid proofread-owned diagnostics

### Requirement: Current-buffer diagnostic navigation

The system SHALL implement `proofread-next` and `proofread-previous` for
proofread-owned diagnostics in the current buffer.

#### Scenario: Next moves to diagnostic after point

- **WHEN** `proofread-next` is invoked with point before a later proofread
  diagnostic
- **THEN** point moves to the beginning of the nearest later proofread
  diagnostic
- **AND** buffer text remains unchanged

#### Scenario: Previous moves to diagnostic before point

- **WHEN** `proofread-previous` is invoked with point after an earlier proofread
  diagnostic
- **THEN** point moves to the beginning of the nearest earlier proofread
  diagnostic
- **AND** buffer text remains unchanged

#### Scenario: Navigation ignores foreign overlays

- **WHEN** the current buffer contains overlays not owned by proofread
- **THEN** `proofread-next` and `proofread-previous` do not navigate to those
  overlays
- **AND** only proofread-owned diagnostics are used as targets

### Requirement: Diagnostic navigation boundaries

The system SHALL use one no-wrap boundary policy for diagnostic navigation.

#### Scenario: Empty diagnostics report no target

- **WHEN** `proofread-next` or `proofread-previous` is invoked in a buffer with
  no proofread-owned diagnostics
- **THEN** point remains unchanged
- **AND** proofread reports that there is no proofread diagnostic to navigate to

#### Scenario: Next at end reports boundary

- **WHEN** `proofread-next` is invoked with point at or after the last
  proofread-owned diagnostic
- **THEN** point remains unchanged
- **AND** proofread reports that there is no next proofread diagnostic
- **AND** proofread does not wrap to the first diagnostic

#### Scenario: Previous at beginning reports boundary

- **WHEN** `proofread-previous` is invoked with point at or before the first
  proofread-owned diagnostic
- **THEN** point remains unchanged
- **AND** proofread reports that there is no previous proofread diagnostic
- **AND** proofread does not wrap to the last diagnostic

### Requirement: Current diagnostic highlighting

The system SHALL visually distinguish the currently selected proofread
diagnostic without modifying buffer text.

#### Scenario: Navigating marks selected diagnostic current

- **WHEN** `proofread-next` or `proofread-previous` moves to a proofread-owned
  diagnostic
- **THEN** that diagnostic is treated as the current diagnostic
- **AND** its proofread-owned overlay uses `proofread-current-face` or an
  equivalent proofread-owned current diagnostic visual state

#### Scenario: Previous current diagnostic is cleared

- **WHEN** navigation selects a different proofread-owned diagnostic
- **THEN** the previously current diagnostic is no longer visually marked as
  current
- **AND** unrelated overlays remain unchanged

### Requirement: Diagnostic lookup at point

The system SHALL find proofread-owned diagnostics that cover point in the
current buffer.

#### Scenario: Diagnostic at point is found

- **WHEN** point is inside the range of a proofread-owned diagnostic
- **THEN** proofread identifies that diagnostic as the diagnostic at point

#### Scenario: Overlapping diagnostics use stable order

- **WHEN** multiple proofread-owned diagnostics cover point
- **THEN** proofread selects the first covering diagnostic in navigation order
- **AND** navigation order is sorted by `:beg` and then `:end`

#### Scenario: Foreign overlays are ignored

- **WHEN** point is inside an overlay not owned by proofread
- **AND** no proofread-owned diagnostic covers point
- **THEN** proofread does not treat that foreign overlay as a diagnostic at
  point

### Requirement: Diagnostic description command

The system SHALL implement `proofread-describe` for the proofread-owned
diagnostic at point.

#### Scenario: Describe shows diagnostic details

- **WHEN** `proofread-describe` is invoked with point on a proofread-owned
  diagnostic
- **THEN** proofread displays the diagnostic kind
- **AND** proofread displays the diagnostic message
- **AND** proofread displays the original diagnostic text
- **AND** proofread displays suggestions when present
- **AND** proofread displays confidence when present
- **AND** proofread displays source when present

#### Scenario: Describe does not modify source buffer

- **WHEN** `proofread-describe` is invoked with point on a proofread-owned
  diagnostic
- **THEN** the source buffer text remains unchanged
- **AND** proofread-owned diagnostics and overlays in the source buffer remain
  unchanged

#### Scenario: Describe reports no diagnostic at point

- **WHEN** `proofread-describe` is invoked and no proofread-owned diagnostic
  covers point
- **THEN** point remains unchanged
- **AND** proofread reports that there is no proofread diagnostic at point

### Requirement: Diagnostic description formatting

The system SHALL format diagnostic descriptions using stable package-level
diagnostic fields.

#### Scenario: Missing optional fields are handled

- **WHEN** `proofread-describe` displays a diagnostic that lacks optional fields
  such as suggestions, confidence, or source
- **THEN** proofread displays the available diagnostic information
- **AND** proofread does not signal an error because those optional fields are
  missing

#### Scenario: Suggestions keep stored order

- **WHEN** a diagnostic contains multiple suggestions
- **THEN** `proofread-describe` displays those suggestions in the same order as
  stored in the diagnostic

#### Scenario: Description avoids backend-private structures

- **WHEN** `proofread-describe` formats a diagnostic
- **THEN** the displayed description is derived from package-level diagnostic
  fields
- **AND** the display logic does not depend on backend-private result structures

### Requirement: Manual suggestion selection

The system SHALL allow users to manually choose a suggestion for the
proofread-owned diagnostic at point.

#### Scenario: Single suggestion is selected by command invocation

- **WHEN** `proofread-apply-suggestion` is invoked on a proofread-owned
  diagnostic with exactly one suggestion
- **THEN** proofread selects that suggestion for application
- **AND** the selection happens only because the user invoked the command

#### Scenario: Multiple suggestions use completion

- **WHEN** `proofread-apply-suggestion` is invoked on a proofread-owned
  diagnostic with multiple suggestions
- **THEN** proofread prompts the user to choose one suggestion through
  completion
- **AND** completion candidates preserve the diagnostic's suggestion order

#### Scenario: No suggestion reports unavailable

- **WHEN** `proofread-apply-suggestion` is invoked on a proofread-owned
  diagnostic with no suggestions
- **THEN** proofread reports that no suggestion is available
- **AND** buffer text remains unchanged

### Requirement: Suggestion application validation

The system SHALL validate diagnostic state and source text before applying a
suggestion.

#### Scenario: Valid diagnostic text can be replaced

- **WHEN** `proofread-apply-suggestion` is invoked on a proofread-owned
  diagnostic with a selected suggestion
- **AND** the diagnostic has a live proofread-owned overlay
- **AND** the diagnostic range is valid
- **AND** the buffer text in the diagnostic range equals the diagnostic original
  text
- **THEN** proofread replaces only the diagnostic range with the selected
  suggestion

#### Scenario: Stale overlay rejects application

- **WHEN** `proofread-apply-suggestion` is invoked for a diagnostic whose
  proofread-owned overlay is no longer live or valid
- **THEN** proofread refuses to apply the suggestion
- **AND** proofread reports that the diagnostic is stale
- **AND** buffer text remains unchanged

#### Scenario: Text mismatch rejects application

- **WHEN** `proofread-apply-suggestion` is invoked for a diagnostic whose
  current buffer text no longer equals the diagnostic original text
- **THEN** proofread refuses to apply the suggestion
- **AND** proofread reports that the diagnostic text no longer matches
- **AND** buffer text remains unchanged

#### Scenario: Replacement stays within diagnostic range

- **WHEN** proofread applies a selected suggestion
- **THEN** proofread replaces only text between the diagnostic `:beg` and `:end`
  positions
- **AND** text outside that range remains unchanged

### Requirement: Suggestion application cleanup and undo

The system SHALL integrate manual suggestion application with proofread overlay
cleanup and Emacs undo.

#### Scenario: Application creates undo boundary

- **WHEN** proofread applies a selected suggestion
- **THEN** the replacement is recorded as a coherent undoable change
- **AND** undo can restore the original diagnostic text

#### Scenario: Affected proofread overlays are invalidated

- **WHEN** proofread applies a selected suggestion
- **THEN** proofread deletes or marks invalid proofread-owned overlays affected
  by the replaced diagnostic range
- **AND** stale proofread overlays for the replaced text are not left visible

#### Scenario: Foreign overlays are preserved

- **WHEN** proofread applies a selected suggestion in a range that also has
  unrelated overlays
- **THEN** proofread does not delete overlays that are not proofread-owned

#### Scenario: Application is not automatic

- **WHEN** diagnostics are created, described, navigated, cached, or refreshed
- **THEN** proofread does not apply suggestions unless
  `proofread-apply-suggestion` is explicitly invoked

### Requirement: Session-local diagnostic ignore keys

The system SHALL maintain an in-memory ignore list for proofread diagnostics in
the current Emacs session.

#### Scenario: Ignore key uses exact text and kind

- **WHEN** proofread builds an ignore key for a diagnostic
- **THEN** the key contains the diagnostic original text
- **AND** the key contains the diagnostic kind
- **AND** no other diagnostic fields are required for the key

#### Scenario: Exact text and kind match ignored entry

- **WHEN** a diagnostic has the same original text and kind as an ignored
  diagnostic
- **THEN** proofread treats that diagnostic as ignored for the current session

#### Scenario: Different kind does not match ignored entry

- **WHEN** a diagnostic has the same original text as an ignored diagnostic but
  a different kind
- **THEN** proofread does not treat that diagnostic as ignored by that entry

#### Scenario: Different text does not match ignored entry

- **WHEN** a diagnostic has the same kind as an ignored diagnostic but different
  original text
- **THEN** proofread does not treat that diagnostic as ignored by that entry

### Requirement: Ignore command

The system SHALL implement `proofread-ignore` for proofread-owned diagnostics at
point.

#### Scenario: Ignoring diagnostic records ignore entry

- **WHEN** `proofread-ignore` is invoked with point on a proofread-owned
  diagnostic
- **THEN** proofread records an in-memory ignore entry for that diagnostic's
  exact text and kind

#### Scenario: Ignoring diagnostic removes matching proofread overlay

- **WHEN** `proofread-ignore` is invoked with point on a proofread-owned
  diagnostic
- **THEN** proofread removes or invalidates the corresponding proofread-owned
  overlay in the current buffer
- **AND** buffer text remains unchanged

#### Scenario: Ignoring does not remove unrelated diagnostics

- **WHEN** `proofread-ignore` is invoked for one proofread-owned diagnostic
- **THEN** proofread does not remove unrelated proofread diagnostics with
  different text or kind

#### Scenario: Ignoring preserves foreign overlays

- **WHEN** `proofread-ignore` removes or invalidates proofread-owned overlays
- **THEN** overlays not owned by proofread remain live

#### Scenario: No diagnostic at point reports no target

- **WHEN** `proofread-ignore` is invoked and no proofread-owned diagnostic
  covers point
- **THEN** proofread reports that there is no proofread diagnostic at point
- **AND** buffer text remains unchanged

### Requirement: Ignored diagnostic display filtering

The system SHALL filter ignored diagnostics before creating proofread-owned
overlays.

#### Scenario: Ignored diagnostic is not displayed again

- **WHEN** proofread is about to display diagnostics
- **AND** a diagnostic has the same exact text and kind as an ignored entry
- **THEN** proofread filters out that diagnostic before overlay creation
- **AND** no proofread-owned overlay is created for that ignored diagnostic

#### Scenario: Different kind remains displayable

- **WHEN** proofread is about to display a diagnostic with the same text as an
  ignored entry but a different kind
- **THEN** proofread does not filter out that diagnostic because of the ignored
  entry
- **AND** the diagnostic remains eligible for proofread overlay creation

#### Scenario: Different text remains displayable

- **WHEN** proofread is about to display a diagnostic with the same kind as an
  ignored entry but different text
- **THEN** proofread does not filter out that diagnostic because of the ignored
  entry
- **AND** the diagnostic remains eligible for proofread overlay creation

### Requirement: Offline batch validation commands

The project SHALL provide documented commands that validate the proofread
package from the repository root without requiring network access or external
model services.

#### Scenario: Batch ERT command runs offline

- **WHEN** a developer runs the documented batch ERT command from the repository
  root
- **THEN** Emacs loads `test/proofread-tests.el` in batch mode
- **AND** the tests use local fixtures or the mock backend
- **AND** the command does not require a real backend, network access, or model
  service

#### Scenario: Batch ERT command uses clean Emacs state

- **WHEN** the documented batch ERT command starts Emacs
- **THEN** Emacs uses a temporary or otherwise clean init directory
- **AND** user init files are not required for the tests to pass

#### Scenario: Byte compilation validates package symbols

- **WHEN** the documented byte-compilation validation is run for
  `lisp/proofread.el`
- **THEN** byte compilation finishes successfully
- **AND** the output contains no warnings indicating missing functions or
  missing variables owned by the proofread package

#### Scenario: Formatting validation remains runnable

- **WHEN** the documented formatting validation command or hook is run
- **THEN** formatting validation completes successfully for the changed
  proofread package files

### Requirement: Core proofreading behavior test coverage

The project SHALL include ERT coverage for the first complete proofread
diagnostic workflow.

#### Scenario: Chunking behavior is covered

- **WHEN** the ERT suite runs
- **THEN** it verifies ordinary paragraph chunking
- **AND** it verifies whitespace-only text produces no chunks
- **AND** it verifies oversized paragraphs split into bounded chunks
- **AND** it verifies chunk text exactly matches the recorded buffer range

#### Scenario: Pre-request filtering behavior is covered

- **WHEN** the ERT suite runs
- **THEN** it verifies URL filtering before backend requests
- **AND** it verifies email filtering before backend requests
- **AND** it verifies ignored face filtering before backend requests
- **AND** it verifies ignored property filtering before backend requests
- **AND** it verifies invisible text filtering before backend requests

#### Scenario: Asynchronous stale result rejection is covered

- **WHEN** the ERT suite runs
- **THEN** it verifies stale results from killed buffers do not create overlays
- **AND** it verifies stale results after `proofread-mode` is disabled do not
  create overlays or modify buffer state
- **AND** it verifies stale results after buffer tick changes are rejected
- **AND** it verifies stale results after chunk text mismatches are rejected

#### Scenario: Overlay lifecycle behavior is covered

- **WHEN** the ERT suite runs
- **THEN** it verifies `proofread-clear` removes proofread-owned overlays
- **AND** it verifies proofread cleanup preserves unrelated overlays
- **AND** it verifies editing covered text invalidates affected proofread
  overlays
- **AND** it verifies disabling `proofread-mode` clears proofread-owned overlays

#### Scenario: Diagnostic cache behavior is covered

- **WHEN** the ERT suite runs
- **THEN** it verifies unchanged visible text can reuse cached diagnostics
- **AND** it verifies cache misses call the backend
- **AND** it verifies backend name or prompt version changes invalidate old
  cache entries
- **AND** it verifies cached diagnostics still pass text and stale-result
  validation before overlay creation

#### Scenario: Diagnostic interaction behavior is covered

- **WHEN** the ERT suite runs
- **THEN** it verifies `proofread-next` and `proofread-previous` ordering and
  boundary behavior
- **AND** it verifies `proofread-describe` reports diagnostic details without
  modifying source buffer text
- **AND** it verifies `proofread-apply-suggestion` handles single suggestions,
  multiple suggestions, stale overlays, and undo
- **AND** it verifies `proofread-ignore` uses exact text and kind matching,
  removes only matching proofread-owned overlays, and preserves unrelated
  diagnostics

### Requirement: Validation commands are deterministic

The project SHALL keep local validation commands stable and repeatable for
developers and CI-style batch runs.

#### Scenario: Validation commands run from repository root

- **WHEN** a developer follows the documented validation instructions
- **THEN** the test command, byte-compilation command, and formatting command
  can be run from the repository root

#### Scenario: Validation commands leave no persistent runtime state

- **WHEN** validation commands finish
- **THEN** they leave no required running backend process
- **AND** they leave no persistent cache or model-service state needed by later
  test runs

#### Scenario: Validation failure identifies the failing layer

- **WHEN** validation fails
- **THEN** the failing command distinguishes whether the failure came from ERT,
  byte compilation, or formatting validation

### Requirement: Model-aware backend identity

The system SHALL compute a stable backend identity for request metadata and
diagnostic cache keys.

#### Scenario: Mock backend keeps compatible identity

- **WHEN** proofread computes backend identity for the built-in mock backend
- **THEN** the identity remains compatible with existing mock cache behavior

#### Scenario: Model backend identity includes model configuration

- **WHEN** proofread computes backend identity for a configurable model backend
- **THEN** the identity includes the backend name
- **AND** the identity includes the configured model name
- **AND** the identity includes the configured endpoint
- **AND** the identity includes the prompt version
- **AND** the identity includes cache-relevant backend options

#### Scenario: Backend identity excludes volatile request state

- **WHEN** proofread computes backend identity for any backend
- **THEN** the identity does not include request id
- **AND** the identity does not include live buffer objects
- **AND** the identity does not include callback functions
- **AND** the identity does not include absolute buffer positions

### Requirement: Model-aware diagnostic cache invalidation

The system SHALL invalidate diagnostic cache entries when model-relevant backend
configuration changes.

#### Scenario: Changing model name misses old cache entry

- **WHEN** a diagnostic cache entry was written with one model name
- **AND** the user changes the configured model name
- **THEN** proofread does not reuse the old cache entry for the same chunk text

#### Scenario: Changing endpoint misses old cache entry

- **WHEN** a diagnostic cache entry was written with one backend endpoint
- **AND** the user changes the configured backend endpoint
- **THEN** proofread does not reuse the old cache entry for the same chunk text

#### Scenario: Changing prompt version misses old cache entry

- **WHEN** a diagnostic cache entry was written with one prompt version
- **AND** the user changes `proofread-prompt-version`
- **THEN** proofread does not reuse the old cache entry for the same chunk text

#### Scenario: Changing cache-relevant options misses old cache entry

- **WHEN** a diagnostic cache entry was written with one set of cache-relevant
  backend options
- **AND** the user changes those cache-relevant backend options
- **THEN** proofread does not reuse the old cache entry for the same chunk text

#### Scenario: Unchanged identity can reuse cache

- **WHEN** visible chunk text is unchanged
- **AND** backend identity is unchanged
- **AND** current buffer text still matches the cached request text
- **THEN** proofread may reuse cached diagnostics without dispatching another
  backend request

#### Scenario: Cache hit still requires stale validation

- **WHEN** proofread reads diagnostics from cache
- **THEN** proofread validates the current buffer text and request freshness
  before creating proofread-owned overlays

### Requirement: LLM provider backend availability

The system SHALL provide a `llm` backend that is available only when a valid
`llm` provider has been configured for proofread.

#### Scenario: LLM backend unavailable without provider

- **WHEN** backend availability is queried for the `llm` backend
- **AND** `proofread-llm-provider` is nil
- **THEN** `proofread-backend-available-p` reports the `llm` backend as
  unavailable

#### Scenario: LLM backend available with provider

- **WHEN** backend availability is queried for the `llm` backend
- **AND** `proofread-llm-provider` contains a configured `llm` provider object
- **THEN** `proofread-backend-available-p` reports the `llm` backend as
  available

### Requirement: LLM provider backend dispatch

The system SHALL dispatch request-ready proofreading chunks through
`llm-chat-async` when the selected backend is `llm`.

#### Scenario: LLM backend submits asynchronous chat request

- **WHEN** `proofread-backend-check` is called for the `llm` backend
- **AND** `proofread-llm-provider` is configured
- **THEN** proofread submits the request through `llm-chat-async`
- **AND** proofread does not invoke the backend callback inline before
  `proofread-backend-check` returns

#### Scenario: LLM prompt contains proofread request fields

- **WHEN** proofread builds an `llm` prompt for a backend request
- **THEN** the prompt includes the request text
- **AND** the prompt includes allowed context before and after the request text
- **AND** the prompt includes the request language and `major-mode` metadata
- **AND** proofread does not rescan the buffer to build additional request text

#### Scenario: LLM prompt requests JSON diagnostics

- **WHEN** proofread builds an `llm` prompt for a backend request
- **THEN** the prompt requests JSON diagnostics with chunk-relative ranges
- **AND** proofread asks `llm` for JSON output with `response-format` or an
  equivalent JSON schema when supported

### Requirement: LLM provider callback conversion

The system SHALL convert `llm` success and error callbacks into existing
proofread backend result shapes.

#### Scenario: LLM success callback enters parser pipeline

- **WHEN** `llm-chat-async` completes successfully with response text
- **THEN** proofread parses the response text as a proofread JSON diagnostic
  payload
- **AND** proofread validates candidate diagnostics before creating proofread
  diagnostic plists
- **AND** proofread invokes the backend callback with a successful proofread
  result containing the validated diagnostics

#### Scenario: LLM error callback becomes backend error

- **WHEN** `llm-chat-async` completes with an error
- **THEN** proofread invokes the backend callback with an error result
- **AND** the error result includes the original request
- **AND** the source buffer text remains unchanged

#### Scenario: LLM invalid response becomes backend error

- **WHEN** `llm-chat-async` completes successfully with response text that
  cannot be parsed as a proofread JSON diagnostic payload
- **THEN** proofread invokes the backend callback with an error result
- **AND** proofread does not create overlays from that response

### Requirement: LLM diagnostics preserve safety boundaries

The system SHALL apply diagnostics from the `llm` backend only through the
existing stale result, cache, and overlay safety boundaries.

#### Scenario: LLM stale result is dropped

- **WHEN** an `llm` backend result returns after the source buffer is killed,
  `proofread-mode` is disabled, the modification tick changes, or the request
  text no longer matches
- **THEN** proofread drops the result
- **AND** proofread does not create overlays from that result
- **AND** proofread does not write diagnostics from that result to the cache

#### Scenario: LLM fresh result can create overlays

- **WHEN** an `llm` backend result returns for a fresh request
- **AND** the response contains valid diagnostics
- **THEN** proofread creates proofread-owned overlays through the existing
  diagnostic application path
- **AND** proofread writes accepted diagnostics to the diagnostic cache

#### Scenario: LLM backend error clears active request

- **WHEN** an active `llm` backend request completes with an error result
- **THEN** proofread removes that request from active request state
- **AND** no stale active request remains for that failed request

### Requirement: LLM provider cache identity

The system SHALL build stable cache identities for the `llm` backend without
embedding live provider objects or secrets in cache keys.

#### Scenario: LLM cache key excludes provider object

- **WHEN** proofread builds a cache key for a request using the `llm` backend
- **THEN** the cache key contains a stable provider identity
- **AND** the cache key does not contain the raw `proofread-llm-provider` object
- **AND** the cache key does not contain callbacks, buffers, request ids,
  timers, process objects, or API keys

#### Scenario: LLM provider identity change invalidates cache

- **WHEN** the stable `llm` provider identity changes for otherwise identical
  request text, language, `major-mode`, prompt version, and configuration
  version
- **THEN** proofread builds a different cache key
- **AND** old cache entries are not reused for the new provider identity

#### Scenario: LLM unchanged provider identity allows cache hit

- **WHEN** the stable `llm` provider identity and request text remain unchanged
- **AND** the diagnostic cache contains a matching entry
- **THEN** proofread may reuse cached diagnostics without calling
  `llm-chat-async`
- **AND** cached diagnostics still pass through current buffer text validation
  before overlays are created

### Requirement: Sentence-aware chunk construction

The system SHALL split Chinese paragraph text into sentence-level proofreading
chunks before cache lookup or backend request dispatch when sentence boundary
support is available.

#### Scenario: Chinese paragraph splits into sentence chunks

- **WHEN** proofread chunking receives a visible range containing one Chinese
  paragraph with multiple sentences separated by Chinese sentence punctuation
- **THEN** it produces separate chunks for those sentences
- **AND** each chunk records absolute `:beg` and `:end` buffer positions
- **AND** each chunk `:text` exactly matches the buffer text between `:beg` and
  `:end`

#### Scenario: Newline can end a sentence span

- **WHEN** proofread chunking receives a paragraph or visible span where the
  configured sentence boundary behavior treats a newline as a sentence boundary
- **THEN** proofread may split the text at that newline
- **AND** produced chunks still use exact absolute buffer ranges

#### Scenario: Sentence chunks preserve metadata and context

- **WHEN** proofread chunking produces a sentence-level chunk
- **THEN** the chunk preserves the existing chunk plist shape
- **AND** the chunk records the buffer's `major-mode`
- **AND** the chunk records the configured proofread language
- **AND** the chunk records bounded surrounding context
- **AND** the chunk records the buffer's `buffer-chars-modified-tick`

#### Scenario: Oversized sentence remains bounded

- **WHEN** sentence splitting produces a single sentence longer than
  `proofread-max-chunk-size`
- **THEN** proofread splits that sentence into multiple bounded chunks
- **AND** every produced chunk has text length less than or equal to
  `proofread-max-chunk-size`
- **AND** the chunks use stable, contiguous absolute buffer ranges for the
  original sentence text

#### Scenario: Sentence boundary unavailable falls back to paragraph chunking

- **WHEN** proofread chunking runs where `jieba-rs` sentence boundary support is
  unavailable, fails, or produces no useful sentence spans
- **THEN** proofread falls back to existing paragraph-level chunking
- **AND** chunking does not signal an error from idle or visible-check paths
- **AND** the buffer text and text properties remain unchanged

#### Scenario: Request filtering still applies after sentence splitting

- **WHEN** request-ready chunks are built from sentence-level chunks containing
  ignored URL, email, invisible, ignored-face, or ignored-property text
- **THEN** the filtering stage excludes ignored text before cache lookup
- **AND** the filtering stage excludes ignored text before backend request
  construction
- **AND** retained request-ready chunk text still exactly matches its recorded
  absolute buffer range

#### Scenario: Visible check dispatches sentence chunks

- **WHEN** `proofread-check-visible` is invoked in a buffer with
  `proofread-mode` enabled, an available backend configured, and visible Chinese
  text containing multiple sentence chunks
- **THEN** proofread dispatches backend requests for the request-ready sentence
  chunks
- **AND** backend requests continue to use chunk-relative diagnostic ranges
  through the existing backend protocol

#### Scenario: Chunking does not mutate buffer contents

- **WHEN** proofread sentence-aware chunking is run for visible ranges in a
  buffer
- **THEN** the buffer text remains unchanged
- **AND** existing text properties in the buffer remain unchanged
- **AND** no diagnostic or overlay is created by chunk construction itself

### Requirement: Provider-based real model backend

The system SHALL use the `llm` backend as the only supported real-model backend
path.

#### Scenario: Direct Ollama backend is unavailable

- **WHEN** backend availability is queried for the `ollama` backend
- **THEN** `proofread-backend-available-p` reports the backend as unavailable

#### Scenario: Direct Ollama backend is unsupported

- **WHEN** `proofread-backend-check` is called explicitly with the `ollama`
  backend
- **THEN** proofread does not dispatch an HTTP request to Ollama
- **AND** proofread returns through the unsupported backend error path

#### Scenario: Ollama uses LLM provider backend

- **WHEN** a user wants to use Ollama after direct backend removal
- **THEN** the supported path is to set `proofread-backend` to `llm`
- **AND** configure `proofread-llm-provider` with an Ollama provider from the
  `llm` package

#### Scenario: DeepSeek uses LLM provider backend

- **WHEN** a user wants to use DeepSeek
- **THEN** the supported path is to set `proofread-backend` to `llm`
- **AND** configure `proofread-llm-provider` with a DeepSeek provider from the
  `llm` package

### Requirement: Provider-agnostic JSON diagnostic prompt contract

The system SHALL keep a JSON diagnostic prompt contract that is independent of
any direct transport backend.

#### Scenario: LLM prompt requests JSON diagnostics

- **WHEN** proofread builds an `llm` prompt for a backend request
- **THEN** the prompt requests JSON diagnostics rather than free-form prose

#### Scenario: LLM prompt describes required diagnostic fields

- **WHEN** proofread builds an `llm` prompt for a backend request
- **THEN** the prompt describes diagnostic fields for kind, message, original
  text, chunk-relative range, suggestions, and confidence

#### Scenario: Prompt contract participates in cache invalidation

- **WHEN** the JSON prompt contract changes
- **THEN** `proofread-prompt-version` can be changed so old cache entries no
  longer match new requests

### Requirement: Provider-agnostic JSON diagnostic parsing

The system SHALL parse model response text into candidate diagnostics only when
a JSON diagnostic payload can be identified.

#### Scenario: Valid JSON response parses diagnostics

- **WHEN** an `llm` provider returns valid JSON containing diagnostics
- **THEN** proofread extracts candidate diagnostics from the JSON payload

#### Scenario: Extra text with one JSON payload can parse

- **WHEN** an `llm` provider returns extra text around one identifiable JSON
  diagnostic payload
- **THEN** proofread may extract and parse that JSON payload

#### Scenario: Non-JSON response is a backend error

- **WHEN** an `llm` provider returns response text from which no JSON diagnostic
  payload can be parsed
- **THEN** proofread treats the response as a backend error

#### Scenario: Invalid JSON response is a backend error

- **WHEN** an `llm` provider returns malformed JSON
- **THEN** proofread treats the response as a backend error

### Requirement: Provider-agnostic diagnostic validation

The system SHALL validate candidate diagnostics before converting them to
proofread diagnostic plists.

#### Scenario: Valid diagnostic becomes absolute diagnostic

- **WHEN** a candidate diagnostic has a chunk-relative range inside the request
  text
- **AND** the candidate original text exactly matches the request substring at
  that range
- **THEN** proofread converts it to a diagnostic with absolute `:beg` and `:end`
  positions

#### Scenario: Out-of-range diagnostic is dropped

- **WHEN** a candidate diagnostic range is outside the request chunk text
- **THEN** proofread does not create a proofread diagnostic for that candidate

#### Scenario: Text mismatch diagnostic is dropped

- **WHEN** a candidate diagnostic original text does not match the request
  substring at its range
- **THEN** proofread does not create a proofread diagnostic for that candidate

#### Scenario: Suggestions preserve string order

- **WHEN** a valid candidate diagnostic contains multiple string suggestions
- **THEN** the resulting proofread diagnostic stores those suggestions in the
  same order

#### Scenario: Invalid candidate does not discard valid candidates

- **WHEN** a parsed response contains both valid and invalid candidate
  diagnostics
- **THEN** proofread converts the valid candidates
- **AND** proofread does not create diagnostics for the invalid candidates

### Requirement: Provider-agnostic diagnostics preserve safety boundaries

The system SHALL apply parsed model diagnostics only through the existing
proofread backend result handling path.

#### Scenario: Parsed diagnostics still require stale validation

- **WHEN** proofread handles parsed diagnostics from an `llm` provider
- **THEN** stale request validation still runs before overlays are created

#### Scenario: Parsed diagnostics do not modify buffer text

- **WHEN** proofread displays parsed diagnostics from an `llm` provider
- **THEN** source buffer text remains unchanged

#### Scenario: Parsed diagnostics enter existing overlay pipeline

- **WHEN** a fresh `llm` backend result contains valid parsed diagnostics
- **THEN** proofread applies diagnostics through the existing backend result
  handling path
- **AND** proofread writes accepted diagnostics to the diagnostic cache

### Requirement: Token map construction for request-ready chunks

The system SHALL build optional word-level token maps for Chinese request-ready
chunks after ignored text filtering and before cache lookup or backend dispatch.

#### Scenario: Chinese request-ready chunk receives token metadata

- **WHEN** proofread builds a request-ready Chinese chunk and tokenization is
  available
- **THEN** the chunk or backend request contains token metadata
- **AND** each token records a stable chunk-local index
- **AND** each token records chunk-relative `beg` and `end` offsets
- **AND** each token records the token text

#### Scenario: Token text matches request chunk text

- **WHEN** proofread constructs a token for a request-ready chunk
- **THEN** the token text exactly equals the request chunk substring between the
  token's `beg` and `end` offsets
- **AND** the token offsets are relative to the request chunk text

#### Scenario: Token category is not required

- **WHEN** proofread constructs token metadata from segmentation output without
  category data
- **THEN** the token remains valid when its index, offsets, and text are valid
- **AND** diagnostic validation does not require a token category

#### Scenario: Tokenization runs after request filtering

- **WHEN** a sentence chunk contains ignored URL, email, invisible,
  ignored-face, or ignored-property text
- **AND** request-ready filtering removes that ignored text before backend
  construction
- **THEN** token metadata is built only for the retained request-ready chunk
  text
- **AND** no token spans ignored text that is not sent to the backend

#### Scenario: Tokenization failure falls back safely

- **WHEN** `jieba-rs` tokenization is unavailable, signals an error, or produces
  token output that cannot be mapped exactly to the request chunk
- **THEN** proofread continues without token metadata
- **AND** proofread does not signal an error from idle or visible-check paths
- **AND** existing sentence-level request construction remains available

### Requirement: Token-boundary bounding for oversized sentences

The system SHALL prefer token boundaries when splitting an oversized
sentence-level chunk into bounded request-ready chunks.

#### Scenario: Oversized sentence splits at token boundaries

- **WHEN** sentence chunking produces a sentence longer than
  `proofread-max-chunk-size`
- **AND** tokenization can map token boundaries for that sentence
- **THEN** proofread splits the sentence into chunks whose lengths are less than
  or equal to `proofread-max-chunk-size`
- **AND** split points occur at token boundaries when doing so can satisfy the
  size limit

#### Scenario: Oversized token falls back to existing bounded split

- **WHEN** one token is longer than `proofread-max-chunk-size`
- **THEN** proofread falls back to the existing bounded split behavior for that
  token text
- **AND** every produced chunk still exactly matches its recorded buffer range

### Requirement: Token-aware JSON prompt contract

The system SHALL include token metadata in the `llm` JSON diagnostic prompt when
token metadata is available for a backend request.

#### Scenario: Prompt includes original text and token list

- **WHEN** proofread builds an `llm` prompt for a request that contains token
  metadata
- **THEN** the prompt still includes the original request text
- **AND** the prompt includes a token list with token indexes, ranges, and texts
- **AND** the prompt requires diagnostics to continue using chunk-relative
  ranges and exact original text

#### Scenario: Prompt describes optional token locators

- **WHEN** proofread builds an `llm` prompt for a request that contains token
  metadata
- **THEN** the prompt describes optional diagnostic token locator fields such as
  `token_index` or `token_range`
- **AND** the prompt states that token locators are auxiliary to the required
  `range` and original `text` fields

#### Scenario: Prompt falls back without tokens

- **WHEN** proofread builds an `llm` prompt for a request that does not contain
  token metadata
- **THEN** the prompt remains a valid provider-agnostic JSON diagnostic prompt
- **AND** the prompt does not require token locator fields in model responses

### Requirement: Token-aware diagnostic validation

The system SHALL treat model-provided token locators as optional consistency
checks while keeping chunk-relative range and exact original text validation
authoritative.

#### Scenario: Valid token locator confirms diagnostic range

- **WHEN** a candidate diagnostic has a valid chunk-relative range
- **AND** the candidate original text exactly matches the request substring at
  that range
- **AND** the candidate contains a token locator that maps to the same range and
  text
- **THEN** proofread converts the candidate to a proofread diagnostic with
  absolute positions

#### Scenario: Missing token locator does not block valid diagnostic

- **WHEN** a candidate diagnostic has a valid chunk-relative range
- **AND** the candidate original text exactly matches the request substring at
  that range
- **AND** the candidate does not contain token locator fields
- **THEN** proofread converts the candidate to a proofread diagnostic with
  absolute positions

#### Scenario: Malformed token locator does not replace range validation

- **WHEN** a candidate diagnostic has a valid chunk-relative range
- **AND** the candidate original text exactly matches the request substring at
  that range
- **AND** the candidate contains a token locator that cannot be interpreted
- **THEN** proofread ignores the token locator
- **AND** proofread does not use that token locator as a position source

#### Scenario: Contradictory token locator rejects diagnostic

- **WHEN** a candidate diagnostic has a token locator that maps to a different
  request text range than the candidate's required `range`
- **THEN** proofread does not create a proofread diagnostic for that candidate
- **AND** other valid candidates in the same response can still be converted

#### Scenario: Token-only diagnostic is rejected

- **WHEN** a candidate diagnostic contains token locator fields but does not
  contain a valid chunk-relative `range` and exact original `text`
- **THEN** proofread does not create a proofread diagnostic for that candidate

### Requirement: Tokenization-aware cache identity

The system SHALL include stable tokenization identity in cache keys whenever
token metadata can affect backend prompts or accepted diagnostics.

#### Scenario: Tokenization identity change invalidates cache

- **WHEN** token-aware prompting is enabled for otherwise identical request text
  and metadata
- **AND** the tokenizer mode, HMM setting, token prompt enablement, prompt
  version, or deterministic user dictionary identity changes
- **THEN** proofread builds a different cache key
- **AND** the old cache entry is not used for the new tokenization identity

#### Scenario: Cache key excludes volatile objects and secrets

- **WHEN** proofread builds a cache key for a token-aware request
- **THEN** the cache key does not contain provider objects
- **AND** the cache key does not contain callback objects
- **AND** the cache key does not contain buffer objects
- **AND** the cache key does not contain API keys or other secrets

#### Scenario: Token fallback keeps existing cache behavior

- **WHEN** tokenization is unavailable and proofread builds a request without
  token metadata
- **THEN** cache lookup and write behavior remain based on the existing
  request-ready chunk identity
- **AND** stale-result validation still runs before cached or fresh diagnostics
  create overlays

### Requirement: Sentence-window request context

The system SHALL build request-ready `:context-before` and `:context-after` from
configurable logical sentence windows when sentence boundary support is
available.

#### Scenario: Default context uses one complete sentence before

- **WHEN** proofread builds a request-ready Chinese sentence chunk with a
  complete logical sentence immediately before it in the same context region
- **THEN** the chunk's `:context-before` is that complete preceding sentence
- **AND** the context does not begin in the middle of that ordinary sentence

#### Scenario: Default context uses one complete sentence after

- **WHEN** proofread builds a request-ready Chinese sentence chunk with a
  complete logical sentence immediately after it in the same context region
- **THEN** the chunk's `:context-after` is that complete following sentence
- **AND** the context does not end in the middle of that ordinary sentence

#### Scenario: Configured sentence counts change the context window

- **WHEN** `proofread-context-sentences-before` or
  `proofread-context-sentences-after` is set to a positive integer greater than
  `1`
- **THEN** proofread includes up to that many complete logical sentences in the
  corresponding context direction
- **AND** it preserves their original buffer order in the returned context
  string

#### Scenario: Zero sentence count disables a context direction

- **WHEN** `proofread-context-sentences-before` is `0`
- **THEN** request-ready chunks have empty `:context-before`
- **WHEN** `proofread-context-sentences-after` is `0`
- **THEN** request-ready chunks have empty `:context-after`

#### Scenario: Context size reduces sentence count before truncating

- **WHEN** the configured complete sentence window for a context side exceeds
  `proofread-context-size`
- **THEN** proofread reduces the number of included context sentences until the
  context fits the budget
- **AND** it does not truncate an ordinary included sentence when at least one
  complete sentence can fit

#### Scenario: Single oversized context sentence uses bounded fallback

- **WHEN** the nearest single logical context sentence exceeds
  `proofread-context-size`
- **THEN** proofread uses a bounded character-window fallback for that context
  side
- **AND** the fallback is limited by `proofread-context-size`
- **AND** the request chunk's `:text` remains the exact buffer substring between
  `:beg` and `:end`

### Requirement: Context sentence boundaries ignore visual wrapping

The system MUST derive sentence-window context from buffer text and logical
sentence boundaries, not from screen lines, visual lines, or window columns.

#### Scenario: Hard-wrapped prose keeps a single logical sentence

- **WHEN** ordinary Chinese prose contains a single hard-wrap newline inside a
  sentence and no sentence-ending punctuation at that newline
- **THEN** proofread does not treat that newline alone as a sentence boundary
- **AND** the newline is preserved in returned context when the containing
  sentence is selected
- **AND** authoritative chunk `:text` still preserves the real buffer newline

#### Scenario: Visual line mode does not change context

- **WHEN** proofread builds request-ready chunks for the same buffer range with
  `visual-line-mode` disabled and enabled
- **THEN** the chunk texts are the same
- **AND** each matching chunk has the same `:context-before`
- **AND** each matching chunk has the same `:context-after`

#### Scenario: Window width does not change context

- **WHEN** the same buffer text is displayed with different window widths or
  soft-wrap layouts
- **THEN** proofread produces the same sentence-window context for the same
  request-ready chunk ranges

### Requirement: Context search stops at unrelated structure

The system SHALL stop sentence-window context search at blank lines and
supported structural boundaries so unrelated document structure is not spliced
into request context.

#### Scenario: Blank line stops context search

- **WHEN** a blank line separates a request-ready chunk from text before or
  after it
- **THEN** proofread does not include sentences across that blank line in the
  corresponding context field

#### Scenario: Org heading stops context search

- **WHEN** an Org heading separates a request-ready chunk from surrounding text
- **THEN** proofread does not include sentences across that heading in
  `:context-before` or `:context-after`

#### Scenario: Org metadata stops context search

- **WHEN** an Org metadata line such as a keyword or property drawer separates a
  request-ready chunk from surrounding prose
- **THEN** proofread does not include context across that metadata boundary

#### Scenario: Org list table or block stops context search

- **WHEN** an Org list item, table row, block delimiter, or block content
  separates a request-ready chunk from surrounding prose
- **THEN** proofread does not include context across that structural boundary

### Requirement: Request context preserves request integrity and filtering

The system SHALL keep request `:text` and diagnostic ranges authoritative for
the request-ready chunk while applying existing ignored-text filtering to
context.

#### Scenario: Ignored text is excluded from context

- **WHEN** selected sentence-window context contains an ignored URL, email,
  invisible span, ignored face, or ignored property
- **THEN** the returned `:context-before` or `:context-after` excludes that
  ignored text
- **AND** request-ready chunk `:text` excludes ignored text only through the
  existing request-ready filtering stage

#### Scenario: Request text exactly matches buffer range

- **WHEN** proofread builds a request-ready chunk with sentence-window context
- **THEN** the chunk's `:text` exactly equals the buffer text between its
  recorded `:beg` and `:end`
- **AND** context text is not appended to or prepended to `:text`

#### Scenario: Diagnostics remain relative to request text

- **WHEN** a backend returns a diagnostic range for a request that includes
  sentence-window context fields
- **THEN** proofread interprets that range only relative to request `:text`
- **AND** a diagnostic range cannot point into `:context-before` or
  `:context-after`

#### Scenario: Overlay positions do not drift

- **WHEN** proofread accepts a diagnostic for a request-ready chunk whose
  context was generated from sentence windows
- **THEN** the created diagnostic and overlay positions map to the chunk's
  absolute `:beg` and `:end` range in the buffer
- **AND** context contents do not shift diagnostic positions

### Requirement: Context fallback and cache identity

The system SHALL fall back safely when sentence-window context cannot be
computed and SHALL distinguish context-affecting changes in diagnostic cache
keys.

#### Scenario: Sentence boundary unavailable falls back to character context

- **WHEN** sentence boundary support is unavailable, fails, does not move, or
  produces no useful context sentence spans
- **THEN** proofread uses the existing bounded character-window context behavior
  for that side
- **AND** proofread does not signal an error from chunk construction, visible
  checking, cache lookup, or backend dispatch

#### Scenario: Context strategy change misses old cache entries

- **WHEN** a cache entry was created with a different context strategy than the
  current request-ready chunk uses
- **THEN** proofread does not reuse that old cache entry for the current chunk

#### Scenario: Context configuration change misses old cache entries

- **WHEN** `proofread-context-sentences-before`,
  `proofread-context-sentences-after`, or `proofread-context-size` changes in a
  way that can affect request context
- **THEN** proofread does not reuse cache entries created under the old context
  configuration

#### Scenario: Context content change misses old cache entries

- **WHEN** two request-ready chunks have the same `:text` but different
  `:context-before` or `:context-after`
- **THEN** their diagnostic cache keys are different

#### Scenario: Context cache key excludes volatile and secret values

- **WHEN** proofread builds a cache key for a request-ready chunk with
  sentence-window context
- **THEN** the key does not include the buffer object
- **AND** the key does not include callback objects
- **AND** the key does not include provider objects
- **AND** the key does not include token lists
- **AND** the key does not include secrets
