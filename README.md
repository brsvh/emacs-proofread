<p align="right"><strong>English</strong> · <a href="README_zh-Hans.md">简体中文</a></p>

```
Copyright (c)  2026 Bingshan Chang.
Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3
or any later version published by the Free Software Foundation;
with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
A copy of the license is included in the section entitled "GNU
Free Documentation License".
```

# proofread

Proofread provides asynchronous, context-aware proofreading for GNU Emacs. It
extracts prose from ordinary text, comments, or docstrings, splits it into
bounded chunks, and sends those chunks to an LLM or local LanguageTool backend.
Spelling, grammar, style, and other issues appear as diagnostics that can be
reviewed, ignored, or corrected in place. Requests run asynchronously, so
proofreading does not block editing.

<div align="center">

https://github.com/user-attachments/assets/9dc5c4ee-a43e-45b8-a9fc-a372079ed528

</div>

## Getting Started

### Installation

The `proofread` package requires GNU Emacs and GNU ELPA `llm`, and contains the
core, LLM, and LanguageTool libraries. LanguageTool itself is an optional
runtime dependency used only by LanguageTool checkers; the core and LLM backend
neither load nor start it. The LanguageTool backend can reuse any compatible
local v2 HTTP server; automatic startup additionally requires a
`languagetool-http-server` executable on `exec-path`. The optional
`proofread-popup` 0.1.1 package additionally requires `proofread` 0.2.0 or later
and `posframe`.

Clone this repository and add its package directories to `load-path`:

```sh
git clone https://github.com/brsvh/emacs-proofread.git
```

```elisp
(add-to-list 'load-path "/path/to/emacs-proofread/lisp/proofread")
(add-to-list 'load-path "/path/to/emacs-proofread/lisp/proofread-popup")
(require 'proofread)
```

### Building packages

The repository's `Makefile` builds the core `proofread` package and the optional
`proofread-popup` package. Building uses GNU Make, GNU tar, and GNU Emacs. The
package dependencies listed above must be visible to the Emacs used for byte
compilation. Run these commands from the repository root:

```sh
make all
make proofread
make proofread-popup
make clean
```

`make all` builds both packages. The package-specific targets build just one
package, and `make clean` removes generated files. Set `EMACS` to choose another
executable, for example `make EMACS=/path/to/emacs all`.

Build outputs are written under `lisp/` and `dist/`: package metadata,
autoloads, byte-compiled files, and ELPA-compatible source archives. Individual
stage targets such as `make proofread-compile` or `make proofread-archive`
remain available for release work, but the summary targets above are normally
enough.

### Configuration

> [!WARNING]
> The API in the current main branch is unstable; it is recommended that you use
> the v0.1.0 tag instead.

Proofread dispatch is profile-driven. Define `proofread-profiles`, select one
with `proofread-profile`, and require the backend libraries used by that
profile. A profile is a named language configuration with `:language`,
`:display-language`, and ordered `:checkers`. Each checker has a stable `:name`,
selects a registered `:backend`, and carries optional backend-local `:options`.

Set `:language` to a machine-readable language code such as `"en-US"` or
`"zh-CN"`. Set `:display-language` to the natural-language name used in LLM
prompts, such as `"English"` or `"Simplified Chinese"`.

#### Minimal configuration (`llm`)

A minimal LLM setup uses one profile with one `llm` checker. This example checks
English text with a local Ollama model named `qwen3.5:4b`:

```elisp
(require 'proofread)
(require 'proofread-llm)
(require 'llm-ollama)

(defvar qwen3.5-4b (make-llm-ollama :chat-model "qwen3.5:4b"))

(setq proofread-profiles
      `((english
         :language "en-US"
         :display-language "English"
         :checkers (( :name ollama-qwen
                      :backend llm
                      :options ( :provider ,qwen3.5-4b
                                 :provider-identity "ollama:qwen3.5:4b"))))))

