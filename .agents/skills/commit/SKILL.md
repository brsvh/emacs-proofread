---
name: commit
description: >-
  Write a GNU Coding Standards Change Log style Git commit message for the
  currently staged changes and create the commit. Use when the user asks to
  commit staged changes, automatically write a commit message, follow GNU
  Change Log style, add the required Assisted-by trailer, or use the
  project-local commit workflow.
---

# Commit

## Overview

Commit exactly the currently staged Git changes with a message that follows the
GNU Coding Standards section "Style of Change Logs" and ends with the required
`Assisted-by` trailer.

## Workflow

1. Verify staged changes exist:

   ```bash
   git diff --cached --quiet
   ```

   If this exits `0`, stop and report that there are no staged changes.

2. Gather staged-only context:

   ```bash
   scripts/staged-commit-context
   ```

3. Read `references/gnu-change-log-style.md`.

4. Determine trailer fields before drafting the final message:

   - `AGENT_CONFIG`: Locate the current agent's active configuration through the
     runtime-provided config path, config-home environment variable, CLI or
     session metadata, or the agent's documented config discovery rules. Do not
     hard-code a user-specific, repository-specific, or different-agent config
     path. Parse the file using its structured format when practical.
   - `AGENT_NAME`: Prefer the exact agent name or display name declared by
     `AGENT_CONFIG`. If the config does not declare one, use the current agent
     name exactly as given by the active agent context.
   - `MODEL_VERSION`: Prefer the exact active model declared by `AGENT_CONFIG`.
     If the config uses profiles, providers, or per-agent sections, resolve the
     active section and merge overrides according to that agent's config
     semantics before selecting the model. If the config does not provide a
     model, use the exact model version exposed by the runtime or higher-level
     agent configuration. Do not guess a model family; if the exact model
     version cannot be determined, stop and report the problem.
   - `TOOL`: Include only external code analysis tools actually invoked during
     this commit workflow. Record each tool once, in first-use order, as
     `[TOOL_NAME]`. If no external code analysis tool was called, omit all tool
     tokens. Do not record Git, shell, file read/search/edit helpers, commit
     helper scripts, formatters, or the final `git commit` command as tools.

5. Draft a commit message that uses the staged diff only and ends with one
   trailer line:

   ```text
   Assisted-by: AGENT_NAME:MODEL_VERSION [TOOL1] [TOOL2]
   ```

   If there are no tool tokens, write only
   `Assisted-by: AGENT_NAME:MODEL_VERSION`.

6. Write the message to a temporary file.

7. Validate the message line lengths before committing:

   ```bash
   awk 'NR == 1 && (length($0) > 68 || $0 !~ /\.$/) { exit 1 }
        NR > 1 && length($0) > 72 { exit 1 }' /tmp/commit-message
   ```

   If validation fails, rewrite the message so the header is at most 68
   characters and every body line is at most 72 characters.

8. Commit with:

   ```bash
   git commit -F /tmp/commit-message
   ```

9. Report the new commit hash and subject. If `git commit` fails, report the
   error and stop.

## Message Requirements

- The first line must be a complete-sentence header summarizing the changeset,
  ending with a period, not a Conventional Commit prefix.
- Keep the first line at 68 characters or fewer.
- Keep every body line after the first line at 72 characters or fewer, including
  free-text paragraphs, ChangeLog entries, and the `Assisted-by` trailer.
- Do not include the ChangeLog date/author line in Git commit messages.
- After the header, include an optional free-text description when it clarifies
  the overall idea, rationale, relationship between files, issue discussion,
  moves, deletions, or other information not obvious from the diff.
- After any free-text description, list changed files and entities using the
  project-local ChangeLog entry syntax documented below.
- Use `* file: (entity): Description.` for entries that name a changed function,
  macro, variable, command, target, option, or definition.
- Use `* file: Description.` for file-level entries without a changed entity.
- When a ChangeLog entry wraps, start continuation lines at column 1 with no
  leading whitespace.
- Prefer listing modified functions, macros, variables, commands, targets, or
  definitions whenever practical.
- For function, macro, variable, command, target, or definition entries, explain
  the purpose of the addition, removal, or change. Do not use bare descriptions
  such as "New function.", "New variable.", "Removed.", or "Deleted." unless the
  surrounding text already states the motivation clearly.
- Name changed entities in full; do not abbreviate names or use brace-combined
  shorthand such as `{insert,jump-to}-register`.
- Do not put blank lines between individual file entries in the same change
  entry.
- Do not omit the filename and leading asterisk for successive entries in the
  same file; write a complete `* file: ...` entry each time.
- For simple comment or documentation-only edits, a file-level entry such as
  `Doc fixes.` is acceptable.
- For broad mechanical changes, describe the underlying change instead of
  enumerating every affected caller or file.
- Treat test suite files as code for change-log purposes.
- Separate the final `Assisted-by` trailer from the ChangeLog entries with one
  blank line.
- The `Assisted-by` trailer must be the last non-empty line of the commit
  message.
- Do not add empty brackets, placeholder tool names, or trailing whitespace when
  no external code analysis tools were called.

## Safety Rules

- Do not stage files; commit only what is already staged.
- Do not include unstaged or untracked changes in the message.
- Do not amend, squash, rebase, push, tag, or change authorship unless the user
  explicitly asks.
- Do not invent issue numbers, mailing-list references, authors, co-authors,
  sign-offs, tool names, or trailers other than the required `Assisted-by`
  trailer.

## Resources

- `scripts/staged-commit-context`: Print staged file names, stats, and diff.
- `references/gnu-change-log-style.md`: Project-local GNU ChangeLog style guide
  derived from the GNU Coding Standards.
