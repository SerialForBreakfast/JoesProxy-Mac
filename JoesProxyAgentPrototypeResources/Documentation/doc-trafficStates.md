# Traffic States

## Overview {#overview}

Each session is either plain HTTP, HTTPS inspected, or HTTPS tunneled. That state determines what metadata and body contents are available.

## Context and limitations {#context}

- Some hosts stay tunneled because of compatibility rules, certificate pinning, or missing trust.
- Inspection Reason explains why a session was inspected or tunneled.

## Next steps {#steps}

- Review HTTPS Rules if a host should stay tunneled or should be intercepted explicitly.
- If you expected readable bodies, verify certificate trust and then check the session's Inspection Reason.
