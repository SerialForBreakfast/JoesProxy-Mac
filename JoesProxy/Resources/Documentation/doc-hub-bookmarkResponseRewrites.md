# Bookmark Response Rewrites

## Bookmark Response Rewrites 1 {#p1}

Use this workflow when you want the client app to receive a modified JSON response without changing the upstream server.

## Bookmark Response Rewrites 2 {#p2}

Create a bookmark from a captured session. JoesProxy stores the response body automatically when the session was HTTPS inspected and the body is available.

## Bookmark Response Rewrites 3 {#p3}

In the Saved Response viewer, right-click a field in Folder or Prettified view to prefill the rewrite path. Nested objects use dot notation such as movie.shortDescription. Arrays use bracket indexes such as items[0].title. Use JSON value type for whole-array overrides such as castNames.

## Bookmark Response Rewrites 4 {#p4}

Toggle Preview Patches to confirm overrides against the saved snapshot. Start the proxy, then tap Enable for Session. The banner shows waiting state, last intercept details, and recent mismatched paths when the app calls a different URL.

## Bookmark Response Rewrites 5 {#p5}

Matching sessions should show a bookmark response rewrite source with applied and skipped field paths. If paths fail validation, use Refresh Saved Response from the latest matching captured session.

## Bookmark Response Rewrites 6 {#p6}

Bookmark response rewrites are session-scoped. Stopping the proxy clears enablement until you enable again. They differ from global Local Overrides (Map Local, Block, Map Remote), which apply until disabled or removed.

