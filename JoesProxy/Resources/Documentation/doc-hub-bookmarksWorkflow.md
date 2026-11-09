# Bookmarks Workflow

## Bookmarks Workflow 1 {#p1}

Use bookmarks to save repeatable requests, refresh auth from newer traffic, and replay through the running proxy.

## Bookmarks Workflow 2 {#p2}

Create a bookmark from a captured session with Add Bookmark or Command-B. JoesProxy stores the request and attaches the response body when the session was HTTPS inspected.

## Bookmarks Workflow 3 {#p3}

Use Refresh Auth for a one-click Auth + Cookies merge from the newest compatible session. Use Update From Session for guided merges with presets such as Auth Only, Headers Only, or Custom field selection.

## Bookmarks Workflow 4 {#p4}

Start the proxy, then Run Bookmark. JoesProxy sends the prepared request through the proxy and selects the matching new session when possible.

## Bookmarks Workflow 5 {#p5}

For client-side JSON mocks without calling upstream, see Bookmark Response Rewrites below. That workflow uses saved response snapshots and session-scoped intercept.

## Bookmarks Workflow 6 {#p6}

Tunneled sessions cannot be merged safely into bookmarks. Signed or one-time-token requests may still fail after refresh.

