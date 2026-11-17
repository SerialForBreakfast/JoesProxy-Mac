# Image evidence over MCP and CLI

Revision 2026-11-16. Design for the image essentials tranche.

## Decision and rationale

Extend the cache audit to answer cross-URL repetition and visual inspection to supply one
requested view. Developers can establish transfer cost first, then inspect the smallest
region that answers their question. The default result contains metadata and coverage.

Hash complete image-file bytes after HTTP content decoding and before pixel decoding.
Record the processing stage. Exclude partial ranges, truncated or evicted bodies, unsupported
encodings and validators without bodies; return counts by reason. Report known transfer
bytes separately from repeated representation bytes. Cacheability requires request context.

Use ImageIO bounds and orientation before applying a normalized top-left region. Return
source dimensions, region and result dimensions with the MCP image block. CLI saves the
same derivative to an explicit output path. Strip source metadata. OCR can return text and
optional boxes alone. Animated images require explicit frame identity. Unsupported image
formats return a structured reason. Validate encoded input, frame count, decoded pixels
and output budget before delivery. Run bounded, cancellable work off the forwarding path.

## Alternatives and consequences

URL grouping misses identical artwork at different locations. Pixel identity conflates
encodings with different transfer costs. Perceptual scores are useful for candidate discovery
and need independent false-merge calibration. Sending full images introduces disclosure
and model costs even when a count answers the question.

Use existing body-read grants for every contributing source. Recheck grant, client, epoch
and source revision before returning hashes, OCR or pixels, including cache hits. Limit
decoder memory and concurrency. Keep derived bytes out of logs and receipts.

## Acceptance

Use generated images with the same bytes at different URLs, a changed corner label, a rotated
label, an animated frame, a partial body, a revoked grant and a decompression-limit case.
Check group counts, crop geometry, readability, denied disclosure and forwarding pressure.
Measure wire bytes, image dimensions and actual model usage separately.
