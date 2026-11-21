# Security Policy

CPU Guard can run an optional **privileged helper** (a root launch daemon reached over XPC) that reads process information and can send signals to processes. Because of that, security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's private reporting instead:
**Security → Report a vulnerability** on this repository.

Include what you found, the macOS version, and steps to reproduce. You'll get a reply as soon as I can manage, and I'll credit you in the release notes if you'd like.

## Scope

- The helper daemon and its XPC interface
- Anything that lets an unprivileged process act through the helper
- Anything that causes CPU Guard to terminate or signal the wrong process

## Supported versions

Only the latest release receives security fixes.
