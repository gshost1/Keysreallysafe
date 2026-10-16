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

Display-wake check on the installed build, 2026-09-22 23:00 PDT: `pmset
displaysleepnow`, then a user wake. `menubar.log` gained exactly one line,
`menubar item recovered: NSWorkspaceScreensDidWakeNotification`, from the same
process, and the user confirmed the item was still visible afterwards. This
exercises the trigger from the 22:19 incident but not full system sleep, unlock,
or a display reconfiguration, and it does not reproduce the original loss.

## Seeding the item's preferred position — 2026-10-15

A second, unproven mitigation for the item being hidden on a full notched menu
bar. This was inferred, not seen on screen: a read-only check found the installed
app's defaults domain `com.keysreallysafe.keysrs` held no
`NSStatusItem Preferred Position Keysreallysafe.usage` key after two days of
running. AppKit reads that key (a point distance from the right edge of the menu
bar) when the autosave name is applied; with no saved value it places the item far
left, which is the first spot macOS drops when the bar is full on a notched
display. So the leading explanation for the item never appearing is simply that it
was placed off the usable area, not the disconnected-scene bug the recovery path
above addresses.

The mitigation is seed-if-absent: `MenubarPosition.seedIfUnset` writes a preferred
distance only when no position key exists and the item is not user-hidden
(`NSStatusItem Visible Keysreallysafe.usage == false`). It never overwrites a
position the user dragged the item to, and it never un-hides an item the user chose
to hide. The seeded constant is 200 points from the right edge; this is a guess,
not a measured value — there is no reproduction to tune it against.

This is not a proven fix: the disappearance was never reproduced on screen, and the
constant is unmeasured. Roll it back with one command, after which macOS falls back
to its own placement:

```sh
defaults delete com.keysreallysafe.keysrs "NSStatusItem Preferred Position Keysreallysafe.usage"
```
