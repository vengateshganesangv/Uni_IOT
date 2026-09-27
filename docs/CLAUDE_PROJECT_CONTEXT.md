# Smart Disaster Relief (Uni_IOT) — Project Context & AWS Scaling Investigation

> Living document. Read this first when resuming. Session-by-session history is in [CLAUDE_INVESTIGATION_LOG.md](CLAUDE_INVESTIGATION_LOG.md).
> **No application code has been modified.** Investigation only.
> Last updated: 2026-09-27 (Session 3: cost-optimized Terraform + optional test broker; real AWS deployment run and verified twice; see §13).
> **Session 3 headline:** the system was deployed to real AWS (ECS Fargate, ap-southeast-2, throwaway test broker, no HiveMQ needed) and both a 35k and a 300k event completed correctly with autoscaling firing. But the extra Priority tasks arrived too late to meaningfully share the 300k burst: the one warm task did 60% of the work; the last task to join processed almost nothing. This is now measured evidence, not just the local-loopback hypothesis in §12.2. Read §13.2.
>
> **Session 2 headline:** the local experiment showed that adding Priority replicas made the 300k event ~2.3x *slower* (broker saturated). Read §12.2 before trusting any "scale Priority" advice in §7.

**Legend** — every claim is tagged:
- **[FACT]** read directly from repo code/config, or verified against installed library source.
- **[MEASURED]** produced by a local experiment in Session 1 (method + caveats in the log). Local loopback only; not AWS numbers.
- **[EXTERNAL]** taken from vendor docs/forum via web search in Session 1. Re-verify before relying on it for sizing/cost.
- **[ASSUMPTION]** my inference; not proven by the repo.
- **[RECOMMENDATION]** my proposal.

---

## 1. TL;DR (read this if nothing else)

1. **[FACT]** The repo is 4 small Node.js processes talking through one external MQTT broker (HiveMQ Cloud). No database, no cache, no SQS/queue service, no IaC, no CI, no tests, no compose file. The only AWS usage is one CloudWatch `PutMetricData` call. Only Priority Service has a Dockerfile.
2. **[FACT]** "IoT device count" is **not** the load driver. 3 sensor messages per event fan out to up to **300,000** MQTT emergency messages, generated *inside* the Emergency Request Service by a `for` loop keyed on water level. Load is a function of water level, not of device count.
3. **[FACT]** The only component that is horizontally scalable today without code changes is **Priority Service** (MQTT shared subscription `$share/priority-workers/...`, Priority_Service.js:42).
4. **[FACT]** **Rescue Service is a stateful singleton** (in-memory queue, teams, per-event counters; non-shared subscription). Adding replicas would duplicate every message and break completion tracking.
5. **[FACT]** The broker is the real shared bottleneck and it is **outside AWS autoscaling**. It is also in a different geography than the AWS region the code targets (EU host vs `ap-southeast-2`).
6. **[MEASURED]** Business logic is not the bottleneck: ~290k msg/s/core (Priority), ~440k msg/s/core (Rescue), logic only. The ceilings are MQTT client/broker/network and single-connection fan-in.
7. **[MEASURED]/[ASSUMPTION]** A whole 100k-request burst drains in seconds locally (≈7 s). Reactive autoscaling (alarm eval + Fargate task start + ~1 GB image pull) is likely **slower than the burst**, so reactive scaling on `IncomingRequests` will mostly add capacity *after* the work is done, unless work per message becomes slower (DB write, etc.) or events overlap.
8. **[FACT]** **Missing link:** nothing in the repo consumes the sensor's `disaster/water/*` topics or calls `POST /emergency`, and the sensor payload (`value`) doesn't match what `/emergency` reads (`waterLevel`). See §9 Open Question #1. Everything downstream depends on how that gap is filled.
9. **[RECOMMENDATION]** Scale **Priority Service** (ECS/Fargate, Application Auto Scaling, step scaling on the existing `IncomingRequests` metric with a warm minimum), keep **Rescue at exactly 1** until its state is externalised, keep Emergency small and fixed, and treat the broker plan/limits as the true capacity ceiling. Details in §7.

---

## 2. Repository inventory

```
Uni_IOT/
├─ Sensor_Device/water_sensor.js               (141 lines)  simulated water-level sensors, CLI-driven
├─ Emergency_Request_Service/emergency_service.js (156)     Express + MQTT + CloudWatch; fan-out generator
├─ Priority_Service/Priority_Service.js          (77)       MQTT shared-subscription worker
├─ Priority_Service/Dockerfile, .dockerignore              only containerised service
├─ Rescue_Service/rescue_service.js             (143)      in-memory dispatcher / event tracker
└─ each dir: package.json + package-lock.json  (mqtt ^5.15.2, dotenv; express ^5 in Emergency & Priority; @aws-sdk/client-cloudwatch in Emergency)
```

**[FACT]** Not present: Terraform/CDK/CloudFormation, ECS task definitions, docker-compose, CI, tests, `.env.example`, README, any DB/Redis/SQS/SNS/Lambda code, any health endpoint, any SIGTERM handling. Git history: single commit `3b31a22 "Smart Disaster Relief System"`.
**[FACT]** `.env` (HIVEMQ_USERNAME / HIVEMQ_PASSWORD) is git-ignored and not in the working tree; not inspected.
**[FACT]** `express` is a dependency of Priority Service but is never imported (Priority_Service.js has no HTTP listener).

---

## 3. Architecture and end-to-end flow

