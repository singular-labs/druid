# Deployment Guide: Vertx HTTP Client & MSQ Polling Configuration

## Quick Reference

| Change | JAR to Build | Where to Deploy | Config Location |
|--------|--------------|-----------------|-----------------|
| **Vertx HTTP Client** | `druid-kubernetes-overlord-extensions-30.0.0.jar` | **Overlord only** | `overlord/runtime.properties` |
| **MSQ Polling Config** | `druid-multi-stage-query-30.0.0.jar` | **Worker pods** + Overlord | `common.runtime.properties` |

---

## Part 1: What to Build

### Build Commands

```bash
cd /Users/ronshub/workspace/druid

# Build both extensions
./apache-maven-3.9.11/bin/mvn -pl extensions-contrib/kubernetes-overlord-extensions,extensions-core/multi-stage-query -am clean package -DskipTests
```

### Built Artifacts

After build, locate these JARs:

| JAR | Path |
|-----|------|
| Kubernetes Extension (Vertx) | `extensions-contrib/kubernetes-overlord-extensions/target/druid-kubernetes-overlord-extensions-30.0.0.jar` |
| MSQ Extension (Polling) | `extensions-core/multi-stage-query/target/druid-multi-stage-query-30.0.0.jar` |

Vertx also requires runtime dependency JARs copied by the build:

| Runtime Dependencies | Path |
|----------------------|------|
| K8s Vertx deps | `extensions-contrib/kubernetes-overlord-extensions/target/dependency/*.jar` |

### Verify Build Success

```bash
# Verify Vertx classes are in the JAR
jar tf extensions-contrib/kubernetes-overlord-extensions/target/druid-kubernetes-overlord-extensions-30.0.0.jar | grep -E "HttpClientType|Vertx"

# Expected output:
# org/apache/druid/k8s/overlord/common/HttpClientType.class
# org/apache/druid/k8s/overlord/common/httpclient/vertx/DruidKubernetesVertxHttpClientConfig.class
# org/apache/druid/k8s/overlord/common/httpclient/vertx/DruidKubernetesVertxHttpClientFactory.class

# Verify MSQ polling classes
jar tf extensions-core/multi-stage-query/target/druid-multi-stage-query-30.0.0.jar | grep -E "MultiStageQueryContext|MSQWorkerTaskLauncher"
```

---

## Part 2: Where to Deploy

### Deployment Matrix

| Component | Kubernetes Extension JAR | MSQ Extension JAR | Config Changes |
|-----------|-------------------------|-------------------|----------------|
| **Overlord** | YES | YES (for consistency) | `overlord/runtime.properties` |
| **Worker Pods (Peon Image)** | NO | YES | `common.runtime.properties` |
| **Broker** | NO | Optional (for consistency) | None |
| **Coordinator** | NO | NO | None |
| **Historical** | NO | NO | None |
| **Router** | NO | NO | None |

### Why This Deployment Pattern?

#### Vertx HTTP Client (Overlord Only)
- The Kubernetes client runs **only on the Overlord**
- It's used for: creating pods, checking pod status, streaming logs, deleting pods
- Worker pods don't make K8s API calls directly

#### MSQ Polling (Worker Pods + Overlord)
- MSQ controller runs on **worker pods** (the peon process)
- The controller polls the Overlord for worker task status
- Deploy to worker pods for the polling feature to take effect
- Deploy to Overlord for build consistency

---

## Part 3: Configuration

### Vertx HTTP Client Configuration

Add to **`overlord/runtime.properties`**:

```properties
# === Vertx HTTP Client (Default: VERTX is already the default) ===
# No configuration needed - Vertx is enabled by default

# Optional: Tune Vertx thread pools for high concurrency (50+ tasks)
druid.indexer.runner.vertxHttpClientConfig.workerPoolSize=40
druid.indexer.runner.vertxHttpClientConfig.internalBlockingPoolSize=40

# Optional: Fallback to OkHttp if issues occur
# druid.indexer.runner.httpClientType=OKHTTP
```

### MSQ Polling Configuration

