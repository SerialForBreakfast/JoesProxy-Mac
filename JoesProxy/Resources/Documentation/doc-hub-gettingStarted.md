# Getting Started

## Capture a first request {#p1}

Choose Start First Capture, choose the device making the request and start the proxy in the Inspector toolbar. Route one plain HTTP request through the displayed proxy address. Select its row to see the method, status and response. You can do this before setting up HTTPS or connecting an agent.

## Choose where to capture {#p2}

For this Mac, point your test client at the displayed proxy port. For a phone, simulator or TV, open that target’s setup guide. Trust for HTTPS belongs on the device making the request.

## Set up HTTPS on this Mac {#p3}

Open HTTPS Setup and follow the action shown to create or install your local JoesProxy Root CA. If trust is required, open Keychain Access, select the login keychain and find the certificate identified in setup. Open its details, expand Trust, choose Always Trust for that certificate and save the change. Return to JoesProxy and choose Check Again if needed.

## Verify HTTPS inspection {#p4}

When setup shows Ready for HTTPS inspection, send a fresh HTTPS request through the running proxy and choose Verify Capture. Select the request and look for its response body. A tunneled connection can forward successfully while its contents remain hidden.

## Enroll the bundled CLI {#p5}

Open MCP Management, start MCP in Overview and open Clients. Select JoesProxy CLI and choose Add Client. Start with Metadata Only for basic inspection. Copy the displayed login command and run it in Terminal. When the credential prompt appears, copy the one-time credential there and press Return. Keep the credential on this Mac.

## Check the connection {#p6}

After login reports stored, use the same joesproxyctl executable to run auth status, then status. The first checks local credential storage and the second contacts the running service. If configured is false, finish login in Terminal. If the service cannot be reached, check Overview for the MCP listener and Clients for the active enrollment.