```
 Sensor_Device (CLI, 3 simulated sensors W001-W003)
   │  MQTT publish, QoS0, 3 msgs/event  topic: disaster/water/Zone_{A,B,C}
   ▼
 ┌────────────────────────── HiveMQ Cloud (external, TLS 8883, EU host) ──────────────────────────┐
 │                                                                                               │
 │  ✗ NO CONSUMER OF disaster/water/* IN REPO  ─ ─ ─ ─ ─ ─ ─ ▶ (unknown bridge) ─ ▶ HTTP POST    │
 │                                                                                    /emergency │
 └───────────────────────────────────────────────────────────────────────────────────────────────┘
                                                                                        │
 Emergency_Request_Service (Express :3001)  ◀───────────────────────────────────────────┘
   • getRequestCount(waterLevel) → 0 / 5k / 10k / 20k / 50k / 100k
   • sendWorkloadMetric(count) → CloudWatch  SmartDisasterRelief/IncomingRequests (1-s resolution)
   • sync for-loop: publish `count` MQTT msgs (QoS0)  topic: disaster/emergency/requests
   • replies 201 {requestsGenerated}
   ▼
 HiveMQ ── shared subscription $share/priority-workers/disaster/emergency/requests ──┐
                                                                                     ▼
 Priority_Service (N replicas OK)   parse → getPriority(emergencyType) → publish disaster/emergency/prioritized
   ▼
 HiveMQ ── plain subscription (every subscriber gets every message) ──┐
                                                                      ▼
 Rescue_Service (MUST be 1)   in-memory rescueQueue / 50 teams / floodEvents{}; "assigns" instantly;
                              prints FLOOD EVENT RESULT when completed === totalEventRequests
```

### Topics and contracts
| Topic | Publisher | Subscriber | Subscription type | QoS | Payload bytes [MEASURED by replication] |
|---|---|---|---|---|---|
| `disaster/water/Zone_{A,B,C}` | Sensor | **none in repo** | – | 0 (mqtt.js default) | ~400 (not measured) |
| `disaster/emergency/requests` | Emergency | Priority | **shared** `$share/priority-workers/` | 0 | ~307 |
| `disaster/emergency/prioritized` | Priority | Rescue | **non-shared** | 0 | ~325 |

### Where the state lives
| State | Location | Scope | Consequence |
|---|---|---|---|
| Sensor readings / event id | in-flight MQTT msgs only | none persisted | no history, no replay |
| Priority counters (`counts`, `totalProcessed`) | Priority_Service.js:12-19 | per process | with N replicas each prints its own partial totals; logging only, no correctness impact |
| `rescueQueue`, `rescueTeams`, `floodEvents` | rescue_service.js:12-14 | per process, never evicted | singleton; memory grows per event; incomplete events leak forever |
| Anything durable | **nowhere** | – | no DB, cache, or queue: a restart loses all state and all in-flight messages |

---

## 4. Component analysis

### 4.1 Sensor_Device — [water_sensor.js](../Sensor_Device/water_sensor.js)
- **[FACT]** Interactive readline loop; one entry of (A,B,C) = one "flood event" with `eventId=EVENT-<Date.now()>`. Publishes exactly 3 messages (lines 89-132). Broker host hard-coded (line 6).
- **[FACT]** `getRequestCount()` duplicated here (35-44) and in Emergency (31-39); `totalEventRequests` is computed by the sensor and *trusted* downstream (used by Rescue for completion).
- **[FACT]** Payload uses `value` (line 103) not `waterLevel`. Random mqtt.js clientId (no fixed device identity), shared broker username/password for all devices, QoS 0, no LWT/retain.
- **Scaling relevance:** not an AWS-hosted scaling target. The dimensions that matter at device scale are broker **connection count** and per-device auth (§8), not compute.

### 4.2 Emergency_Request_Service — [emergency_service.js](../Emergency_Request_Service/emergency_service.js)
- **[FACT]** `POST /emergency` (line 77): no auth, no validation, no rate limit, no body-size override (Express default).
- **[FACT]** **Amplification:** one HTTP call → up to 100,000 `client.publish()` calls (lines 101-136) in one synchronous loop, then `res.status(201)` (145). Max event = 3 zones × 100k = 300k messages.
- **[FACT]** `sendWorkloadMetric(requestCount)` (line 97, defn 42-67): `IncomingRequests`, Unit Count, `StorageResolution: 1` (high-res), **no dimensions**, region hard-coded `ap-southeast-2` (line 16). One datapoint per HTTP call, value = that zone's request count.
- **[FACT]** Because the publish loop is fully synchronous, the metric's `await cloudwatch.send()` cannot actually go out until the loop and the 201 response have completed. The metric is therefore emitted *after* the burst is already enqueued, not before it. It is a "work injected" signal, not a leading indicator, and it says nothing about work *remaining*.
- **[MEASURED]** Building+publishing 100k msgs blocks the event loop ≈ 0.35 s (logic only) to ≈ 0.56 s (including mqtt.js encode/enqueue, local). 300k ≈ 1–1.7 s. While blocked it can't serve HTTP or health checks.
- **[FACT]** mqtt.js 5.16.0 defaults (verified in `build/lib/client.js`): random `clientId` (`mqttjs_` + 8 hex, line 114), `clean: true`, `keepalive: 60`, `resubscribe: true`, `queueQoSZero: true` (offline QoS0 publishes are buffered in memory, no cap).
- **[ASSUMPTION]** Real-world role: this service is the **load generator** simulating citizens' requests, not a receiver of external load. Evidence: requests are randomly typed (`Math.random()`), synthetic, and the count is derived from a sensor reading. Consequence: scaling Emergency *out* creates load faster; it does not absorb it.
- **Statelessness:** stateless across requests (no shared state), so it can be replicated behind an ALB. Latent hazard: `requestId = REQ-<Date.now()>-<i>` can collide across replicas/zones in the same millisecond (nothing dedupes on it today).

