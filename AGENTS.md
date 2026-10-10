# ActionImport

A Mac utility for importing new footage from a configured DJI Osmo Action 6. Start with the author's own camera and Mac; validate the complete import flow before expanding the product.

## Agent skills

### Issue tracker

Issues and specs are local Markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five standard triage role strings. See `docs/agents/triage-labels.md`.

### Domain docs

Use a single-context glossary and ADR layout. See `docs/agents/domain.md`.

## Footage handling

Read source footage without modifying it. Only mark a file imported after successful copy verification. Never overwrite a different destination file or report an incomplete copy as successful.

## Engineering

Follow the user-level remote synchronization gate and Matt Pocock engineering flow. Preserve unrelated work. Use native macOS APIs and avoid dependencies without a demonstrated need. Keep file operations away from the UI thread. Report fixture tests, app launch, camera detection and real-footage import as separate validation results.