Add to **`common.runtime.properties`** (on all worker pods):

```properties
# === MSQ Worker Polling Configuration ===
# Reduce Overlord HTTP request load from MSQ controllers

# Low-frequency polling interval (after first 10 seconds)
# Default: 2000ms, Recommended for 50+ workers: 5000-10000ms
druid.query.default.context.workerStatusPollIntervalMs=5000

# High-frequency polling interval (first 10 seconds of worker startup)
# Default: 100ms, Recommended: 250-500ms
druid.query.default.context.workerStatusPollIntervalHighMs=500
```

### Recommended Settings by Environment

| Environment | Workers | High-Freq (ms) | Low-Freq (ms) | Est. Reduction |
|-------------|---------|----------------|---------------|----------------|
| Light (<50) | <50 | 100 (default) | 2000 (default) | N/A |
| Medium (50-200) | 50-200 | 500 | 5000 | ~60% |
| Heavy (200+) | 200+ | 500 | 10000 | ~80% |

---

## Part 4: Deployment Steps

### Step 1: Build

```bash
cd /Users/ronshub/workspace/druid

# Clean and build both extensions
./apache-maven-3.9.11/bin/mvn -pl extensions-contrib/kubernetes-overlord-extensions,extensions-core/multi-stage-query -am clean package -DskipTests
```

### Step 2: Deploy to Overlord

1. Copy the Kubernetes extension JAR to Overlord's extensions directory:
   ```bash
   cp extensions-contrib/kubernetes-overlord-extensions/target/druid-kubernetes-overlord-extensions-30.0.0.jar \
      $OVERLORD_DEPLOY_DIR/extensions/druid-kubernetes-overlord-extensions/
   ```

2. Copy the **K8s Vertx runtime dependency JARs** to the same directory:
   ```bash
   cp extensions-contrib/kubernetes-overlord-extensions/target/dependency/*.jar \
      $OVERLORD_DEPLOY_DIR/extensions/druid-kubernetes-overlord-extensions/
   ```

   If you skip this step, Overlord will fail with:
   `NoClassDefFoundError: io/vertx/core/VertxOptions`

3. Copy the MSQ extension JAR (for consistency):
   ```bash
   cp extensions-core/multi-stage-query/target/druid-multi-stage-query-30.0.0.jar \
      $OVERLORD_DEPLOY_DIR/extensions/druid-multi-stage-query/
   ```

4. Add Vertx configuration to `overlord/runtime.properties` (optional tuning)

5. Restart Overlord

#### Concrete SCP Commands (prodft30-overlord0)

These match your current SCP workflow:

```bash
# K8s Overlord extension JAR
scp ./extensions-contrib/kubernetes-overlord-extensions/target/druid-kubernetes-overlord-extensions-30.0.0.jar \
  prodft30-overlord0.druid.singular.net:/home/ubuntu/druid/extensions/druid-kubernetes-overlord-extensions/

# K8s Vertx runtime dependency JARs (required)
scp ./extensions-contrib/kubernetes-overlord-extensions/target/dependency/*.jar \
  prodft30-overlord0.druid.singular.net:/home/ubuntu/druid/extensions/druid-kubernetes-overlord-extensions/

# MSQ extension JAR (for consistency)
scp ./extensions-core/multi-stage-query/target/druid-multi-stage-query-30.0.0.jar \
  prodft30-overlord0.druid.singular.net:/home/ubuntu/druid/extensions/druid-multi-stage-query/
```

### Step 3: Deploy to Worker Pod Base Image

1. Update the worker pod (peon) Docker image with the new MSQ JAR:
   ```bash
   cp extensions-core/multi-stage-query/target/druid-multi-stage-query-30.0.0.jar \
      $WORKER_IMAGE_DIR/extensions/druid-multi-stage-query/
   ```

2. Add MSQ polling configuration to `common.runtime.properties` in the image

3. Rebuild and push the worker pod Docker image

4. New MSQ tasks will automatically use the new image

### Step 4: Verification

See Part 5 below for logs to look for.

---

