# Traffic States

## Traffic States 1 {#p1}

JoesProxy decrypted the connection, so request and response details are available in the inspector.

## Traffic States 2 {#p2}

The connection stayed encrypted end-to-end. You can still see metadata such as host, timing, and status, but not decrypted bodies.

## Traffic States 3 {#p3}

Explains why a session was inspected or tunneled, such as an explicit HTTPS rule, compatibility bypass, or missing trust.

## Traffic States 4 {#p4}

Some apps reject the proxy-generated certificate even when the device trusts the Root CA. Those hosts usually need to stay tunneled.