### 4.3 Priority_Service — [Priority_Service.js](../Priority_Service/Priority_Service.js)
- **[FACT]** Subscribes with `$share/priority-workers/disaster/emergency/requests` (line 42) → broker load-balances across group members. Each replica has its own random clientId, so multiple replicas coexist. **This is the horizontally scalable unit.**
- **[FACT]** Per message: `JSON.parse` → map type→priority → `client.publish(prioritized)` (47-65). No I/O other than the broker. No ack/ordering logic, no error handling: a malformed message throws in the `message` handler and crashes the process (uncaught exception). No SIGTERM handler.
- **[MEASURED]** ~288k msg/s/core logic-only. It is not CPU-bound on logic; its ceiling is the MQTT connection (parse/encode, TLS, one TCP stream) and broker delivery limits.
- **[FACT]** Dockerfile ([Priority_Service/Dockerfile](../Priority_Service/Dockerfile)): `FROM node:24` (full image), `npm install` (not `npm ci`, dev deps not excluded), runs as root, no `EXPOSE`/`HEALTHCHECK`. **[ASSUMPTION]** the full node image is ≈1 GB, making Fargate cold starts slower than a slim/distroless image.
- **[FACT]** With QoS 0 and `clean: true`, anything delivered to a replica that dies (scale-in, crash, deploy) is lost; nothing is redelivered. [EXTERNAL] HiveMQ: QoS0 messages are not queued for offline clients, even with a persistent session.

### 4.4 Rescue_Service — [rescue_service.js](../Rescue_Service/rescue_service.js)
- **[FACT]** Non-shared subscription (line 40) → **every replica receives every message**. In-memory `rescueQueue`, 50 teams (10 × 5 types), `floodEvents` map (never pruned).
- **[FACT]** "Assignment" is instantaneous: `assignTeams()` sets `team.available=false` then `true` in the same synchronous block (lines 104-110), so completion is immediate and teams are never a capacity constraint.
- **[MEASURED]** Replaying 100k messages: max `rescueQueue` length = **0** (queue never builds); ~444k msg/s/core logic-only.
- **[FACT]** Completion criterion: `event.completed === event.totalEventRequests` (line 121). **Any lost message (QoS0 drop, restart, Priority replica killed mid-flight) means the event never completes, the result never prints, and the entry leaks.** More Priority replicas + scale-in raises the loss probability.
- **[MEASURED, latent risk]** If real work were modelled (teams busy → queue builds), `findHighestPriorityRequest` is O(queue) per team per message: one `assignTeams()` over a 50k backlog ≈ 8.5 ms → O(N²) behaviour on a 100k+ backlog.
- **Fan-in:** all traffic converges on this single connection/process. Amdahl's law applies: scaling Priority to N replicas only helps until the Rescue singleton (or the broker's per-subscriber delivery) saturates.
- The console line "Execution Time" (checkEventComplete, 126-140) — sensor `eventStartTime` → last completion — is the only end-to-end latency measurement in the system and is the natural SLO/KPI for any scaling experiment. **[ASSUMPTION]** it's the metric the course project uses to show scaling benefit. It uses two different hosts' clocks (skew risk).

### 4.5 HiveMQ Cloud (external)
- **[FACT]** Host `1490e7aa…s1.eu.hivemq.cloud:8883` hard-coded in all four services. `s1` naming suggests HiveMQ Serverless **[ASSUMPTION]**; `eu` suggests an EU cluster **[ASSUMPTION]**, whereas CloudWatch is `ap-southeast-2` (Sydney). Cross-continent RTT + internet egress for every hop **[ASSUMPTION]**.
- **[EXTERNAL]** HiveMQ Cloud Serverless free plan: 100 connections, 10 GB/month traffic, shared platform. Plan actually in use is unknown (see §9).
- **[EXTERNAL]** HiveMQ: shared-subscription QoS is the individual subscription's QoS; QoS0 not queued while offline.

---

## 5. Load model — how volume really grows

`getRequestCount(waterLevel)`: ≥90→100,000; ≥80→50,000; ≥70→20,000; ≥60→10,000; ≥50→5,000; else 0. (Sensor status: ≥70 CRITICAL, ≥50 WARNING.)

| Event (A,B,C) | Sensor msgs | Emergency msgs | Broker msg ops (×4 hops/req) | Payload through broker (≈1,264 B/req, all 4 legs) |
|---|---|---|---|---|
| 50,50,50 | 3 | 15,000 | 60k | ≈19 MB |
| 70,70,70 | 3 | 60,000 | 240k | ≈76 MB |
| 90,90,90 (max) | 3 | **300,000** | **1.2 M** | **≈379 MB** |

- Amplification ≈ **100,000 : 1** at the top tier. Doubling devices doubles this; changing one sensor's reading from 89→90 doubles that zone's load.
- Per-request path = 4 broker operations: Emergency→broker, broker→Priority, Priority→broker, broker→Rescue.
- **[EXTERNAL/ASSUMPTION]** If the 10 GB/month free cap counts in+out payload: ≈26 max events/month (all four legs) to ≈52 (ingress only); protocol/TLS overhead makes it fewer. Cap behaviour on exhaustion unknown.

### Measured throughput reference (Session 1, local loopback, single Node process hosting broker+3 clients; no TLS/WAN)
| Test | Result |
|---|---|
| Handler logic only (Priority / Rescue) | ~288k / ~444k msg/s per core |
| Emergency sync loop, 100k msgs | 0.35 s (logic) / 0.56 s (with mqtt.js enqueue) |
| End-to-end 20k msgs, Emergency→Priority→Rescue via aedes | 1.8 s ≈ 11.3k msg/s, 0 lost |
| End-to-end 100k msgs | 7.0 s ≈ 14.3k msg/s, 0 lost, RSS 324 MB (shared process) |
Caveat: everything shared one event loop, so 11–14k msg/s is a pessimistic floor for an isolated pipeline, and TLS + WAN to an EU broker will change it in unknown directions. Treat as order-of-magnitude only.

---

## 6. Bottlenecks, ranked (as load grows)

