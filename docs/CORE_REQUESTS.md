# MonitorCore requests

- Expose timestamped storage-capacity and endpoint-state summaries for Overview sparklines. Add per-process energy attribution if available for the Battery card. Storage and endpoint activity also need explicit attribution metrics before they can have process rankings. Disk throughput and system-wide network traffic measure different things.
- Optionally expose a core type for each `CoreUsage` if the platform reports it. The UI currently shows numbered cores and separate performance and efficiency counts.
