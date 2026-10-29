# Contributing to Surimono

Thanks for your interest in Surimono! This is a small project maintained in spare time. Issues and pull requests are welcome in **English or Japanese** (日本語でも大丈夫です).

## Reporting bugs and requesting features

- Search existing issues first.
- Use the issue templates. For bugs, include the macOS version, the Surimono version, the file type and, if possible, a minimal sample file with anything private removed.
- For security problems, do **not** open a public issue. Follow [SECURITY.md](SECURITY.md) instead.

## Development workflow

- `master` is protected: changes land through pull requests, and CI must pass before merging.
- Create a topic branch from `master`, for example `feat/booklet-signatures` or `fix/org-tables`.
- Keep pull requests focused. Several small, logical commits are preferred over one large commit.
- Fill in the pull request template, including how you tested the change.

Run `make build` to build the app, `make lint` to check formatting, and `make test` to run package and hosted app tests. See the README for toolchain requirements and other commands.

Debug builds (`make build`, `make run`, and the host app of the hosted tests) are a separate app named **Surimono Dev**, with the bundle ID `io.github.phyten.Surimono.debug` and a dark icon with a yellow DEV band. They keep their own preferences and store styles, presets, and per-document settings in `~/Library/Application Support/Surimono Dev/`, so you can run them next to an installed Surimono without touching its data. The menu bar still shows "Surimono".

## Commit messages

Commits follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```text
feat(print): A5 冊子レイアウトを追加
fix(org): 表の区切り線を正しく描画する
docs: add build instructions
```

The maintainer writes commit descriptions in Japanese; English is equally welcome.

## Code style and tests

- Format Swift code with `make format` and check it with `make lint` (`xcrun swift-format`, configured in `.swift-format`).
- New behavior should come with tests, and test names should describe the behavior.
- Surimono must never modify the files it opens.

## AI-assisted contributions

This repository includes instructions for coding agents: [AGENTS.md](AGENTS.md) (shared by all agents), [CLAUDE.md](CLAUDE.md), path-specific rules in `.claude/rules/`, and project skills in `.agents/skills/` (also visible to Claude Code through `.claude/skills/`). These files are written in Japanese. AI-assisted contributions are welcome, but you are responsible for reviewing and testing everything you submit.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
