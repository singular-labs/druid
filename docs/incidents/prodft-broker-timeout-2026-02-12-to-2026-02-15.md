# Prodft Broker Timeout Incident RCA

## 1. Incident Summary

- **Cluster:** `prodft` / `prodft30`
- **Incident window:** from approximately **2026-02-12 22:00 UTC** to **2026-02-15 12:30 UTC**
- **Primary impact:** widespread broker query timeouts (`Query did not complete within configured timeout period`), delayed/failed report reads, degraded ETL/reporting UX
- **Current status:** recovered after broker restart; root cause identified with high confidence

### Final diagnosis

The incident was caused by a **broker-side merge pipeline stall** in Druid query serving, specifically in the parallel merge path (`ParallelMergeCombiningSequence`) where request threads repeatedly blocked in `ArrayBlockingQueue.poll`.

---

## 2. What Happened (Timeline)

1. **2026-02-12 ~22:00 UTC**
   - First degradation indicators appear in dashboards (broker latency/timeout behavior starts diverging).

2. **2026-02-15 08:20 UTC**
   - Incident escalated with repeated timeout errors:
   - `QueryTimeoutException`
   - `Query did not complete within configured timeout period`

3. **2026-02-15 08:42 UTC**
   - Append middlemanager rebooted; no meaningful recovery of broker timeout behavior.

4. **2026-02-15 ~09:44–09:51 UTC**
   - Experimental Overlord change reverted and Overlord restarted; timeout behavior persisted.

5. **2026-02-15 ~12:20 UTC**
   - Broker restart performed; query behavior recovered quickly on restarted node.

---

## 3. Impact Scope

- **Broker0 timeout lines (validated from host logs):**
  - `20260212`: `0`
  - `20260213`: `70`
  - `20260214`: `1846`
  - `20260215`: `2070`
  - `20260216`: `0`
  - **Total:** `3986`

- **Broker1 behavior:**
  - sustained timeout storm plus repeated JVM full thread dumps
  - timeout window observed in logs at least from **2026-02-15T06:16:13.768** to **2026-02-15T10:37:24.088**

---

## 4. Root Cause (Confirmed)

### Technical root cause

Broker query threads became stuck in the merge-consumer path:

- `java.util.concurrent.ArrayBlockingQueue.poll(...:435)`
- `org.apache.druid.java.util.common.guava.ParallelMergeCombiningSequence$1$1.hasNext(...:207)`
- `org.apache.druid.java.util.common.guava.ParallelMergeCombiningSequence.toYielder(...:161)`

This blocked query progression until the configured timeout fired.

### Why this is conclusive

1. Direct stack-level signatures were captured repeatedly in broker logs.
2. Multiple `Full thread dump` entries were captured in the same period.
3. Timeout storm and thread-dump evidence are temporally aligned.
4. Restarting broker cleared the failure mode, consistent with stuck in-memory pipeline state.

---

## 5. Relation to Recent MSQ/Overlord Changes

### What changed recently

- Recent branch commit: `4944d8e7ad` (2026-02-04), MSQ polling/logging related.
- Overlord extension rollout/revert occurred near incident time.

### Causality assessment

- **Most likely:** recent MSQ/Overlord changes were a **trigger/contributor**, not the direct defect.
- **Reason:** the direct failing path is broker merge internals, while recent rollout scope primarily touched Overlord.
- **Plausible trigger mechanism:** workload shape/concurrency/cancellation pressure changed enough to expose an existing broker merge fragility already present on this branch.

Confidence:

- Broker merge stall as root cause: **high**
- MSQ/Overlord rollout as primary direct root cause: **low to medium**
- MSQ/Overlord rollout as contributing trigger: **medium**

---

## 6. Missing Upstream Fixes That Address This Failure Mode

These commits exist upstream and are missing from this branch. They are directly relevant to this incident class.

1. **`302739aa58`**
   - "more aggressive cancellation of broker parallel merge, more chill blocking queue timeouts, and query cancellation participation (#16748)"
   - Files: `processing/.../ParallelMergeCombiningSequence.java`, `server/.../CachingClusteredClient.java`
   - Relevance: improves cancellation and resilience of broker parallel merge path.

2. **`dded473ac0`**
   - "Fix another deadlock which can occur while acquiring merge buffers (#16372)"
   - Files: `processing/.../GroupByResourcesReservationPool.java`, `processing/.../GroupingEngine.java`
   - Relevance: addresses deadlock behavior in merge-buffer/groupBy execution paths.

---

## 7. Action Plan (Production-Ready)

### Immediate safeguards (now)

1. Add alerts per broker host:
   - timeout count
   - p95/p99 query latency
   - jetty thread pool pressure
2. Add runbook step: if timeout storm + stuck broker signature appears, restart brokers one-by-one with traffic safety checks.
3. Keep broker0/broker1 metrics split in dashboards (avoid averaged masking).

### Code fix plan (this week)

1. Backport `302739aa58` into `singular-druid-30-changes`.
2. Backport `dded473ac0` into `singular-druid-30-changes`.
3. Build and deploy to staging; run targeted broker stress/regression before prod rollout.

### Validation gates (must pass before prod)

1. No sustained timeout storm under representative high-concurrency query load.
2. No repeated thread dumps showing:
   - `ParallelMergeCombiningSequence...hasNext(...:207)`
   - `ArrayBlockingQueue.poll(...:435)`
3. Broker p99 query time stable and asymmetric-host behavior absent during soak.
4. Canary comparisons:
   - broker query latency
   - direct historical query latency
   - alert on divergence.

### Post-deploy acceptance criteria

1. 72-hour production window without elevated timeout rate.
2. No recurrence of merge-path stack signatures in broker logs.
3. No emergency broker restart required for this symptom class.

---

## 8. Open Items

1. Pin exact trigger point on **2026-02-12 ~22:00 UTC** for broker0 degradation onset.
2. Quantify which query shapes were most represented during the timeout storm.
3. Confirm whether any long-lived broker JVM condition (uptime/memory/GC) increased susceptibility.
