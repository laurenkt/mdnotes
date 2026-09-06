# MDNotes

A native macOS notes app in the spirit of Notational Velocity and nvALT: a folder of markdown
files, one field that searches and creates, a list, an editor. Built to be instant.

- Spec: [docs/SPEC.md](docs/SPEC.md)
- Plan: [docs/PLAN.md](docs/PLAN.md)
- Decisions: [docs/adr/](docs/adr/)
- Agent protocol: [CLAUDE.md](CLAUDE.md)

To run the agent: open a Claude Code session in this directory and type `/loop /next-task`.

```
scripts/setup.sh         once
scripts/check.sh quick   build and test
scripts/bundle.sh        produce build/MDNotes.app
```
