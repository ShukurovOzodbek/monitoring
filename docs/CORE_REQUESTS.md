# MonitorCore requests

- Record user and system CPU percentages as separate timestamped series in `MetricHistory`. The CPU page can then stack measured values over time. It currently plots measured total usage and shows a separate bar for the current split.
- Accept optional `processHistory` and `watchedHistory` in the preview initializer. Standalone inspector and Watched previews currently pass their synthetic histories directly to the views. Store-backed previews cannot seed those series.
- Expose timestamped storage-capacity and endpoint-state summaries for Overview sparklines. Add per-process energy attribution if available for the Battery card. Storage and endpoint activity also need explicit attribution metrics before they can have process rankings. Disk throughput and system-wide network traffic measure different things.
- Optionally expose a core type for each `CoreUsage` if the platform reports it. The UI currently shows numbered cores and separate performance and efficiency counts.
- Guard `checkNow(id:)` against stale results if the endpoint is edited or deleted while a manual check is in flight.
