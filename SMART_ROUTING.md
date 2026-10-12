# Smart Routing

## ProbeEngine

`ProbeEngine` schedules a bounded batch and captures typed reachability, measured latency, timestamp, and failure category. A platform/core probe implementation must use a real connection handshake or routed request as the deciding signal; raw TCP reachability is only supporting evidence.

## SmartSelector

`SmartSelector` combines latency, historical success ratio, stability, result recency, health classification, and enabled state. It applies a configurable switching margin to keep the current node when a challenger has only a small score advantage.

## ConnectionManager

The typed state machine requires `verifying` to succeed before `connected`. Failover excludes the failed node, tries a bounded number of distinct candidates, and verifies every candidate tunnel. Network monitoring and durable metrics are pending Android core integration.
