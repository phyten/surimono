# Security Policy

## Supported versions

Surimono is in early development. Security fixes are made on the `master` branch and shipped in the next release.

## Reporting a vulnerability

Please do **not** open a public issue for security problems.

Report vulnerabilities privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability** ([how private vulnerability reporting works](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)).

Please include:

- a description of the problem and its impact,
- steps to reproduce (a minimal sample file helps),
- the macOS and Surimono versions.

This project is maintained in spare time, so responses are best effort. You can expect a first reply within about two weeks.

## Scope

Surimono opens local files and renders HTML-based formats with WebKit. In scope are, for example, crafted documents that run unexpected code, read files the user did not open, or send data over the network without the user's consent.