| # | Bottleneck | Evidence | Behaviour under growth |
|---|---|---|---|
| 1 | **Broker capacity/plan** (connections, GB/month, rate, per-connection delivery) | one shared external broker for all traffic; hard-coded host | Hard ceiling not solvable by AWS autoscaling; failure modes (throttle/disconnect/drop) unknown |
| 2 | **Rescue singleton fan-in** | non-shared sub + in-memory state (rescue_service.js:12-14, 40) | Priority can scale out, but everything converges on 1 process/connection; cannot be replicated without a redesign |
| 3 | **QoS0 + no durability** | default qos 0 everywhere; `clean:true` | Loss under slow consumer, restart, or scale-in → events never complete (line 121) → memory leak; **scaling in actively causes loss** |
| 4 | **Emergency synchronous amplification** | for-loop lines 101-136 | Event loop blocked 0.5 s/100k; unbounded mqtt.js buffering (memory ∝ burst); health checks can time out; single request can flood the broker (no auth/rate limit) |
| 5 | **Observability gap for backlog** | no queue, QoS0, per-replica counters | Nothing in the system exposes "messages waiting"; `IncomingRequests` measures injected work, and is emitted after the burst |
| 6 | **Broker↔compute distance** | EU broker host vs `ap-southeast-2` | Extra latency and internet/NAT egress on every hop [ASSUMPTION] |
| 7 | Rescue O(N) scan (latent) | rescue_service.js:66-86 | Only matters once assignment takes time; O(N²) for large backlogs |

CPU on Priority/Rescue is **not** a bottleneck for the current logic [MEASURED].

---

## 7. AWS scaling determination

### 7.1 What should scale
| Component | Scale out? | Why / how |
|---|---|---|
| **Priority Service** | **Yes** – the only safe scale-out target | Stateless, shared subscription already load-balances (Priority_Service.js:42) |
| **Emergency Request Service** | Only lightly (min 2 for HA behind ALB); **not** on request count | Stateless, but it is the load *generator*; HTTP request count is meaningless (1 req = 5k–100k msgs). Scale on CPU / event-loop lag if at all |
| **Rescue Service** | **No (min=max=1)** until state is externalised | Duplicates all messages; in-memory counters; see §4.4 |
| **Sensor_Device** | Not an AWS compute target | Devices scale by connection count and per-device credentials |
| **Broker** | Outside autoscaling; **choose a plan/architecture with headroom** | Ceiling for everything |

