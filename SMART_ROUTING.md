# Smart Routing

## ProbeEngine

`ProbeEngine` schedules a bounded batch and captures typed reachability, measured latency, timestamp, and failure category. A platform/core probe implementation must use a real connection handshake or routed request as the deciding signal; raw TCP reachability is only supporting evidence.

## SmartSelector

`SmartSelector` combines latency, historical success ratio, stability, result recency, health classification, and enabled state. It applies a configurable switching margin to keep the current node when a challenger has only a small score advantage.

## ConnectionManager

The typed state machine requires `verifying` to succeed before `connected`. The resolver probes every candidate in the highest viable priority tier, ranks reachable candidates by the configured country priority, latest stored authoritative warm ping, and Last Good bonus, then returns that tier as an ordered candidate set. The connection manager starts candidates in order and verifies each real VPN dataplane attempt. It advances to the next priority tier only after all viable candidates in the current tier fail. Permission denial and core-wide failures are not retried as endpoint failures.

Candidate probes remain serialized through the Android Xray service. They are reachability-only cold `pingBatch` checks and do not update displayed Ping, warm RTT history, or background probe state. Displayed Ping and connected-session monitoring continue to use their existing warm HTTP measurement path.
