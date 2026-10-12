# Probe Engine

Probe batches are bounded to reduce battery and network cost. The `NodeProbe` boundary is asynchronous and returns measured latency plus a typed result. Implement Android probes through the selected core or a short-lived real protocol handshake; never use ICMP alone to declare a node usable. Background scheduling must be cancellable and should run only after subscription changes, user connect requests, meaningful degradation, or a restrained refresh interval.

The Android Xray adapter uses libXray `pingBatch` against the candidate's proxy outbound before a connection attempt. This probe is supporting evidence only. After `VpnService` establishes the TUN, a separate HTTPS request through the actual TUN is required before the client reports Connected. During failover the previous Xray session is stopped before probing and starting the replacement node.
