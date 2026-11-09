# Build and try JoesProxy

Revision 2026-11-08 for source version 1.9.0 (23).

## Requirements

The app target is macOS 15.1 or newer. The source was last built and tested with Xcode 27.0, build 27A266a. The companion SDK manifest requires Swift tools 6.3. Physical older-OS acceptance remains pending. Optional local model features require macOS 26 and an available system model.

Use a copy of the source on a Mac with the full Xcode toolchain selected. Check the selected version with `xcodebuild -version`. Source builds need the dependency versions recorded in Package.resolved. The release automation's Ruby tooling is optional for this walkthrough.

## First dependency download

On your own development machine, the first command below downloads the pinned packages into build/PublicPreview/SourcePackages. It requires network access and is an explicit setup action. Later commands reuse those checkouts.

```sh
bash memlog/utility_scripts/public_preview_build.sh resolve
```

Keep the checked-in lockfiles unchanged. A resolution error requires inspecting the selected Xcode version, network access and pinned dependencies before choosing any update.

## Build

```sh
bash memlog/utility_scripts/public_preview_build.sh build
```

This checks compilation with signing disabled. Running the app and its hosted tests requires suitable local signing. The checked-in project contains the original maintainer's team settings. Select your own signing configuration for a runnable development build, or use a separately verified installer when available.

The helper verifies Xcode 27.0 and unchanged lockfiles, and stores packages, products and evidence under build/PublicPreview by default. The app product is under build/PublicPreview/DerivedData/Build/Products/Debug/JoesProxy.app. Its CLI is Contents/MacOS/joesproxyctl inside the app. Offline commands work before agent enrollment:

```sh
build/PublicPreview/DerivedData/Build/Products/Debug/JoesProxy.app/Contents/MacOS/joesproxyctl version --json
build/PublicPreview/DerivedData/Build/Products/Debug/JoesProxy.app/Contents/MacOS/joesproxyctl docs list --format json
```

## Five-minute HTTP walkthrough

Use a runnable local build or verified installer. This synthetic example uses the loopback interface, a one-request HTTP server and ordinary curl. It needs neither device setup nor HTTPS certificate trust.

1. Launch JoesProxy. Read the [privacy guide](PRIVACY.md), including rolling disk recovery. Note the displayed proxy port, then choose **Start Proxy**.
2. In one Terminal, start a one-request local fixture on an unused port:

   ```sh
   printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 29\r\nConnection: close\r\n\r\n{"items":[{"state":"ready"}]}' | nc -l 127.0.0.1 8088
   ```

3. In another Terminal, explicitly send a request through the proxy. Substitute the displayed proxy port if it differs from 9090:

   ```sh
   curl --noproxy "" --proxy http://127.0.0.1:9090 http://127.0.0.1:8088/items
   ```

4. Expect `{"items":[{"state":"ready"}]}`. Select the /items row in JoesProxy. Inspect its GET method, 200 response, JSON content type and body.
5. Choose **Stop Proxy**. If the fixture Terminal is still waiting, stop that command with Control-C. Review any saved capture/recovery data using the privacy guide.

The walkthrough passed an authorized UI-lane test using real synthetic loopback HTTP: Start, capture of /items with status 200, exact JSON-body inspection through accessibility and Stop. The test uses isolated storage and suppresses launch recovery; it does not establish the default recovery experience or manual installer acceptance. A port already in use or a local signing/setup failure should be resolved before interpreting missing traffic as a proxy defect.

## Tests

With a runnable test signing configuration and pinned dependencies already present, run the serial unattended Policy plan:

```sh
xcodebuild test -project JoesProxy.xcodeproj -scheme JoesProxy -testPlan JoesProxy-Policy -destination "platform=macOS" -derivedDataPath build/PublicPreview/DerivedData -clonedSourcePackagesDirPath build/PublicPreview/SourcePackages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO
```

The companion SDK's macOS tests can run separately:

```sh
bash memlog/utility_scripts/public_preview_build.sh sdk
```

Use one native build/test lane at a time. UI, smoke and screenshot plans take keyboard/window focus and require explicit local permission. Existing results and deferrals are in [source validation](VALIDATION.md).
