---
name: no-hint-text
description: "Kyle doesn't want instruction/hint captions in his app's UI (\"Sends when you pause\", \"Hold to ask\", \"Tap a town to…\")"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 66dfb66d-09cb-4e49-8ba8-296233a824a0
  modified: 2026-10-21T18:23:46.786Z
---

Don't add hint or instruction text to ShootDesk's screens (things like "Sends when you pause", "Hold to ask", "Let go to send, slide up to cancel"). Kyle said on 2026-10-21: "i never need those type of hints in the final app when app building - you do it often."

**Why:** they clutter the UI; the design itself should make the action obvious.

**How to apply:** use icons, motion, haptics and sound for feedback instead of captions. Keep only real status (errors, download progress, "Listening") and real content. When reviewing screens, flag existing hint captions as candidates to remove rather than adding new ones. Related: [[builds-are-local]].
