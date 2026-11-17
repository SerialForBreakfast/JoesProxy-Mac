#!/bin/bash
set -eu
evidence=build/PublicPreview/evidence
mkdir -p "$evidence"
/usr/bin/log show --last 15m --style compact --info \
  --predicate 'eventMessage CONTAINS[c] "JoesProxy" AND (process IN {"amfid","taskgated","taskgated-helper","runningboardd","launchd","kernel","syspolicyd","testmanagerd"})' \
  > "$evidence/launch.log" 2>&1 || true
host=$(find build/PublicPreview/DerivedData/Build/Products -path '*/JoesProxy.app/Contents/PlugIns/JoesProxyTests.xctest' -print -quit)
if [[ -n "$host" ]]; then
  app="${host%/Contents/PlugIns/JoesProxyTests.xctest}"
  codesign -dvv --entitlements :- "$app" > "$evidence/test-host-signature.log" 2>&1 || true
fi
if [[ -d "$evidence/filtered-calculations.xcresult" ]]; then
  ditto -c -k --keepParent "$evidence/filtered-calculations.xcresult" "$evidence/filtered-calculations.xcresult.zip"
fi
