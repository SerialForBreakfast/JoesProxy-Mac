# Capture Capacity and Missing History

## Overview {#overview}

JoesProxy reserves memory for traffic being captured and separately limits the history you keep. Open Details on the capacity notice to see which limit affected your evidence.

## Context and limitations {#context}

- During busy capture, JoesProxy can skip a response body while retaining headers and timing. If even those details cannot fit, the request is absent from history. Traffic continues and capture recovers automatically.
- When saved bodies exceed the history budget, older bytes are removed. The session remains and the inspector explains which body was removed.
- When the session limit is reached, the oldest whole sessions are removed. Compact shows both history removal counts since the last clear or recording load.

## Next steps {#steps}

- For repeated busy episodes, lower Per-Response Body Cap in Settings → Advanced → Long Capture Storage or reduce concurrent requests.
- For longer history, increase the appropriate retention limit or save a recording before older data is removed. Changing settings cannot restore missing evidence.
- Dismiss a recovered episode after reviewing its counts. A later episode appears separately.
