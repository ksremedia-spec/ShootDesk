---
name: builds-are-local
description: "ShootDesk is built and tested locally on Kyle's Mac; GitHub's cloud build is no longer needed"
metadata:
  node_type: memory
  type: project
  originSessionId: 66dfb66d-09cb-4e49-8ba8-296233a824a0
  modified: 2026-10-19T20:40:41.506Z
---

As of 2026-10-19 Kyle builds ShootDesk locally on his Mac (Xcode 27.1, Duo simulator) and said "we no longer need github to build anymore - we're local."

**Why:** the GitHub Actions build (`.github/workflows/build.yml`) existed because there was no Mac; now there is.

**How to apply:** don't suggest pushing so GitHub can build, and don't treat a green GitHub run as the check; build and run locally. The workflow was deleted Oct 19 (commit 8b8553c); a push only stores the code.
