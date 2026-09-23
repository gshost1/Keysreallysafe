# Menu bar recovery — 2026-09-22

The installed process remained responsive while its menu bar item was absent.
A pre-restart sample showed the main thread waiting normally in AppKit's event
loop; the dashboard returned HTTP 200. System logs recorded repeated AppKit
`auxiliary scene activation failed` errors for that process. After the 22:19
display wake, another scene invalidation error occurred at 22:20. Restarting at
22:43 created a new visible status item and the user confirmed it returned.
This supports a disconnected status-item scene as the leading explanation;
the exact disappearance was not reproduced and these errors alone do not prove
its trigger. The restart removed the old in-memory state.

`MenubarItemController` now owns the status item independently of the dashboard
and services. It coalesces wake, display-wake, session-activation, and screen
configuration notifications, waits two seconds for the transition to settle,
then removes and recreates the item with its existing title, tooltip, and menu.
It uses a stable autosave name for placement. Recovery waits while a menu is
open and resumes after it closes. The existing refresh checks for an explicitly
invisible item, missing button, or missing window. It does not treat offscreen
coordinates as failure, because full screen, auto-hide, and crowding are normal.
Shutdown cancels recovery and removes observers and the status item.

This is event-driven recovery even when `isVisible` is incorrectly true. It is
not a claim that the underlying macOS scene bug is fixed, or that all possible
causes of an invisible item can be detected. A disconnected scene arising
without a subscribed transition and with apparently healthy AppKit properties
can still require further diagnosis. Recovery writes its reason to menubar.log.

Validation: 16 menu bar tests passed, including four new tests using real AppKit
status items and injected notification centers: visible-but-stale replacement,
menu preservation, deferral while open, recovery after close, explicitly hidden
item repair, healthy refresh stability, burst coalescing, and shutdown cancellation.
These simulate notifications; no physical sleep/wake reproduction was performed.

Independent read-only review found no blocking issues. The release build passed,
was signed with the existing stable Apple identity, and was installed through
`keys autostart` using the existing installed web assets. The installed binary
hash matched the release binary and the dashboard returned HTTP 200 afterward.
This local update has not been newly notarized or published.

Workflow tracker status failed because trial-01-04 is missing or duplicated in
the existing Desktop work log. No duplicate trial entry was created. Existing
licensing, stylesheet, acceptance-document, and UI-test changes were preserved.