(setq proofread-profile 'english)

(add-hook 'text-mode-hook #'proofread-mode)
(add-hook 'prog-mode-hook #'proofread-mode)
```

#### Further `llm` backend configuration

LLM checkers read provider and request behavior from checker-local `:options`.
Checker options override the corresponding `proofread-llm-*` defaults only for
that checker.

For every LLM request, Proofread uses the profile's non-`nil`
`:display-language` as the target-language hint and falls back to `:language`.
If both are `nil`, no target-language hint is added.

For local models, this documentation covers Ollama. Use the provider supplied by
the `llm` package and give the checker a stable, non-secret provider identity:

```elisp
(require 'llm-ollama)

(defvar qwen3.5-4b-checker
  `( :name ollama-qwen
     :backend llm
     :options ( :provider ,(make-llm-ollama :chat-model "qwen3.5:4b")
                :provider-identity "ollama:qwen3.5:4b"
                :diagnostic-passes 1)))
```

For remote models, keep credentials in `auth-source` or another secure facility.
This OpenAI example reads the key from `auth-source` and uses a stable provider
identity that does not contain the key:

```elisp
(require 'auth-source)
(require 'llm-openai)

(defvar gpt-5.4-checker
  `( :name openai
     :backend llm
     :options ( :provider ,(make-llm-openai :key (auth-source-pick-first-password
                                                  :host "api.openai.com")
                                            :chat-model "gpt-5.4")
                :provider-identity "openai:gpt-5.4"
                :source-label "gpt-5.4"
                :response-strategy auto
                :diagnostic-passes 1)))
```

Proofread uses a checker-local `:source-label` in popup messages when it is
non-`nil`. Otherwise it uses `proofread-llm-source-label`, then the provider's
`llm-name`, and finally `llm`. Some providers return a provider family rather
than the exact chat model from `llm-name`, so set `:source-label` explicitly
when the precise model name matters. An explicit checker-local `nil` bypasses
the global label and restores automatic provider naming for that checker.

`proofread-llm-response-strategy` defaults to `auto`: it uses a JSON schema when
the provider advertises that capability, and otherwise falls back to prompt-only
JSON. If you provide `:instructions-function`, also provide a stable
`:instructions-identity` so cache identity changes when your instructions
change.

`proofread-llm-request-timeout` is a Proofread-owned request watchdog. It
defaults to `120` seconds. Every non-`nil` value must be a positive number; set
it to `nil` to disable the watchdog globally. A checker-local `:request-timeout`
overrides the global value whenever that key is present, so an explicit `nil`
disables the watchdog for that checker. The timeout controls request liveness
only and is not part of cache compatibility; changing it does not invalidate
otherwise compatible cached results. When `proofread-mode` is enabled, the
current `proofread-llm-request-timeout` value also becomes the buffer-local
`llm-request-plz-connect-timeout`; disabling the mode restores its previous
local binding or inherits its current global value.

For provider-specific setup details, see the upstream
[`llm.el` provider documentation](https://github.com/ahyatt/llm#setting-up-providers).

#### `languagetool` backend configuration

A single-language LanguageTool setup also uses one profile with one
`languagetool` checker. LanguageTool uses `:language` from checker-local
`:options` when that key is present, including an explicit `nil` for automatic
detection; otherwise it falls back to the profile's machine-readable
`:language`. A non-`nil` value must be a code such as `en-US`, `zh-CN`, or
`de-DE`, not a display name such as `"English"`. LanguageTool never receives the
profile's `:display-language`:

```elisp
(require 'proofread)
(require 'proofread-languagetool)

(defvar languagetool-checker
  '( :name languagetool
     :backend languagetool
     :options ( :language "en-US"
                :level picky)))

(setq proofread-profiles
      `((english-languagetool
         :language "en-US"
         :display-language "English"
         :checkers (,languagetool-checker))))

(setq proofread-profile 'english-languagetool)

(add-hook 'text-mode-hook #'proofread-mode)
(add-hook 'prog-mode-hook #'proofread-mode)
```

To use automatic local startup, make sure `languagetool-http-server` is on
`exec-path` or set `proofread-languagetool-command` to its absolute path. The
server URL and lifecycle settings are session-global. Request options such as
`:language`, `:level`, `:preferred-variants`, rule lists, category lists,
`:mother-tongue`, and `:enabled-only` belong in the checker. The LanguageTool
server URL remains global; do not put `:url` in a checker expecting a separate
server per profile.

Run `M-x proofread-languagetool-start-server` to explicitly reuse or start the
configured server, including when automatic startup is disabled. Run
`M-x proofread-languagetool-stop-server` to stop a server owned by this Emacs
session; it never stops an external server.

When a LanguageTool checker's `:language` is `nil`, the backend sends
`language=auto`. Set `:preferred-variants` in that checker so variant-dependent
spelling dictionaries can run, for example:

```elisp
'( :language nil
   :preferred-variants ("en-US" "de-DE"))
```

The local open-source server keeps checked text on the local machine, but it
does not include LanguageTool's cloud-only AI rules. Automatic language
detection is also less accurate without a separately configured fastText model,
so an explicit language code is the most predictable configuration. See the
official [local server guide](https://dev.languagetool.org/http-server.html) and
[HTTP API](https://languagetool.org/http-api/) for upstream details.

#### Enabling different backends for multiple languages

More complex setups define one profile per language. Each profile can choose a
different backend set or different backend-local options. This example uses
OpenAI plus LanguageTool for English, and local Ollama plus LanguageTool for
Simplified Chinese:

```elisp
(require 'proofread)
(require 'proofread-llm)
(require 'proofread-languagetool)
(require 'auth-source)
(require 'llm-openai)
(require 'llm-ollama)

(defvar gpt-5.4-checker
  `( :name openai
     :backend llm
     :options ( :provider ,(make-llm-openai :key (auth-source-pick-first-password
                                                  :host "api.openai.com")
                                            :chat-model "gpt-5.4")
                :provider-identity "openai:gpt-5.4"
                :source-label "gpt-5.4"
                :response-strategy auto
                :diagnostic-passes 1)))

(defvar languagetool-english-checker
  '( :name languagetool
     :backend languagetool
     :options ( :language "en-US"
                :level picky)))

(defvar languagetool-chinese-checker
  '( :name languagetool
     :backend languagetool
     :options ( :language "zh-CN"
                :level picky)))

(defvar qwen3.5-4b-checker
  `( :name ollama-qwen
     :backend llm
     :options ( :provider ,(make-llm-ollama :chat-model "qwen3.5:4b")
                :provider-identity "ollama:qwen3.5:4b"
                :diagnostic-passes 1)))

(setq proofread-profiles
      `((english
         :language "en-US"
         :display-language "English"
         :checkers (,gpt-5.4-checker
                    ,languagetool-english-checker))
        (chinese
         :language "zh-CN"
         :display-language "Simplified Chinese"
         :checkers (,qwen3.5-4b-checker
                    ,languagetool-chinese-checker))))

(setq proofread-profile 'english)
```

Switch profiles by setting `proofread-profile`:

```elisp
(setq proofread-profile 'chinese)
```

Diagnostics from different checkers remain separate internally. The user
interface groups diagnostics that refer to the same live range and text,
preserves each checker's message, and deduplicates identical suggestion text.
Within each group, checker labels, messages, suggestions, and correction choices
follow the profile's declared `:checkers` order, regardless of asynchronous
completion order.

#### Selecting a profile for one buffer

`proofread-profile` remains an ordinary global default. To select a different
profile in one buffer without changing the default for other buffers, set it
buffer-locally:

```elisp
(setq-local proofread-profile 'chinese)
```

Changing a buffer's selected profile, or removing a checker from that profile,
does not itself clear diagnostics. On the next explicit check, Proofread removes
diagnostics in the checked range that belong to checkers absent from the
selected profile, even if its current checkers report no findings. Diagnostics
outside the checked range remain unchanged, and diagnostics from checkers still
in the profile remain visible until their replacement results are applied.

File-local and directory-local values use Emacs's normal confirmation flow. If
you trust one exact profile value, you can explicitly allow only that value:

```elisp
(add-to-list 'safe-local-variable-values
             '(proofread-profile . chinese))
```

Do not mark arbitrary values of `proofread-profile` as safe. A profile may
select a remote checker, and automatic checking may then send buffer contents to
that provider.

During compatibility with version 0.1 configurations, `nil` means that the
obsolete single-backend settings remain active when configured; it does not
unconditionally disable dispatch. To disable dispatch explicitly, select a named
profile whose `:checkers` list is empty:

```elisp
(add-to-list 'proofread-profiles '(disabled :checkers nil))
(setq-local proofread-profile 'disabled)
```

An explicit check with this profile removes profile-owned diagnostics from the
checked range without dispatching backend requests. Diagnostics outside that
range remain unchanged. This profile-owner retirement does not affect
otherwise-valid ad-hoc diagnostics added through the low-level API.

#### Migrating from version 0.1

`proofread-backend` and `proofread-language` are obsolete in version 0.2. Move
backend selection into each checker's `:backend`, move the language hint into
the profile's `:language`, and select that profile with `proofread-profile`. The
old variables remain temporarily functional for compatibility when
`proofread-profile` is `nil`, but new configurations should not set them.

`proofread-targets` controls which text is checked in each buffer:

| Value                     | Behavior                                                                                     |
| ------------------------- | -------------------------------------------------------------------------------------------- |
| `auto`                    | Check comments and docstrings in modes derived from `prog-mode`, and all text in other modes |
| `all`                     | Check all text                                                                               |
| `comments`                | Check comments only                                                                          |
| `docstrings`              | Check docstrings only                                                                        |
| `comments-and-docstrings` | Check comments and docstrings                                                                |

This option becomes buffer-local when set. To change the default for new
buffers, use `setq-default`, for example:

```elisp
(setq-default proofread-targets 'all)
```

### Running checks

After `M-x proofread-mode`, the default behavior is to check the union of the
current buffer's visible ranges across all live windows that display it after
one second of idle time. Enabling the mode, editing, scrolling, or changing the
window configuration schedules a check. URLs, email addresses, invisible text,
and text selected by `proofread-ignored-faces` or `proofread-ignored-properties`
are not sent to the backend.

Automatic checks cover visible text only. To check another scope explicitly, use
`proofread-check-at-point`, `proofread-check-region`, `proofread-check-buffer`,
or `proofread-check-visible-range`. All four commands require `proofread-mode`
to be enabled. The buffer command respects narrowing; the point command checks
the request-ready chunk at point, not merely one word.

Accepted diagnostics use `proofread-face`. Navigate with `proofread-next` and
`proofread-previous`, inspect full details with `proofread-describe`, or open a
list below the source window with `proofread-show-buffer-diagnostics`. In that
list, `RET` visits a diagnostic, `SPC` or `C-o` previews it in another window,
and `n` or `p` moves through the list.

### Correcting errors

Place point on a diagnostic and run `M-x proofread-correct-at-point`. A single
suggestion is applied directly; multiple suggestions are selected with
`completing-read`, so completion UIs such as Vertico work without additional
integration. Before committing the edit, Proofread verifies that the diagnostic
is still live, that its original text has not changed, and that a replacement
will not damage a comment or docstring delimiter.

Run `M-x proofread-ignore` to dismiss a diagnostic. Ignore records persist for
the current Emacs session and filter semantically identical diagnostics from
every buffer in which Proofread is active.

<div align="center">

**Check and correct at point**

https://github.com/user-attachments/assets/49bfacf7-1278-47c4-a0c3-180f1fb0b790

</div>

## Advanced features

### `proofread-popup`

`proofread-popup` is an optional frontend based on Posframe. Once the library is
loaded, `proofread-popup-mode` automatically follows `proofread-mode` in each
buffer:

```elisp
(require 'proofread-popup)
```

When point is on a diagnostic, the frontend displays each diagnostic message in
a child frame above the start of its range and hides the frame when point moves
away. The frame is also hidden immediately when its source buffer or window
loses selection, so switching buffers or windows cannot leave a stale popup
behind. By default, it waits until point has been idle for `0.5` seconds, then
creates or updates the child frame from the diagnostic at that time. Movement
and diagnostic notifications during the wait are coalesced. Set
`proofread-popup-delay` to `0` to restore immediate updates, for example with
`(setq proofread-popup-delay 0)` or Customize. Every message is prefixed with
its backend source: LLM checkers use their effective source label, while
LanguageTool displays `languagetool`. Source labels use a bold, theme-aware
emphasis face. The popup does not show suggestions or provide actions. It is
unavailable in terminals and other environments where child frames do not work.
Run `M-x proofread-popup-mode` to opt the current buffer out of or back into the
automatic integration. Its display can also be controlled with
`proofread-popup-enabled`, `proofread-popup-delay`, and
`proofread-popup-max-width`.

### Batch correction

Proofread never rewrites text merely because a backend returned diagnostics.
Batch correction happens only after the user explicitly invokes one of these
commands:

- `proofread-correct-region` corrects diagnostics fully contained in the active
  region.
- `proofread-correct-buffer` corrects diagnostics in the accessible portion of
  the current buffer.
- `proofread-correct-visible-range` corrects diagnostics in all visible ranges.

Diagnostics without suggestions are skipped, as are later diagnostics that
overlap an earlier one. Diagnostics with multiple suggestions still prompt
individually. The entire batch is applied atomically as a single undo step; if
any replacement fails, all changes in the batch are rolled back.

<div align="center">

**Check and correct a selected region**

https://github.com/user-attachments/assets/fbac8da1-96b2-4eb6-b08a-f2a1459f02e1

**Check and correct visible ranges**

https://github.com/user-attachments/assets/621e7e66-b7ed-4345-8a15-1e4aa08dfad9

</div>

## Commands

The core mode defines no default key bindings. These commands can be invoked
with `M-x` or bound by the user:

| Command                             | Description                                                  |
| ----------------------------------- | ------------------------------------------------------------ |
| `proofread-mode`                    | Toggle the Proofread minor mode in the current buffer        |
| `proofread-check-at-point`          | Check the request-ready text chunk at point                  |
| `proofread-check-region`            | Check the active region                                      |
| `proofread-check-buffer`            | Check the accessible portion of the current buffer           |
| `proofread-check-visible-range`     | Check all live-window ranges displaying the current buffer   |
| `proofread-show-buffer-diagnostics` | Open a list of diagnostics for the current buffer            |
| `proofread-next`                    | Move to the next diagnostic without wrapping                 |
| `proofread-previous`                | Move to the previous diagnostic without wrapping             |
| `proofread-describe`                | Describe the diagnostic at point in a help buffer            |
| `proofread-correct-at-point`        | Apply a suggestion for the diagnostic at point               |
| `proofread-correct-region`          | Correct diagnostics contained in the active region           |
| `proofread-correct-buffer`          | Correct diagnostics in the accessible buffer                 |
| `proofread-correct-visible-range`   | Correct diagnostics contained in visible ranges              |
| `proofread-ignore`                  | Ignore the diagnostic at point for this Emacs session        |
| `proofread-clear`                   | Clear diagnostics and their overlays from the current buffer |
| `proofread-clear-cache`             | Clear the diagnostic cache for the current buffer            |
| `proofread-show-buffer-requests`    | Start recording and display backend requests for a buffer    |

In a request list, `RET` or `C-m` invokes `proofread-show-request` to display
the complete request lifecycle. In a diagnostic list, `RET` or `C-m` invokes
`proofread-goto-diagnostic`, while `SPC` or `C-o` invokes
`proofread-show-diagnostic`.

## Customization options

Run `M-x customize-group RET proofread RET` to edit the core options:

| Option                                    | Default | Purpose                                                                           |
| ----------------------------------------- | ------- | --------------------------------------------------------------------------------- |
| `proofread-auto-check`                    | `t`     | Schedule checks after enabling, edits, and window activity; buffer-local when set |
| `proofread-targets`                       | `auto`  | Select all text, comments, or docstrings; buffer-local when set                   |
| `proofread-docstring-predicate-functions` | `nil`   | Add predicate functions for recognizing docstrings; buffer-local when set         |
| `proofread-idle-delay`                    | `1.0`   | Wait this many idle seconds before an automatic check                             |
| `proofread-inhibit-progress-messages`     | `t`     | Suppress background progress, but not errors or explicit command feedback         |
| `proofread-max-chunk-size`                | `2000`  | Limit the number of characters in each proofreading chunk                         |
| `proofread-context-size`                  | `300`   | Limit context characters sent on each side of a chunk                             |
| `proofread-context-sentences-before`      | `1`     | Limit logical context sentences before a chunk                                    |
| `proofread-context-sentences-after`       | `1`     | Limit logical context sentences after a chunk                                     |
| `proofread-max-concurrent-requests`       | `8`     | Limit active backend requests per buffer                                          |
| `proofread-profiles`                      | `nil`   | Define named multi-backend profiles                                               |
| `proofread-profile`                       | `nil`   | Select a named profile                                                            |
| `proofread-llm-provider`                  | `nil`   | Default provider when an LLM checker omits `:provider`                            |
| `proofread-llm-response-strategy`         | `auto`  | Default response strategy when an LLM checker omits `:response-strategy`          |
| `proofread-llm-request-timeout`           | `120`   | Set the LLM watchdog and mode-local plz connect timeout; `nil` disables both      |
| `proofread-llm-provider-identity`         | `nil`   | Default stable provider identity when an LLM checker omits `:provider-identity`   |
| `proofread-llm-source-label`              | `nil`   | Default diagnostic source label; `nil` uses the effective provider name           |
| `proofread-llm-max-diagnostic-passes`     | `3`     | Default pass limit when an LLM checker omits `:diagnostic-passes`                 |
| `proofread-llm-instructions-function`     | `nil`   | Default extra instructions when an LLM checker omits `:instructions-function`     |
| `proofread-llm-instructions-identity`     | `nil`   | Default stable instructions identity when an LLM checker omits it                 |
| `proofread-cache-max-entries`             | `128`   | Limit per-buffer LRU cache entries; `0` disables caching                          |
| `proofread-request-log-max-records`       | `100`   | Limit records retained for each monitored buffer                                  |
| `proofread-ignored-faces`                 | `nil`   | Exclude text whose `face` property matches one of these faces                     |
| `proofread-ignored-properties`            | `nil`   | Exclude text where one of these text properties is non-`nil`                      |

The LanguageTool library defines a separate `proofread-languagetool` Customize
group:

| Option                                       | Default                                  | Purpose                                                       |
| -------------------------------------------- | ---------------------------------------- | ------------------------------------------------------------- |
| `proofread-languagetool-server-url`          | `http://127.0.0.1:8081/v2`               | Select the local or externally managed v2 API endpoint        |
| `proofread-languagetool-auto-start`          | `t`                                      | Start a session-local server when the endpoint is unavailable |
| `proofread-languagetool-command`             | `languagetool-http-server`               | Select an executable or argv prefix for managed startup       |
| `proofread-languagetool-config-file`         | `PROOFREAD_LANGUAGETOOL_CONFIG` or `nil` | Pass an optional local Java properties file to the server     |
| `proofread-languagetool-startup-timeout`     | `15.0`                                   | Limit the overall managed-server startup wait                 |
| `proofread-languagetool-health-timeout`      | `3.0`                                    | Limit one server health probe                                 |
| `proofread-languagetool-request-timeout`     | `10.0`                                   | Limit one `/check` request                                    |
| `proofread-languagetool-level`               | `default`                                | Default level when a checker omits `:level`                   |
| `proofread-languagetool-preferred-variants`  | `nil`                                    | Default variants when a checker omits `:preferred-variants`   |
| `proofread-languagetool-mother-tongue`       | `nil`                                    | Default mother tongue when a checker omits `:mother-tongue`   |
| `proofread-languagetool-enabled-rules`       | `nil`                                    | Default enabled rules when a checker omits `:enabled-rules`   |
| `proofread-languagetool-disabled-rules`      | `nil`                                    | Default disabled rules when a checker omits `:disabled-rules` |
| `proofread-languagetool-enabled-categories`  | `nil`                                    | Default enabled categories when omitted by a checker          |
| `proofread-languagetool-disabled-categories` | `nil`                                    | Default disabled categories when omitted by a checker         |
| `proofread-languagetool-enabled-only`        | `nil`                                    | Default enabled-only policy when a checker omits it           |

`proofread-languagetool-enabled-only` requires at least one enabled rule or
category and cannot be combined with disabled rules or categories. Language,
level, variant, mother-tongue, rule, and category settings are included in the
backend cache identity, so changing them does not reuse results produced by a
different checking policy.

The optional frontend also defines `proofread-popup-enabled` (default `t`),
`proofread-popup-delay` (default `0.5` seconds, with `0` meaning immediate
updates), and `proofread-popup-max-width` (default `80`). Customize diagnostic
appearance with `proofread-face`, `proofread-current-face`,
`proofread-popup-face`, `proofread-popup-source-face`, and
`proofread-popup-border-face`.

### Tuning concurrency

`proofread-max-concurrent-requests` controls the number of active requests per
buffer. It defaults to `8`; additional requests wait in a queue. Lower it when a
provider imposes rate limits or when you want to reduce the load on a local
model:

```elisp
(setq proofread-max-concurrent-requests 2)
```

At `0`, cache hits remain available but no new backend requests are sent. To
reduce cost further, lower `proofread-llm-max-diagnostic-passes` from its
default of `3` to `1`.

## Behavior and caveats

- Requests run asynchronously. A result is applied only if the text, context,
  target scope, and provider configuration still match the original request;
  stale results caused by edits are discarded.
- A remote LLM provider or non-loopback LanguageTool service receives the
  selected text and limited surrounding context, and may charge for its use.
- Request monitoring keeps source text, generated prompt text or HTTP request
  parameters, and provider responses for debugging; these fields may contain
  sensitive buffer content.
- Request-log events and displayed records omit raw checker `:options`, provider
  objects, backend handles, and other opaque backend-local objects. Logged URLs
  retain only their origin (scheme, host, and port); backend errors and related
  warnings retain only the condition kind. Checker fingerprints are derived from
  safe identity summaries, not raw options. Proofread does not recursively
  inspect opaque objects for secrets.
- `proofread-show-buffer-requests` starts recording future requests and seeds
  the log with requests that are active or queued at that moment. It cannot
  recover requests that have already finished.
- `proofread-clear` clears current diagnostics but neither the cache nor
  in-flight requests, so later results may make diagnostics reappear.
  `proofread-clear-cache` clears only the cache. Disable `proofread-mode` to
  stop all work and clear its state.
- The cache cannot detect an upgrade or model change in an externally managed
  LanguageTool server that keeps the same URL. Run `proofread-clear-cache` after
  such a change.
- Records created by `proofread-ignore` persist only for the current Emacs
  session; they are not saved, and there is no command to remove one.

## Guide for Nix users

Nix users can add both packages to an Emacs package set through the flake's
default overlay. For example, a NixOS configuration can use:

```nix
{
  inputs.emacs-proofread.url = "git+https://github.com/brsvh/emacs-proofread.git";
  inputs.nixpkgs.url = "git+https://github.com/NixOS/nixpkgs?ref=nixos-unstable";

  outputs =
    { emacs-proofread, nixpkgs, ... }:
    {
      nixosConfigurations.HOSTNAME =
        nixpkgs.lib.nixosSystem
          {
            modules = [
              (
                { pkgs, ... }:
                {
                  environment.systemPackages = [((with pkgs; emacsPackagesFor emacs-pgtk).emacsWithPackages(epkgs: with epkgs; [ proofread proofread-popup]))];
                  nixpkgs.overlays = [ emacs-proofread.overlays.default ];
                }
              )
            ];
            system = "x86_64-linux";
          };
    };
}
```

Remove `epkgs.proofread-popup` if only the core package is needed. The
`epkgs.proofread` derivation remains a normal Emacs package and does not
propagate LanguageTool or Java as runtime dependencies.

For repository development, the default `nix develop` shell and the flake's
ready-made Emacs launchers put a pinned Nixpkgs LanguageTool server on PATH.
Their development-only `languagetool-http-server` wrapper uses a 1,000-sentence
local cache. When `proofread-languagetool-config-file` is set, that explicit
properties file replaces the wrapper's cache-only default and controls the
complete server configuration.

On supported systems, the flake also provides ready-made launchers that start
Emacs with a temporary, clean init directory. Use `nix flake show` from the
repository root to find a suitable launcher, then run it with `nix run`.

These development launchers make the packages available on `load-path` and the
LanguageTool server available on `exec-path`; they do not load or configure
Proofread automatically.

## AI Assistance Disclosure

Parts of the code, tests, and documentation in this project were developed with
assistance from AI tools. All AI-generated output was reviewed and modified by
the maintainer where necessary. The maintainer remains responsible for the final
content. No secrets, private user data, or other sensitive information were
intentionally provided to AI tools.

## License

emacs-proofread is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

You should have received a copy of the GNU General Public License along with
this emacs-proofread. If not, see <https://www.gnu.org/licenses/>.

## GNU Free Documentation License

<details>
<summary>Toggle this to check the GNU Free Documentation License.</summary>

```text

                GNU Free Documentation License
                 Version 1.3, 3 November 2008


 Copyright (C) 2000, 2001, 2002, 2007, 2008 Free Software Foundation, Inc.
     <https://fsf.org/>
 Everyone is permitted to copy and distribute verbatim copies
 of this license document, but changing it is not allowed.

 0. PREAMBLE

 The purpose of this License is to make a manual, textbook, or other
 functional and useful document "free" in the sense of freedom: to
 assure everyone the effective freedom to copy and redistribute it,
 with or without modifying it, either commercially or noncommercially.
 Secondarily, this License preserves for the author and publisher a way
 to get credit for their work, while not being considered responsible
 for modifications made by others.

 This License is a kind of "copyleft", which means that derivative
 works of the document must themselves be free in the same sense.  It
 complements the GNU General Public License, which is a copyleft
 license designed for free software.

 We have designed this License in order to use it for manuals for free
 software, because free software needs free documentation: a free
 program should come with manuals providing the same freedoms that the
 software does.  But this License is not limited to software manuals;
 it can be used for any textual work, regardless of subject matter or
 whether it is published as a printed book.  We recommend this License
 principally for works whose purpose is instruction or reference.


 1. APPLICABILITY AND DEFINITIONS

 This License applies to any manual or other work, in any medium, that
 contains a notice placed by the copyright holder saying it can be
 distributed under the terms of this License.  Such a notice grants a
 world-wide, royalty-free license, unlimited in duration, to use that
 work under the conditions stated herein.  The "Document", below,
 refers to any such manual or work.  Any member of the public is a
 licensee, and is addressed as "you".  You accept the license if you
 copy, modify or distribute the work in a way requiring permission
 under copyright law.

 A "Modified Version" of the Document means any work containing the
 Document or a portion of it, either copied verbatim, or with
 modifications and/or translated into another language.

 A "Secondary Section" is a named appendix or a front-matter section of
 the Document that deals exclusively with the relationship of the
 publishers or authors of the Document to the Document's overall
 subject (or to related matters) and contains nothing that could fall
 directly within that overall subject.  (Thus, if the Document is in
 part a textbook of mathematics, a Secondary Section may not explain
 any mathematics.)  The relationship could be a matter of historical
 connection with the subject or with related matters, or of legal,
 commercial, philosophical, ethical or political position regarding
 them.

 The "Invariant Sections" are certain Secondary Sections whose titles
 are designated, as being those of Invariant Sections, in the notice
 that says that the Document is released under this License.  If a
 section does not fit the above definition of Secondary then it is not
 allowed to be designated as Invariant.  The Document may contain zero
 Invariant Sections.  If the Document does not identify any Invariant
 Sections then there are none.

 The "Cover Texts" are certain short passages of text that are listed,
 as Front-Cover Texts or Back-Cover Texts, in the notice that says that
 the Document is released under this License.  A Front-Cover Text may
 be at most 5 words, and a Back-Cover Text may be at most 25 words.

 A "Transparent" copy of the Document means a machine-readable copy,
 represented in a format whose specification is available to the
 general public, that is suitable for revising the document
 straightforwardly with generic text editors or (for images composed of
 pixels) generic paint programs or (for drawings) some widely available
 drawing editor, and that is suitable for input to text formatters or
 for automatic translation to a variety of formats suitable for input
 to text formatters.  A copy made in an otherwise Transparent file
 format whose markup, or absence of markup, has been arranged to thwart
 or discourage subsequent modification by readers is not Transparent.
 An image format is not Transparent if used for any substantial amount
 of text.  A copy that is not "Transparent" is called "Opaque".

 Examples of suitable formats for Transparent copies include plain
 ASCII without markup, Texinfo input format, LaTeX input format, SGML
 or XML using a publicly available DTD, and standard-conforming simple
 HTML, PostScript or PDF designed for human modification.  Examples of
 transparent image formats include PNG, XCF and JPG.  Opaque formats
 include proprietary formats that can be read and edited only by
 proprietary word processors, SGML or XML for which the DTD and/or
 processing tools are not generally available, and the
 machine-generated HTML, PostScript or PDF produced by some word
 processors for output purposes only.

 The "Title Page" means, for a printed book, the title page itself,
 plus such following pages as are needed to hold, legibly, the material
 this License requires to appear in the title page.  For works in
 formats which do not have any title page as such, "Title Page" means
 the text near the most prominent appearance of the work's title,
 preceding the beginning of the body of the text.

 The "publisher" means any person or entity that distributes copies of
 the Document to the public.

 A section "Entitled XYZ" means a named subunit of the Document whose
 title either is precisely XYZ or contains XYZ in parentheses following
 text that translates XYZ in another language.  (Here XYZ stands for a
 specific section name mentioned below, such as "Acknowledgements",
 "Dedications", "Endorsements", or "History".)  To "Preserve the Title"
 of such a section when you modify the Document means that it remains a
 section "Entitled XYZ" according to this definition.

 The Document may include Warranty Disclaimers next to the notice which
 states that this License applies to the Document.  These Warranty
 Disclaimers are considered to be included by reference in this
 License, but only as regards disclaiming warranties: any other
 implication that these Warranty Disclaimers may have is void and has
 no effect on the meaning of this License.

 2. VERBATIM COPYING

 You may copy and distribute the Document in any medium, either
 commercially or noncommercially, provided that this License, the
 copyright notices, and the license notice saying this License applies
 to the Document are reproduced in all copies, and that you add no
 other conditions whatsoever to those of this License.  You may not use
 technical measures to obstruct or control the reading or further
 copying of the copies you make or distribute.  However, you may accept
 compensation in exchange for copies.  If you distribute a large enough
 number of copies you must also follow the conditions in section 3.

 You may also lend copies, under the same conditions stated above, and
 you may publicly display copies.


 3. COPYING IN QUANTITY

 If you publish printed copies (or copies in media that commonly have
 printed covers) of the Document, numbering more than 100, and the
 Document's license notice requires Cover Texts, you must enclose the
 copies in covers that carry, clearly and legibly, all these Cover
 Texts: Front-Cover Texts on the front cover, and Back-Cover Texts on
 the back cover.  Both covers must also clearly and legibly identify
 you as the publisher of these copies.  The front cover must present
 the full title with all words of the title equally prominent and
 visible.  You may add other material on the covers in addition.
 Copying with changes limited to the covers, as long as they preserve
 the title of the Document and satisfy these conditions, can be treated
 as verbatim copying in other respects.

 If the required texts for either cover are too voluminous to fit
 legibly, you should put the first ones listed (as many as fit
 reasonably) on the actual cover, and continue the rest onto adjacent
 pages.

 If you publish or distribute Opaque copies of the Document numbering
 more than 100, you must either include a machine-readable Transparent
 copy along with each Opaque copy, or state in or with each Opaque copy
 a computer-network location from which the general network-using
 public has access to download using public-standard network protocols
 a complete Transparent copy of the Document, free of added material.
 If you use the latter option, you must take reasonably prudent steps,
 when you begin distribution of Opaque copies in quantity, to ensure
 that this Transparent copy will remain thus accessible at the stated
 location until at least one year after the last time you distribute an
 Opaque copy (directly or through your agents or retailers) of that
 edition to the public.

 It is requested, but not required, that you contact the authors of the
 Document well before redistributing any large number of copies, to
 give them a chance to provide you with an updated version of the
 Document.


 4. MODIFICATIONS

 You may copy and distribute a Modified Version of the Document under
 the conditions of sections 2 and 3 above, provided that you release
 the Modified Version under precisely this License, with the Modified
 Version filling the role of the Document, thus licensing distribution
 and modification of the Modified Version to whoever possesses a copy
 of it.  In addition, you must do these things in the Modified Version:

 A. Use in the Title Page (and on the covers, if any) a title distinct
    from that of the Document, and from those of previous versions
    (which should, if there were any, be listed in the History section
    of the Document).  You may use the same title as a previous version
    if the original publisher of that version gives permission.
 B. List on the Title Page, as authors, one or more persons or entities
    responsible for authorship of the modifications in the Modified
    Version, together with at least five of the principal authors of the
    Document (all of its principal authors, if it has fewer than five),
    unless they release you from this requirement.
 C. State on the Title page the name of the publisher of the
    Modified Version, as the publisher.
 D. Preserve all the copyright notices of the Document.
 E. Add an appropriate copyright notice for your modifications
    adjacent to the other copyright notices.
 F. Include, immediately after the copyright notices, a license notice
    giving the public permission to use the Modified Version under the
    terms of this License, in the form shown in the Addendum below.
 G. Preserve in that license notice the full lists of Invariant Sections
    and required Cover Texts given in the Document's license notice.
 H. Include an unaltered copy of this License.
 I. Preserve the section Entitled "History", Preserve its Title, and add
    to it an item stating at least the title, year, new authors, and
    publisher of the Modified Version as given on the Title Page.  If
    there is no section Entitled "History" in the Document, create one
    stating the title, year, authors, and publisher of the Document as
    given on its Title Page, then add an item describing the Modified
    Version as stated in the previous sentence.
 J. Preserve the network location, if any, given in the Document for
    public access to a Transparent copy of the Document, and likewise
    the network locations given in the Document for previous versions
    it was based on.  These may be placed in the "History" section.
    You may omit a network location for a work that was published at
    least four years before the Document itself, or if the original
    publisher of the version it refers to gives permission.
 K. For any section Entitled "Acknowledgements" or "Dedications",
    Preserve the Title of the section, and preserve in the section all
    the substance and tone of each of the contributor acknowledgements
    and/or dedications given therein.
 L. Preserve all the Invariant Sections of the Document,
    unaltered in their text and in their titles.  Section numbers
    or the equivalent are not considered part of the section titles.
 M. Delete any section Entitled "Endorsements".  Such a section
    may not be included in the Modified Version.
 N. Do not retitle any existing section to be Entitled "Endorsements"
    or to conflict in title with any Invariant Section.
 O. Preserve any Warranty Disclaimers.

 If the Modified Version includes new front-matter sections or
 appendices that qualify as Secondary Sections and contain no material
 copied from the Document, you may at your option designate some or all
 of these sections as invariant.  To do this, add their titles to the
 list of Invariant Sections in the Modified Version's license notice.
 These titles must be distinct from any other section titles.

 You may add a section Entitled "Endorsements", provided it contains
 nothing but endorsements of your Modified Version by various
 parties--for example, statements of peer review or that the text has
 been approved by an organization as the authoritative definition of a
 standard.

 You may add a passage of up to five words as a Front-Cover Text, and a
 passage of up to 25 words as a Back-Cover Text, to the end of the list
 of Cover Texts in the Modified Version.  Only one passage of
 Front-Cover Text and one of Back-Cover Text may be added by (or
 through arrangements made by) any one entity.  If the Document already
 includes a cover text for the same cover, previously added by you or
 by arrangement made by the same entity you are acting on behalf of,
 you may not add another; but you may replace the old one, on explicit
 permission from the previous publisher that added the old one.

 The author(s) and publisher(s) of the Document do not by this License
 give permission to use their names for publicity for or to assert or
 imply endorsement of any Modified Version.


 5. COMBINING DOCUMENTS

 You may combine the Document with other documents released under this
 License, under the terms defined in section 4 above for modified
 versions, provided that you include in the combination all of the
 Invariant Sections of all of the original documents, unmodified, and
 list them all as Invariant Sections of your combined work in its
 license notice, and that you preserve all their Warranty Disclaimers.

 The combined work need only contain one copy of this License, and
 multiple identical Invariant Sections may be replaced with a single
 copy.  If there are multiple Invariant Sections with the same name but
 different contents, make the title of each such section unique by
 adding at the end of it, in parentheses, the name of the original
 author or publisher of that section if known, or else a unique number.
 Make the same adjustment to the section titles in the list of
 Invariant Sections in the license notice of the combined work.

 In the combination, you must combine any sections Entitled "History"
 in the various original documents, forming one section Entitled
 "History"; likewise combine any sections Entitled "Acknowledgements",
 and any sections Entitled "Dedications".  You must delete all sections
 Entitled "Endorsements".


 6. COLLECTIONS OF DOCUMENTS

 You may make a collection consisting of the Document and other
 documents released under this License, and replace the individual
 copies of this License in the various documents with a single copy
 that is included in the collection, provided that you follow the rules
 of this License for verbatim copying of each of the documents in all
 other respects.

 You may extract a single document from such a collection, and
 distribute it individually under this License, provided you insert a
 copy of this License into the extracted document, and follow this
 License in all other respects regarding verbatim copying of that
 document.


 7. AGGREGATION WITH INDEPENDENT WORKS

 A compilation of the Document or its derivatives with other separate
 and independent documents or works, in or on a volume of a storage or
 distribution medium, is called an "aggregate" if the copyright
 resulting from the compilation is not used to limit the legal rights
 of the compilation's users beyond what the individual works permit.
 When the Document is included in an aggregate, this License does not
 apply to the other works in the aggregate which are not themselves
 derivative works of the Document.

 If the Cover Text requirement of section 3 is applicable to these
 copies of the Document, then if the Document is less than one half of
 the entire aggregate, the Document's Cover Texts may be placed on
 covers that bracket the Document within the aggregate, or the
 electronic equivalent of covers if the Document is in electronic form.
 Otherwise they must appear on printed covers that bracket the whole
 aggregate.


 8. TRANSLATION

 Translation is considered a kind of modification, so you may
 distribute translations of the Document under the terms of section 4.
 Replacing Invariant Sections with translations requires special
 permission from their copyright holders, but you may include
 translations of some or all Invariant Sections in addition to the
 original versions of these Invariant Sections.  You may include a
 translation of this License, and all the license notices in the
 Document, and any Warranty Disclaimers, provided that you also include
 the original English version of this License and the original versions
 of those notices and disclaimers.  In case of a disagreement between
 the translation and the original version of this License or a notice
 or disclaimer, the original version will prevail.

 If a section in the Document is Entitled "Acknowledgements",
 "Dedications", or "History", the requirement (section 4) to Preserve
 its Title (section 1) will typically require changing the actual
 title.


 9. TERMINATION

 You may not copy, modify, sublicense, or distribute the Document
 except as expressly provided under this License.  Any attempt
 otherwise to copy, modify, sublicense, or distribute it is void, and
 will automatically terminate your rights under this License.

 However, if you cease all violation of this License, then your license
 from a particular copyright holder is reinstated (a) provisionally,
 unless and until the copyright holder explicitly and finally
 terminates your license, and (b) permanently, if the copyright holder
 fails to notify you of the violation by some reasonable means prior to
 60 days after the cessation.

 Moreover, your license from a particular copyright holder is
 reinstated permanently if the copyright holder notifies you of the
 violation by some reasonable means, this is the first time you have
 received notice of violation of this License (for any work) from that
 copyright holder, and you cure the violation prior to 30 days after
 your receipt of the notice.

 Termination of your rights under this section does not terminate the
 licenses of parties who have received copies or rights from you under
 this License.  If your rights have been terminated and not permanently
 reinstated, receipt of a copy of some or all of the same material does
 not give you any rights to use it.


 10. FUTURE REVISIONS OF THIS LICENSE

 The Free Software Foundation may publish new, revised versions of the
 GNU Free Documentation License from time to time.  Such new versions
 will be similar in spirit to the present version, but may differ in
 detail to address new problems or concerns.  See
 https://www.gnu.org/licenses/.

 Each version of the License is given a distinguishing version number.
 If the Document specifies that a particular numbered version of this
 License "or any later version" applies to it, you have the option of
 following the terms and conditions either of that specified version or
 of any later version that has been published (not as a draft) by the
 Free Software Foundation.  If the Document does not specify a version
 number of this License, you may choose any version ever published (not
 as a draft) by the Free Software Foundation.  If the Document
 specifies that a proxy can decide which future versions of this
 License can be used, that proxy's public statement of acceptance of a
 version permanently authorizes you to choose that version for the
 Document.

 11. RELICENSING

 "Massive Multiauthor Collaboration Site" (or "MMC Site") means any
 World Wide Web server that publishes copyrightable works and also
 provides prominent facilities for anybody to edit those works.  A
 public wiki that anybody can edit is an example of such a server.  A
 "Massive Multiauthor Collaboration" (or "MMC") contained in the site
 means any set of copyrightable works thus published on the MMC site.

 "CC-BY-SA" means the Creative Commons Attribution-Share Alike 3.0
 license published by Creative Commons Corporation, a not-for-profit
 corporation with a principal place of business in San Francisco,
 California, as well as future copyleft versions of that license
 published by that same organization.

 "Incorporate" means to publish or republish a Document, in whole or in
 part, as part of another Document.

 An MMC is "eligible for relicensing" if it is licensed under this
 License, and if all works that were first published under this License
 somewhere other than this MMC, and subsequently incorporated in whole or
 in part into the MMC, (1) had no cover texts or invariant sections, and
 (2) were thus incorporated prior to November 1, 2008.

 The operator of an MMC Site may republish an MMC contained in the site
 under CC-BY-SA on the same site at any time before August 1, 2009,
 provided the MMC is eligible for relicensing.


 ADDENDUM: How to use this License for your documents

 To use this License in a document you have written, include a copy of
 the License in the document and put the following copyright and
 license notices just after the title page:

     Copyright (c)  YEAR  YOUR NAME.
     Permission is granted to copy, distribute and/or modify this document
     under the terms of the GNU Free Documentation License, Version 1.3
     or any later version published by the Free Software Foundation;
     with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
     A copy of the license is included in the section entitled "GNU
     Free Documentation License".

 If you have Invariant Sections, Front-Cover Texts and Back-Cover Texts,
 replace the "with...Texts." line with this:

     with the Invariant Sections being LIST THEIR TITLES, with the
     Front-Cover Texts being LIST, and with the Back-Cover Texts being LIST.

 If you have Invariant Sections without Cover Texts, or some other
 combination of the three, merge those two alternatives to suit the
 situation.

 If your document contains nontrivial examples of program code, we
 recommend releasing these examples in parallel under your choice of
 free software license, such as the GNU General Public License,
 to permit their use in free software.

```

</details>
