# GNU Change Log Style

This skill follows the GNU Coding Standards, "Style of Change Logs":
https://www.gnu.org/prep/standards/standards.html#Style-of-Change-Logs

## Git Commit Shape

Use this shape for Git commits:

```text
Header line as a complete sentence.

Optional free-text description of the overall change, rationale, relation
between changed files, moved or deleted code, issue discussion, or other
context not obvious from the diff.

* path/to/file: (changed-entity): Description of the specific change.
Continuation lines start at column 1 with no leading whitespace.
* path/to/other-file: Description of a file-level change.

Assisted-by: AGENT_NAME:MODEL_VERSION [TOOL1] [TOOL2]
```

The GNU date/author line is required for separate ChangeLog files, but not for
VCS commit messages.

The `Assisted-by` trailer is required for this project-local commit workflow.
Use the active agent name and exact model version from the current agent
configuration when available. Locate that configuration through the runtime
provided config path, config-home value, session metadata, or the agent's
documented discovery rules, not a hard-coded user or repository path. Include
bracketed external code analysis tool names only when such tools were actually
called. If no external code analysis tool was called, omit the bracketed tool
fields.

## Required Rules

- Start with a single header line that is a complete sentence summarizing the
  changeset. End the header with a period.
- Keep the header line at 68 characters or fewer.
- Keep every body line after the header at 72 characters or fewer, including
  free-text paragraphs, ChangeLog entries, and the `Assisted-by` trailer.
- Keep one commit per logical changeset.
- After the header, explain the overall change as much as needed for clear
  software forensics.
- Include rationale, main ideas, relationships between files or functions,
  moves, deletions, and issue or discussion references when known.
- Follow the free-text description with a list of changed files and entities
  whenever practical.
- Use `* file: (entity): Description.` for entries that name a changed function,
  macro, variable, command, target, option, or definition.
- Use `* file: Description.` for file-level entries without a changed entity.
- When a ChangeLog entry wraps, start continuation lines at column 1 with no
  leading whitespace.
- When describing functions, macros, variables, commands, targets, or other
  definitions, state why the entity was added, removed, or changed. Avoid bare
  labels like `New function.`, `New variable.`, `Removed.`, or `Deleted.`;
  prefer purpose-oriented text such as `Add ... to support ...` or
  `Remove ... now that ... handles ...`.
- Name modified functions, macros, variables, data structures, targets, and
  other definitions in full.
- Do not abbreviate entity names.
- Do not combine names with shorthand that prevents searching for the complete
  name.
- Do not put blank lines between individual changes in one entry.
- For long lists of function names, keep each complete entity name searchable
  and avoid hanging indentation.
- Do not omit the filename and leading asterisk for successive entries in the
  same file; write a complete `* file: ...` entry each time.
- For simple changes, the file entry can be the whole description.
- For comments or doc strings, a file-level `Doc fixes.` style entry is enough.
- For a calling sequence change where all callers are updated, write the change
  at the called function and add `All callers changed.`
- For mechanical changes across many files, describe the underlying change
  instead of enumerating every file.
- Treat test suite files as code.
- End the Git commit message with the required `Assisted-by` trailer, separated
  from the GNU ChangeLog entries by one blank line.
- Do not add empty tool brackets or placeholder tool names.

## Examples

```text
Handle undecoded terminal input.

* lisp/term.el: (term-emulate-terminal): Avoid errors if the whole
decoded string is eight-bit characters.  Do not save the string for
next iteration in that case.
* test/lisp/term-tests.el: (term-decode-partial): Test partial
input handling so the decoder regression stays covered.
* test/lisp/term-tests.el: (term-undecodable-input): Test
undecodable input handling so the decoder regression stays covered.

Assisted-by: Codex:gpt-5.5
```

```text
Port tputs detection to tinfow.

* configure.ac: (tputs_library): Also try tinfow and ncursesw.

Assisted-by: Codex:gpt-5.5 [ruff]
```

```text
Update project-local commit skill.

* .codex/skills/commit/SKILL.md: Define the staged-only commit
workflow and project-local ChangeLog message requirements.
* .codex/skills/commit/references/gnu-change-log-style.md: Document
the project-local interpretation of the GNU ChangeLog style for Git
commits.
* .codex/skills/commit/scripts/staged-commit-context: Add staged diff
context collection.

Assisted-by: Codex:gpt-5.5
```
