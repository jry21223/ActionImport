# Issue tracker: Local Markdown

Issues and specs for this project live in `.scratch/`.

- One feature per directory: `.scratch/<feature-slug>/`.
- The spec is `.scratch/<feature-slug>/spec.md`.
- Each implementation ticket has its own file: `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`.
- Triage state is a `Status:` line near the top of an issue. Use the role strings in `triage-labels.md`.
- Blocking dependencies are a `Blocked by:` line listing ticket numbers.
- Comments and conversation history append under `## Comments`.

When a skill says to publish to the issue tracker, write the appropriate local Markdown file. When it says to fetch a ticket, read the referenced issue file.
