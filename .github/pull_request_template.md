<!--
PR title: use a Conventional Commit, e.g. `fix(restore): verify checksum`,
`feat(schedule): ...`, `docs: ...`. See CONTRIBUTING.md.
-->

## Summary

What does this change and why?

## Related issue

Closes #

## Checklist

- [ ] PR title follows Conventional Commits (`type(scope): summary`)
- [ ] `shellcheck -S error dbx lib/*.sh` is clean
- [ ] `bash -n` passes on `dbx` and `lib/*.sh`
- [ ] `bats tests/unit/` passes (and `bats tests/integration/` if Docker-affecting)
- [ ] Tests added/updated for the behavior changed
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` (if user-facing)
- [ ] Docs updated (`docs/` + `mkdocs.yml` nav, if a public command/page changed)
