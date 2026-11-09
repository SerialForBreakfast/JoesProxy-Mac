# Replace an image

## Scope and authority {#safety}

Use a synthetic image or an asset the user authorizes. A documentation read grants no filesystem, body-access, mutation or device-control authority. Keep matching narrow and client-scoped. Agents can prepare and request activation; only the local user resolves human approval.

## Inspect the actual request {#inspect}

Find the target client's image request in retained traffic. Inspect the final host, path and query: the JSON reference may be relative, resized or transformed before fetching. Confirm the intended resource, not merely a filename shared by sibling endpoints. Missing traffic is not evidence of client caching. Ask the user for one concrete target action if no relevant request has been observed.

## Prepare immutable bytes {#prepare}

Use the discovered response-edit or coordinated bundle preparation surface, depending on whether JSON references also change. Register the binary through supported opaque file references. Review status, MIME inferred from bytes, dimensions, byte length, matcher and client scope. When changing JSON too, prepare the response and image in the same revision. Prefer a content-versioned URL only when the target can route it; otherwise explicitly review retained-URL cache risk. Do not encode image bytes into tool text.

## Prove delivery and clean up {#observe}

After required approval, record an observation marker and ask the user to refresh the relevant view. Read all bounded delivery evidence pages, correlating the served revision and asset hash. Distinguish no request, mismatch, application failure and completed delivery. Rendering requires human or external confirmation; successful proxy delivery is not enough. Stop the owned effect and verify cleanup, retaining actionable partial failures.