## Part 5: Logs to Look For After Deployment

### Overlord Startup Logs (Vertx Verification)

Look for these logs in the **Overlord** logs:

#### Success - Vertx Enabled (Expected)
```
INFO [main] KubernetesOverlordModule - Kubernetes HTTP client type configured: [VERTX]
INFO [main] KubernetesOverlordModule - Creating Kubernetes client with VERTX HTTP client - workerPoolSize=[40], eventLoopPoolSize=[0], internalBlockingPoolSize=[40]
INFO [main] DruidKubernetesVertxHttpClientFactory - Initializing Vertx HTTP client factory with config: DruidKubernetesVertxHttpClientConfig{workerPoolSize=40, eventLoopPoolSize=0, internalBlockingPoolSize=40}
INFO [main] DruidKubernetesVertxHttpClientFactory - Vertx instance created successfully with daemon threads
INFO [main] DruidKubernetesVertxHttpClientFactory - Vertx HTTP client initialized - workerPoolSize=[40], eventLoopPoolSize=[16], internalBlockingPoolSize=[40]
INFO [main] DruidKubernetesClient - Creating Kubernetes client with custom HTTP client factory: DruidKubernetesVertxHttpClientFactory
```

#### Fallback - OkHttp (If Configured to Fallback)
```
INFO [main] KubernetesOverlordModule - Kubernetes HTTP client type configured: [OKHTTP]
INFO [main] KubernetesOverlordModule - Creating Kubernetes client with OKHTTP HTTP client
INFO [main] DruidKubernetesClient - Creating Kubernetes client with default HTTP client (OkHttp)
```

### Worker Pod Logs (MSQ Polling Verification)

Look for these logs in **worker pod** logs when an MSQ query runs:

#### Custom Configuration Applied
```
INFO [task-runner-0-priority-0] ControllerImpl - Task[query-abc-123-worker0_0] configured worker polling intervals from context: highFrequencyPollIntervalMs=500, lowFrequencyPollIntervalMs=5000
INFO [task-runner-0-priority-0] MSQWorkerTaskLauncher - MSQ worker task launcher initialized for controller[query-abc-123-worker0_0]: highFrequencyPollMs=500, lowFrequencyPollMs=5000, switchToLowFreqAfterMs=10000 (CUSTOM CONFIG)
```

#### Default Configuration (If No Custom Config)
```
INFO [task-runner-0-priority-0] MSQWorkerTaskLauncher - MSQ worker task launcher initialized for controller[query-abc-123-worker0_0]: highFrequencyPollMs=100, lowFrequencyPollMs=2000, switchToLowFreqAfterMs=10000 (defaults)
```

#### Runtime Polling Mode Transitions
```
INFO [multi-stage-query-task-launcher] MSQWorkerTaskLauncher - Controller[query-abc-123-worker0_0] entering high-frequency polling mode: interval=500ms, duration=10000ms, trackedWorkers=1
INFO [multi-stage-query-task-launcher] MSQWorkerTaskLauncher - Controller[query-abc-123-worker0_0] switching to low-frequency polling mode: interval=5000ms, afterHighFreqPolls=20, trackedWorkers=5
```

### Overlord Shutdown Logs (Vertx Cleanup)
```
INFO [main] KubernetesOverlordModule - Stopping Vertx HTTP client factory
INFO [main] DruidKubernetesVertxHttpClientFactory - Closing Vertx HTTP client factory
INFO [main] DruidKubernetesVertxHttpClientFactory - Vertx instance closed
INFO [main] KubernetesOverlordModule - Stopping overlord Kubernetes client
```

### Thread Dump Verification (Advanced)

To verify Vertx is actively being used, take a thread dump on the Overlord:

```bash
# On the Overlord pod/container
jstack <overlord_pid> | grep -i "vert.x"

# Expected output with Vertx:
"vert.x-eventloop-thread-0" daemon prio=5 ...
"vert.x-eventloop-thread-1" daemon prio=5 ...
"vert.x-worker-thread-0" daemon prio=5 ...
```

---

## Part 6: Troubleshooting

