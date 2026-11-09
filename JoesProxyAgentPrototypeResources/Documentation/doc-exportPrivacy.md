# Export And Privacy

## Overview {#overview}

Export saves the current session set to a shareable file. Exported traffic may include headers, cookies, bodies, and other sensitive request data.

## Context and limitations {#context}

- JSON recordings preserve the JoesProxy workspace model more faithfully than HAR.
- HAR is useful for interoperation, but JoesProxy-specific state may not round-trip exactly.

## Next steps {#steps}

- Choose Selected when you only need the active request set, and All when you need the whole session workspace.
- Review files before sharing them outside your team because exports can include sensitive data.
- Pick a Recording Save Mode appropriate for your data sensitivity when saving recordings.
