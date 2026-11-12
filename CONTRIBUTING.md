# Contributing

Small, focused pull requests and reproducible bug reports are welcome.

Before a pull request, run `./install.sh --build-only` on macOS and describe what you tested. A successful compile does not establish that UI, permissions, filesystem cleanup, or media controls work. Include your macOS version, chip architecture, Swift/Xcode version, expected result, actual result, and minimal steps to reproduce.

For changes to screenshot or tray cleanup, use disposable sample files in an isolated test account. Cover pinned files, expiration, accepted and cancelled drag operations, and disabled cleanup settings. Do not run destructive scenarios against personal files. For clipboard changes, use fictional text and images and check both ordinary content and concealed/transient pasteboard markers.

Keep API keys, certificates, provisioning profiles, `.env` files, build output, personal paths, clipboard databases, and private screenshots out of commits and issue attachments. The repository's ignore rules are a guardrail, not a substitute for reviewing a diff.

The interface is currently in Russian; English localization, runtime tests, older macOS validation, and Intel verification are useful areas for contribution. Preserve documented behavior or explain intentional changes in the pull request.

Contributions are made under the repository's MIT license.
