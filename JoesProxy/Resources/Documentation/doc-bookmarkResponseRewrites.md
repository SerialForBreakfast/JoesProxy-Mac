# Bookmark Response Rewrites

## Overview {#overview}

Bookmark Response Rewrites intercept matching requests and return a saved JSON snapshot with selected field values replaced. This is session-scoped mock behavior tied to a bookmark, not a global Map Local rule.

## Context and limitations {#context}

- Adding a bookmark saves the captured response automatically so you can configure field overrides against real JSON.
- Rewrites do not affect traffic until you enable them for the current proxy session and the client makes a new matching request.
- Use nested dot paths such as movie.shortDescription. Top-level field names only work when the value lives at the JSON root.
- A green checkmark means the path exists in the saved response; an orange warning means the override will be skipped at runtime.
- Stopping the proxy clears session enablement. Re-enable after restart before testing again.

## Next steps {#steps}

- Open Bookmarks, select a bookmark, and review the Saved Response JSON in Folder or Prettified view.
- Right-click a JSON field and choose Add Field Rewrite to prefill the path and current value.
- Add one or more overrides, toggle Preview Patches to verify the saved snapshot, then start the proxy.
- Tap Enable for Session, re-trigger the request in your client, and confirm the session shows a bookmark response rewrite source.
- Bookmark the exact endpoint the app calls. A movies/… bookmark will not rewrite movie/metadata/… traffic.