### Issue: Vertx Not Initializing

**Symptom:** Logs show OkHttp instead of Vertx

**Check:**
1. Verify `httpClientType` is not set to `OKHTTP` in Overlord config
2. Check the extension directory includes `kubernetes-httpclient-vertx` and `vertx-core` JARs
3. Look for Vertx initialization errors:
   ```bash
   grep -i "vertx\|error\|exception" overlord.log | head -50
   ```

### Issue: MSQ Polling Config Not Applied

**Symptom:** Worker logs show default values (100ms, 2000ms)

**Check:**
1. Configuration is in `common.runtime.properties` on **worker pods** (not just Overlord)
2. Worker pods have been restarted after config change
3. Search for config in logs:
   ```bash
   grep "configured worker polling intervals" worker-pod.log
   ```

### Issue: Tasks Failing After Deployment

**Immediate Rollback - Vertx:**
```properties
# Add to overlord/runtime.properties
druid.indexer.runner.httpClientType=OKHTTP
# Restart Overlord
```

**Immediate Rollback - MSQ Polling:**
```properties
# Remove or comment out in common.runtime.properties
# druid.query.default.context.workerStatusPollIntervalMs=5000
# druid.query.default.context.workerStatusPollIntervalHighMs=500
# Restart worker pods (or wait for new tasks to use defaults)
```

---

## Part 7: Deployment Checklist

### Pre-Deployment
- [ ] Build both extensions successfully
- [ ] Verify JARs contain new classes (see Part 1)
- [ ] Prepare configuration changes
- [ ] Plan rollback procedure

### Overlord Deployment
- [ ] Deploy `druid-kubernetes-overlord-extensions-30.0.0.jar`
- [ ] Deploy `druid-multi-stage-query-30.0.0.jar` (for consistency)
- [ ] Add Vertx configuration to `overlord/runtime.properties` (optional)
- [ ] Restart Overlord
- [ ] Verify startup logs show Vertx enabled

### Worker Pod Deployment
- [ ] Deploy `druid-multi-stage-query-30.0.0.jar` to worker pod base image
- [ ] Add MSQ polling configuration to `common.runtime.properties`
- [ ] Rebuild/push worker pod Docker image
- [ ] New MSQ tasks will use updated image automatically

### Post-Deployment Verification
- [ ] Overlord logs show Vertx initialization
- [ ] Run test MSQ query
- [ ] Worker pod logs show custom polling intervals
- [ ] Task completes successfully
- [ ] No unexpected errors in logs

### Load Testing (Recommended)
- [ ] Run 10 concurrent MSQ tasks
- [ ] Run 50+ concurrent MSQ tasks
- [ ] Monitor Overlord thread count (should stay bounded)
- [ ] Monitor Overlord HTTP response times

---

## Part 8: Summary

### What We're Deploying

1. **Vertx HTTP Client Backport** (from Druid 35 PR #18540)
   - Replaces OkHttp with non-blocking Vertx for K8s API calls
   - Prevents thread pool exhaustion under high task concurrency
   - **Overlord only**

2. **MSQ Polling Configuration** (custom enhancement)
   - Makes worker status polling intervals configurable
   - Reduces Overlord HTTP request load
   - **Worker pods primarily, Overlord for consistency**

### Expected Benefits

| Metric | Before | After |
|--------|--------|-------|
| Overlord HTTP threads under 100 tasks | Can exhaust pool | Bounded (~20-40) |
| Overlord polling requests (100 workers) | ~50/sec | ~10-20/sec |
| Thread model | Thread-per-request (blocking) | Event loops (non-blocking) |

### Rollback

Both changes have simple rollback:
- **Vertx:** Set `httpClientType=OKHTTP` and restart Overlord
- **MSQ Polling:** Remove config values (defaults will be used)

---

*Created: February 2026*
*Based on: IMPLEMENTATION_PLAN_VERTX_AND_MSQ_POLLING.md, VERTX_HTTP_CLIENT_BACKPORT.md, MSQ_POLLING_CONFIGURATION.md*