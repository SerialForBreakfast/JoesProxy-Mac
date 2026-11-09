# Export Visualization

## Overview {#overview}

Export Visualization turns captured traffic into shareable PNG charts. V1 supports Session Timeline, Request Waterfall, and Host Health Summary using the same preview you see before export.

## Context and limitations {#context}

- Each chart type accepts a different scope: timelines use selected or filtered sessions; waterfalls add host and time-range scopes; host health uses filtered results or host selections.
- Redaction defaults remove auth headers, cookies, tokens, query parameters, user identifiers, raw bodies, and artwork before labels appear in the PNG.
- PNG is the only V1 export format. PDF, SVG, and interactive dashboards are deferred.
- Footer metadata can include provenance notes such as partial capture or stripped bodies when the source data was incomplete.

## Next steps {#steps}

- Open Export Visualization from the session toolbar when you have a selection or filtered working set.
- Pick the chart type, confirm scope in the sidebar, then review the preview warnings before exporting PNG.
- Keep redaction enabled unless you explicitly need raw values for an internal-only artifact.
- Use HD or QHD for slides; 4K only when you need maximum label density on a large display.