### 7.2 What should trigger scaling (Priority Service)
Candidates, from the code's own signals:
| Signal | Source | Verdict |
|---|---|---|
| `SmartDisasterRelief/IncomingRequests` (Sum, 1 s) | already emitted, emergency_service.js:42-67 | **Best available today.** Deterministic function of water level (5k/10k/20k/50k/100k tiers) so the work size of an event is *known* at emission. Caveats: emitted after the enqueue; not per-task; no "remaining" semantic |
| Priority task CPU | ECS built-in | Poor trigger: logic is ~300k msg/s/core, so the process is I/O bound long before CPU saturates |
| ALB request count | – | Not applicable (Priority has no HTTP; Emergency's HTTP count is 1:100k) |
| Backlog / lag (in-flight = injected − processed) | **does not exist** | The right signal but requires a code change (Priority emitting a `Processed` metric, or a real queue). Recommended next step |
| Sensor `status`/water level as **feed-forward** (WARNING ≥50 / CRITICAL ≥70) | payload field, water_sensor.js:93-99 | **[ASSUMPTION]** In a real flood levels rise over minutes; pre-scaling on WARNING beats any reactive trigger |

### 7.3 Which AWS autoscaling approach fits
**[RECOMMENDATION]** ECS on **Fargate** (existing Dockerfile → ECR), **Application Auto Scaling**:
1. **Warm floor:** `minCapacity` sized for a max event (300k msgs) within the SLO. Reason: **[MEASURED/ASSUMPTION]** the whole burst drains in ~7-20 s; alarm evaluation (min 10 s with high-res metrics) + Fargate provisioning + image pull of a ~1 GB image (~30-90 s+ [ASSUMPTION]) is slower. Scale-to-zero/1 → scale-out will arrive after the burst.
2. **Scale-out policy = step scaling** on `SUM(IncomingRequests)` over a short period (10–60 s), with steps aligned to the tier constants (e.g. ≥20k → +1, ≥50k → +3, ≥100k → +N). Rationale: step scaling maps naturally to the discrete tiers and to a non-per-task metric.
   - *Why not plain target tracking:* target tracking requires the metric to move inversely with task count [EXTERNAL: AWS docs]; total injected requests doesn't fall when tasks are added. It would work only via **metric math** (`IncomingRequests / RunningTaskCount`, needs Container Insights) [EXTERNAL: metric math supported for target tracking].
3. **Slow scale-in** (long cooldown, e.g. ≥5–10 min) and, before scale-in is acceptable, SIGTERM handling + QoS1/persistent session (otherwise scale-in loses messages; §6 #3).
4. **Scheduled/manual pre-warm** for demos/known drills (deterministic tiers make this trivial).
5. Optional: **predictive/feed-forward** via an EventBridge/Lambda rule that raises desired count when a sensor reports WARNING/CRITICAL (requires the missing sensor→cloud ingestion path).

**Rejected / not fitting now:**
- EC2 ASG: slower than Fargate for a burst pattern; more ops.
- Lambda: `mqtt.js` long-lived subscription + shared subscription model doesn't map; would need broker→Lambda integration (IoT Core rules / SQS event source) = re-architecture.
- KEDA/EKS: only worthwhile if already on Kubernetes; nothing in the repo indicates it.
- Target tracking on CPU: wrong signal (§7.2).

### 7.4 Advantages / disadvantages / risks
**Advantages**
- Priority is already shared-subscription-ready: scale-out is a config change, no code change.
- Custom metric already exists and encodes the exact work size deterministically; high-res (1 s) is already enabled.
- Stateless workers → cheap, fast to add/remove; Fargate removes node management.
- Rescue has natural partition keys (5 emergency types), making a future partitioned design straightforward.

**Disadvantages**
- Reactive autoscaling likely lags a seconds-long burst; benefit only shows for sustained/overlapping events or slower per-message work.
- Total-volume metric isn't per-task; needs step scaling or metric math.
- High-res custom metric and alarms have per-metric/per-alarm cost (note for cost model; not priced here).
- Large `node:24` image slows scale-out; running as root.

**Scaling risks**
1. Scaling Priority beyond ~1-2 tasks yields no end-to-end gain if Rescue/broker is saturated (Amdahl); more replicas can *increase* loss.
2. QoS0 + scale-in/crash ⇒ lost messages ⇒ events never complete ⇒ Rescue memory leak. **Scale-in is a correctness risk.**
3. Connection cap: every replica = 1 broker connection; free tier 100 [EXTERNAL] ⇒ hard replica cap (~<95 incl. others).
4. Monthly traffic cap: ≈26–52 max events/month on free plan [EXTERNAL+ASSUMPTION].
5. Broker outside AWS: latency, egress/NAT cost, no autoscaling control; alarm on it isn't possible from AWS alone.
6. Emergency has no auth/rate-limit: an open `/emergency` on the internet is a trivial 100,000× amplification vector (also a cost/DoS risk once on AWS).
7. Metric emitted after burst; `IncomingRequests` summed across concurrent Emergency replicas is fine, but there are no dimensions to separate environments/zones.
8. If AWS IoT Core is chosen as the broker: **[EXTERNAL]** hard limits ≈100 publish/s and 512 KB/s **per connection**; default account 10k inbound / 20k outbound publish/s. A single 100k-message burst from one connection would be throttled by ~3 orders of magnitude. The internal hops (Emergency→Priority→Rescue) should not be MQTT at all in that world (use SQS/Kinesis/SNS); keep MQTT for devices only.

### 7.5 What happens as device/message volume increases
1. **Today (3 sensors, ≤300k msgs/event):** works if the broker plan holds; whole pipeline drains in seconds locally; 1 Priority replica suffices in the local measurements.
2. **More events per hour:** first limit is broker traffic quota (≈26–52 max events/month on free tier), not compute.
3. **Concurrent events / more zones:** Emergency event loop is blocked ~0.5 s/100k messages, buffers grow in memory (unbounded), the broker sees a spike of up to hundreds of thousands msgs/s from one connection [ASSUMPTION on broker limit response]; QoS0 drops appear silently.
4. **Add Priority replicas:** throughput on the Priority stage grows, but Rescue fan-in and broker outbound to a single subscriber cap the gain; every drop breaks completion (`completed !== total`).
5. **True device growth (thousands of sensors):** sensor traffic itself is tiny (~400 B, 3/event); the pressure is connection count/auth (shared password today), topic design, and amplification scaling linearly with the number of sensors × their tier.
6. **Beyond broker single-connection limits:** requires re-architecture (§7.6).

### 7.6 Structural recommendations (would need code/infra changes — **not done**)
Ordered by value for scaling:
1. Make the sensor→Emergency path explicit (Open Q #1) and fix the `value`/`waterLevel` contract.
2. Decouple internal hops from MQTT with a durable queue (e.g. SQS/Kinesis) so backlog is measurable and scale-in is safe; then scale Priority on **backlog per task** (classic ECS+SQS target tracking).
3. Emit `Processed` (or per-stage) metrics so `IncomingRequests − Processed` is a lag proxy.
4. Rescue: externalise `floodEvents` to DynamoDB/Redis (atomic counters), partition by `emergencyType`, add TTL/eviction; only then allow >1 replica.
5. Emergency: batch/stream publishes instead of a blocking loop; add auth + rate limiting; QoS1 or move to queue.
6. Container hygiene: slim base image, `npm ci --omit=dev`, non-root, SIGTERM handler, health check; move broker host/region/port to env config.
7. Choose the broker deliberately (HiveMQ paid tier in/near ap-southeast-2 vs IoT Core edge-only) with the limits in §7.4.

---

## 8. Decisions recorded (so far)
| # | Decision | Status |
|---|---|---|
| D1 | No application code modified; investigation-only, artifacts limited to `docs/` | Agreed with user |
| D2 | Scaling target = Priority Service only; Rescue pinned to 1; Emergency small/fixed | Proposed (pending review) |
| D3 | Preferred mechanism = ECS Fargate + Application Auto Scaling step scaling on `IncomingRequests`, warm floor, slow scale-in | Proposed |
| D4 | Do not use CPU or ALB request count as triggers | Proposed |
| D5 | Use docker-compose for local validation, then Terraform for AWS (user chose "compose and terraform, with start and terminate scripts") | **Done (Session 2)**, §12 |
| D6 | Deploy to **ap-southeast-2**, not the CLI default ap-south-1: the CloudWatch client region is hard-coded (emergency_service.js:16) and alarms must be in the metric's region | Implemented in Terraform (`var.region`) |
| D7 | Sensor→Emergency link = `scripts/fire-event.js` (user: "yes throw script"); no bridge service built | Done; real sensor still not connected |
| D8 | No application code changed. Priority's original Dockerfile left untouched; slim variant added as `Priority_Service/Dockerfile.slim` | Done |
| D9 | Region conflict (user asked for ap-south-1): keep the real deployment in **ap-southeast-2** because emergency_service.js:16 hard-codes that region for CloudWatch, and an alarm can't watch a metric in a different region. `var.region`/`REGION=` stays configurable for whoever removes that hard-code later. User chose this option over disabling autoscaling in ap-south-1 or editing the app code. | Decided (Session 3) |
| D10 | Added `use_test_broker` (default false): an in-VPC throwaway Mosquitto broker + private DNS shadow of the hard-coded HiveMQ hostname, so AWS can be tested with no HiveMQ account. User: "optional feature but by default it should not [be used]." Test only; broker behaviour is Mosquitto's, not HiveMQ's. | Done (Session 3), §13.1 |
| D11 | Cost-optimization defaults added per user request ("make sure cost optimization is there... don't want to put more money"): Fargate Spot for Emergency/Priority (on-demand only for Rescue and the test broker), no ALB by default (Emergency gets a restricted public IP instead), `priority_max_capacity` lowered 8→4, `emergency_desired_count` lowered 2→1, ECR lifecycle policy keeps only 3 images/repo | Done (Session 3), §13.1 |
| D12 | After each real deployment, tear down immediately once verified rather than leaving it running, per the user's cost preference | Done for the Session 2 deployment. **The Session 3 deployment was NOT torn down before this doc was written — see §13.3 PENDING.** |

## 9. Open questions (need the user / the deployed environment)
1. **How does a sensor reading become a `POST /emergency`?** Nothing in the repo subscribes to `disaster/water/*` or calls port 3001, and the sensor sends `value` while `/emergency` reads `waterLevel` (a raw forward would yield `NaN` → 0 requests). Manual curl/Postman? An unshown bridge/Lambda? Another repo? **Highest-priority unknown.**
2. Which HiveMQ plan is used (Serverless free / Starter / Professional) and which region? Are the services already running on AWS, and where (ECS/EC2/local)?
3. What is the actual success criterion — Rescue "Execution Time" (end-to-end), throughput, cost, or demonstrating autoscaling behaviour for coursework?
4. Is `IncomingRequests` already wired to an alarm/scaling policy in the AWS account (none in repo)? Which service is intended to autoscale (Dockerfile suggests Priority)?
5. Is real per-message work (DB write, geo lookup, notification) planned? That changes everything: only then does Priority become compute/latency-bound and reactive autoscaling pays off.
6. Are events expected to be one-off bursts (drills) or sustained/overlapping waves?
7. Acceptable message loss? (QoS0 today.)
8. Are Emergency Service and Sensor intended to be on public internet?

**Session 2 updates to the above:** Q1 - answered by user: use a trigger script (`scripts/fire-event.js`); a real sensor→`/emergency` bridge is still absent. Q2 (partial) - AWS account 943138168360, IAM user `Vengatesh`, CLI default region ap-south-1 (irrelevant, see D6); HiveMQ plan/region still unknown; no `.env` in the repo tree, so HiveMQ credentials must be supplied to `scripts/aws-start.sh`. Q3-Q8 still open.

## 10. Assumptions to validate
- A1: Emergency Service is a synthetic load generator, not an external-facing receiver.
- A2: Priority is the intended autoscaling target (Dockerfile-only, CloudWatch metric namespace).
- A3: Broker host `…s1.eu…` = HiveMQ Serverless in EU.
- A4: `node:24` image ≈ 1 GB; Fargate scale-out ≈ 30-90 s (not measured).
- A5: HiveMQ 10 GB cap counts in+out; behaviour on exhaustion.
- A6: Real WAN/TLS throughput to EU broker differs materially from the loopback numbers.
- A7: Sensor water-level changes gradually in reality (feed-forward viable).

## 11. Next steps (suggested)
1. Resolve Open Q #1–#4 with the user.
2. Measure against the **real** HiveMQ endpoint from an AWS-region host (needs `.env`): publish rate ceiling of one connection, drop/disconnect behaviour, subscriber slowdown, TLS/WAN effects. (Local aedes numbers are only a sanity check.)
3. Measure Fargate cold-start with the current image vs slim image; alarm→task-running latency, to quantify whether reactive scaling can beat a burst.
4. Draft (docs only, not applied) the Application Auto Scaling step-scaling policy + alarm definitions and a Rescue-pinned ECS layout as IaC sketches if wanted.
5. If real work per message is planned, re-run capacity model with realistic per-message latency and derive tasks-per-load formula: `tasks ≈ ceil(arrival_msg_s / per_task_msg_s)`.
6. Decide on durable-queue redesign (§7.6 #2) — the change that makes scaling observable and safe.

---

## 12. Deployment artifacts and local validation (Session 2)

### 12.1 What was added (no application code changed)
```
docker-compose.yml                       local stack: Mosquitto + emergency + priority + rescue (priority scalable)
docker/certgen.sh, docker/mosquitto/     throwaway CA + server cert; Mosquitto TLS config
Emergency_Request_Service/Dockerfile(+.dockerignore)   node:24-alpine, npm ci --omit=dev, non-root
Rescue_Service/Dockerfile(+.dockerignore)              same
Priority_Service/Dockerfile.slim         slim variant; ORIGINAL Dockerfile untouched
scripts/fire-event.js                    zero-dep trigger: POSTs 3 zone requests to /emergency (sensor-equivalent payload)
scripts/local-up.sh / local-down.sh      compose start / stop (+ volume cleanup)
scripts/aws-start.sh / aws-terminate.sh  Terraform deploy (2-phase: ECR, build/push, rest) / destroy + leftovers check
scripts/aws-status.sh / aws-logs.sh      task counts, alarms, scaling activity / tail service logs
infra/terraform/*.tf                     VPC (2 public subnets, no NAT), ALB, ECR x3, ECS cluster + 3 Fargate services,
                                         IAM, SSM SecureString creds, step-scaling policies + 2 CloudWatch alarms
.gitignore                               + terraform state/tfvars/.terraform
```
**How the local stack runs the UNMODIFIED services:** the hard-coded HiveMQ hostname is registered as a Docker network alias of the local Mosquitto broker, which serves TLS on 8883 with a cert whose SAN is that hostname; the services trust the throwaway CA via `NODE_EXTRA_CA_CERTS`. No code change, no real HiveMQ traffic. (Without AWS creds the CloudWatch put fails and is caught by the app: "Could not send CloudWatch metric".)

**Terraform design (validated: `terraform validate` OK; `terraform plan` = 38 to add, 0 to change/destroy; NOT applied):**
- Region `ap-southeast-2` (D6). Emergency: 2 tasks (0.5 vCPU / 1 GB) behind an ALB reachable only from `allowed_cidr` (aws-start.sh passes your public IP /32), because the endpoint is unauthenticated and amplifies 1:100k. Priority: 0.25 vCPU / 0.5 GB, autoscaled 1..8. Rescue: exactly 1 task, min healthy 0 / max 100% so two are never alive during a deploy.
- Autoscaling: step scaling on `SUM(IncomingRequests)` over a 10 s period (alarm threshold = first step). Defaults: >=5k +1, >=20k +2, >=60k +4, >=150k +6 tasks (ChangeInCapacity, so a small event after a big one never scales down). Scale-in: alarm when Sum<1 for 10 consecutive minutes (missing data = breaching), -1 task per 300 s cooldown. Policies verified in plan output (relative bounds 0 / 15000 / 55000 / 145000).
- `initProcessEnabled = true` in the task definitions and `init: true` in compose so Node (PID 1) receives SIGTERM.
- HiveMQ credentials: SSM SecureString, injected through ECS `secrets` as `HIVEMQ_USERNAME/PASSWORD` env vars (the apps already read `process.env`). **They are also stored in Terraform state** (git-ignored).
- Rough cost while running: ~US$0.15-0.20/h (ALB + ~4 Fargate tasks + public IPv4) [ESTIMATE]. Always run `scripts/aws-terminate.sh`.
- ECS/ALB service-linked roles and image pulls from ECR over public IPs are assumed to work as usual [ASSUMPTION: untested, nothing was applied].

### 12.2 Local experiment results (compose + Mosquitto, Docker VM with 12 CPUs / 3.5 GB, Windows Docker Desktop)
| Test | Result |
|---|---|
| Event 70/60/50 (35k requests) | 35,000 completed in 1.75 s, 0 lost |
| Event 90/90/90 (300k requests), 1 Priority replica, 3 clean runs | **10.5 s, 10.3 s, 11.8 s** (~27k msg/s end to end), 0 lost |
| Same event, 4 Priority replicas, 3 clean runs | **23.1 s, 27.0 s, 28.4 s**, 0 lost |
| Shared-subscription distribution | 4 replicas each processed exactly 75,000 of 300,000: `$share` load balancing works as assumed |
| CPU during a burst (1 replica) | **broker ~98-103% (one core, saturated)**, rescue 71-87%, priority 42-99%, emergency ~0% after its loop |

Note: an early run showed 36.5 s at 4 replicas and 13.2 s at 1; the first timing loop read stale result lines and was discarded. The numbers above use a before/after counter of result lines.

**Interpretation [MEASURED + HYPOTHESIS]:**
- The broker is the bottleneck, as predicted in §6 #1. Local Mosquitto is single-threaded and hit one full core; more Priority replicas added subscribers, publishers and sockets and did **not** raise throughput, they made it ~2.3x slower. Hypothesis (not tested): per-message shared-subscription dispatch plus connection overhead on the single broker thread, with Rescue as the single fan-in.
- **HiveMQ Cloud is a multi-threaded/clustered broker and may not behave like Mosquitto.** This result shows that adding Priority replicas does not automatically help and can hurt when the broker or Rescue is the limiter. It does not prove it will hurt on HiveMQ. It must be re-measured against the real broker.
- Consequence for §7: autoscaling Priority is only worth demonstrating if (a) real per-message work is added, or (b) the real broker has headroom. Otherwise expect scale-out to be neutral or slightly negative for the "Execution Time" that Rescue prints. The deployment still provides the requested scaling machinery; choose the comparison experiment accordingly.

### 12.3 Next steps (post Session 2)
1. **Run the AWS deployment when the user says so** (`bash scripts/aws-start.sh`): supply HiveMQ creds; then `EMERGENCY_URL=<output> node scripts/fire-event.js 90 90 90`; watch `scripts/aws-status.sh`. Measure alarm-to-task-running latency and compare Rescue "Execution Time" at `priority_min_capacity` 1 vs 4 (via TF_VAR) to test the warm-floor claim against the real broker.
2. Repeat the local 1-vs-N replica test with a multi-threaded broker (HiveMQ CE or EMQX container) to separate "broker single thread" from "Rescue fan-in" effects.
3. If real per-message work is planned, add it and re-run; only then does Priority CPU/latency become the bottleneck that autoscaling addresses.
4. Consider the durable-queue redesign (§7.6 #2), which also makes scale-in safe.
5. Known IaC gaps: local Terraform state only (no remote backend or locking), HTTP-only ALB, no WAF, `latest` tag also pushed.

---

## 13. Real AWS deployment: cost optimization, region decision, and two verified test runs (Session 3)

### 13.1 What changed in the Terraform (still no application code touched)
User requests this session: continue and actually run/test on AWS; make region configurable and asked specifically about ap-south-1; keep cost minimal; add an optional way to test without touching the real broker.

- **New variables, all defaulting to the lean/off setting:** `use_test_broker` (false), `use_fargate_spot` (true), `enable_alb` (false). `hivemq_username`/`password` now default to `""` (only required when `use_test_broker=false`, enforced with a Terraform `precondition`).
- **New file `infra/terraform/broker.tf`** (only created when `use_test_broker=true`): Mosquitto on Fargate, registered under a Cloud Map **private DNS namespace named after the real HiveMQ hostname's suffix** (`s1.eu.hivemq.cloud`) with service name `1490e7aa...`, so inside the VPC that hard-coded hostname resolves to the test broker. A `tls_*` provider chain issues a throwaway CA + server cert (SAN = that hostname) at apply time; the cert/key go through SSM SecureString, the CA is a plain env var. Security group only admits the service tasks. On-demand (not Spot): an interrupted broker would drop every in-flight message.
- **ALB is now optional** (`alb.tf`, all resources `count = var.enable_alb ? 1 : 0`). Default: Emergency gets `assign_public_ip = true` and its security group admits only `var.allowed_cidr` directly on port 3001 — no fixed ALB cost (~US$0.035/h saved). `scripts/aws-url.sh` resolves the reachable URL either way (ALB DNS, or the running task's public IP via `ecs describe-tasks` + `ec2 describe-network-interfaces`).
- **Fargate Spot** (`aws_ecs_cluster_capacity_providers` + `capacity_provider_strategy`) for Emergency and Priority only; Rescue and the test broker stay on-demand (Spot interruption for either is a functional problem: Rescue is a stateful singleton, and interrupting the broker drops every in-flight message).
- **Lower ceilings:** `priority_max_capacity` 8→4, `emergency_desired_count` 2→1 (no-ALB mode can only usefully reach one task anyway), ECR lifecycle policy keeps the 3 newest images per repo.
- **`scripts/aws-start.sh`** rewritten with flags `--test-broker`, `--alb`, `--no-spot`, `-y`; prints the actual mode and a rough cost line before asking to proceed. **`scripts/aws-url.sh`** is new (see above).
- **Region:** kept as `var.region`/`REGION=` (already configurable), but see D9 — real runs stay in ap-southeast-2 because the CloudWatch client's region is hard-coded in the app.

Validated with `terraform validate` and `terraform plan` in three configurations before any apply: default (creds required, fails cleanly without them), default with dummy creds (38 resources), and `use_test_broker=true` (46 resources, no creds required). Local component tests before any AWS spend: built the `docker/mosquitto/Dockerfile.aws` broker image and started it locally with the same env-var-injected cert content the Terraform passes; ran an unmodified Emergency image locally against it using the exact `command` override `ecs.tf` uses (write `TEST_CA_PEM` to a file, then `exec node ...`) — connected successfully before ever touching AWS.

### 13.2 Two real AWS deployments, both `--test-broker` mode, ap-southeast-2

**Deployment 1** (this session's predecessor): full deploy (50 resources) → confirmed the Emergency URL answered → torn down without firing any events (user said stop mid-session) → verified clean (`aws ecs describe-clusters` showed `INACTIVE`, 0 running tasks, no VPC, no ALB).

**Deployment 2** (this session): full deploy (also `--test-broker`, Spot, no ALB) → **fired real events end to end**:

| Event | Requests | Result |
|---|---|---|
| 70/60/50 | 35,000 | `Requests Completed: 35000`, **Execution Time: 15.020 s** (vs 1.75 s in the Session 2 local/loopback test — expected: real network hops between separate Fargate tasks, not one machine's loopback) |
| 90/90/90 | 300,000 | `Requests Completed: 300000`, **Execution Time: 38.498 s** |

Autoscaling, observed directly (not inferred): `sdr-priority-incoming-high` alarm fired and `describe-scaling-activities` shows two successful `sdr-priority-scale-out` triggers. Priority went **1 → 3** (after the 35k event: ≥20,000 step adds 2) → **4/4, i.e. max capacity** (after the 300k event). The Emergency task's IAM role worked correctly: logs show `CloudWatch workload metric sent: 100000` for each zone (no permission errors).

**Key finding — direct evidence for the scale-out-lag risk already written in §7.4 #1, now measured, not just theorized:**
Per-task `Total Processed` counters (summed across both events, ~335,000 messages total) at the point of measurement:

| Task | Joined | Total Processed |
|---|---|---|
| `eb691dec...` (the original warm task, running since before either event) | before both events | **201,000 (~60%)** |
| `322e8f8d...` (added after the 35k event's scale-out) | mid-burst | 66,000 |
| `8be5527f...` (added after the 35k event's scale-out) | mid-burst | 66,000 |
| `d30bdaea...` (added after the 300k event's scale-out, hit max capacity) | connected at 06:22:59 UTC, ~25s after the 300k burst started | ~2,000 or less (only just connected as the burst was ending) |

Interpretation: the shared subscription itself load-balances correctly (confirmed again), but **new capacity from a reactive alarm arrives too late to meaningfully rebalance a burst that's already draining**. The already-warm task did the majority of the work regardless of autoscaling. This directly supports keeping `priority_min_capacity` high as the actual lever for a max-size event (§7.3), not the step-scaling policy — the policy mattered for the *next* event, not the one that triggered it.

Also observed: on Windows/Git Bash, `aws logs tail` (and similar commands) fail with `'charmap' codec can't encode character '◇'` because the app's dotenv banner prints a Unicode character the console can't display; fixed per-call with `export PYTHONIOENCODING=utf-8 PYTHONUTF8=1` (Bash tool shell state does not persist between calls, so this must be repeated each time). Documented in the README troubleshooting table.

### 13.3 PENDING at the time this section was written
**Deployment 2 (§13.2) had not yet been torn down.** The session was interrupted (user moved on to asking about the EC2 console and doc updates) before teardown could be confirmed. Whoever resumes this investigation should treat this as the first thing to check:
```bash
bash scripts/aws-status.sh                                   # or:
aws ecs describe-clusters --clusters sdr --region ap-southeast-2 --query 'clusters[0].status'
```
If it says anything other than `INACTIVE` / no services, real AWS resources are still running and billing (Fargate Spot + one on-demand Rescue task + one on-demand test-broker task) — run `bash scripts/aws-terminate.sh` unless there's an active reason to keep it up.

### 13.4 Next steps (superseding the equivalent items in §11/§12.3)
1. **Resolve §13.3 above.**
2. A real HiveMQ-backed deployment (needs credentials) is still untested — everything measured in §13.2 used the throwaway test broker, so latencies and the scale-out-lag finding should be treated as "true on this architecture," not yet "true on the production broker."
3. Observing a full scale-in cycle (10 idle minutes → `sdr-priority-idle` alarm → task removed) was proposed but not run this session, to avoid extra idle billing.
4. If the ap-south-1 requirement becomes firm later, the real fix is making the CloudWatch client's region configurable via an env var in `emergency_service.js` (a one-line, additive app change) rather than living with disabled autoscaling — flag this to the user if it comes up again (see D9).
