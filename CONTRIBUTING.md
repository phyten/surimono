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

Build and test instructions will be documented in the README together with the Xcode project.

## Commit messages

Commits follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```text
feat(print): A5 冊子レイアウトを追加
fix(org): 表の区切り線を正しく描画する
docs: add build instructions
```

The maintainer writes commit descriptions in Japanese; English is equally welcome.

## Code style and tests

- Swift code will be formatted and linted with `swift format`. The configuration and commands will be added together with the Xcode project.
- New behavior should come with tests, and test names should describe the behavior.
- Surimono must never modify the files it opens.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
