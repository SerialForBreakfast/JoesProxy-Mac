[.. | objects | select(.nodeIdentifier? == $id) |
  ([.. | objects | select(.nodeType? == "Repetition")] |
    if length > 0 then . else empty end) // [.] |
  .[] | select(.result == "Passed")] | length
