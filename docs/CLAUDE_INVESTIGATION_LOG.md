# Investigation Log (append-only)

Companion to [CLAUDE_PROJECT_CONTEXT.md](CLAUDE_PROJECT_CONTEXT.md). Each session appends a new dated section; do not rewrite old sessions. Goal of the investigation: determine how the Smart Disaster Relief IoT system should scale in AWS, based on actual code. No application code is modified.

---

## Session 1 — 2026-09-27

### Scope / method
- Explored the whole repo (15 tracked files; all 4 source files + Dockerfile + package manifests + git log read in full). Repo is small: 4 Node.js services, no IaC/tests/CI/DB/queue.
- Grepped for producers/consumers of every topic, port 3001, `/emergency`, HTTP clients.
- Checked local env: Node v22.14.0; no `node_modules` and no `.env` in the repo tree (secrets not inspected).
- Verified external claims via web search (HiveMQ Cloud limits, HiveMQ shared subscription/QoS0 behaviour, ECS Application Auto Scaling, AWS IoT Core quotas, mqtt.js defaults).
- Ran local experiments in the session scratchpad (outside the repo; not preserved in the repo). Verified mqtt.js defaults by reading installed `mqtt@5.16.0` source.

### Discoveries
1. **Topology.** Sensor → (`disaster/water/Zone_*`) → ??? → `POST /emergency` (Emergency :3001) → `disaster/emergency/requests` → Priority (shared sub) → `disaster/emergency/prioritized` → Rescue (plain sub). Broker is one external HiveMQ Cloud host hard-coded in all four services. The only AWS call is `PutMetricData` to CloudWatch `SmartDisasterRelief/IncomingRequests` (region `ap-southeast-2`, 1-second storage resolution, no dimensions).
2. **Missing link.** Nothing subscribes to `disaster/water/*` and nothing calls `/emergency`. Also contract mismatch: sensor payload has `value`, Emergency reads `event.waterLevel` (emergency_service.js:81); forwarding the sensor JSON as-is would produce `NaN` → 0 requests. Logged as Open Question #1.
3. **Load is synthetic and amplified.** `getRequestCount()` (duplicated in sensor and Emergency) maps water level → 0/5k/10k/20k/50k/100k. One `POST` → up to 100k publishes in a synchronous loop; a max event is 300k messages, ≈1.2M broker operations (4 hops/request), ≈379 MB payload. Load ∝ water level, not device count. Emergency is effectively the **load generator**, not a load receiver (assumption A1).
4. **Metric timing quirk.** `sendWorkloadMetric()` is called before the loop but its `await` can't dispatch until the synchronous loop and response finish → metric is emitted after the burst is enqueued, and represents injected work, not remaining backlog. Not per-task, so plain target tracking is a poor fit.
5. **Priority is the only horizontally scalable component** (`$share/priority-workers/...`, random mqtt.js clientId per process, stateless aside from per-process log counters). Unused `express` dependency; no health endpoint; no SIGTERM handling; Dockerfile uses full `node:24`, `npm install`, root user.
6. **Rescue is a stateful singleton.** Non-shared subscription (every replica would get every message), in-memory queue/teams/floodEvents (never evicted). Assignment completes instantly (available toggled false→true synchronously), so the queue never builds. Completion test `completed === totalEventRequests` breaks on any lost message → event never completes and leaks. Latent O(N) scan per team per message.
7. **Reliability model is QoS0 everywhere** (mqtt.js default), `clean:true`; verified mqtt.js 5.16.0 defaults: `queueQoSZero:true` (unbounded offline buffering), `keepalive:60`, `reconnectPeriod:1000`, `resubscribe:true`. Scale-in/crash ⇒ message loss ⇒ incomplete events.
8. **Broker is the shared ceiling and sits outside AWS.** Host is `…s1.eu.hivemq.cloud` vs AWS region `ap-southeast-2` (geography assumption).
9. **[EXTERNAL] limits gathered:** HiveMQ Cloud Serverless free: 100 connections, 10 GB/month. HiveMQ: QoS0 not queued for offline clients. AWS IoT Core (if chosen): ≈100 publishes/s and 512 KB/s per connection, default 10k inbound / 20k outbound publishes/s per account (a 100k burst from one connection would be heavily throttled). AWS: target tracking needs a per-capacity metric or metric math; high-res custom metrics supported for ECS scaling.

### Experiments (all local loopback, Node 22.14, no TLS/WAN; scripts lived in the scratchpad `bench.js` / `pipe.js`)
Method A (`bench.js`): replicate each handler's logic on 100k synthetic messages, no network.
| Measurement | Result |
|---|---|
| Emergency build+stringify 100k | 347 ms; payload ≈ 307 B/msg |
| Priority parse+spread+stringify 100k | 347 ms ≈ 288k msg/s/core; out ≈ 325 B/msg |
| Rescue handler 100k (with 50-team scan) | 225 ms ≈ 444k msg/s/core; **max rescueQueue length = 0**; completed=100000 |
| One `assignTeams()` over a 50k backlog | 8.5 ms (latent O(N²) risk) |

Method B (`pipe.js`): real `mqtt@5.16.0` clients (Emergency-like publisher, Priority-like subscriber/republisher, Rescue-like subscriber) through an in-process `aedes` broker on loopback. Non-shared subscription used (aedes has no `$share`); everything in ONE process/event loop, so numbers are a pessimistic floor.
| N | Publish-loop return | Delivered to Rescue | Lost | Total | End-to-end | RSS |
|---|---|---|---|---|---|---|
| 20,000 | 159 ms | 20,000 | 0 | 1.77 s | ≈11.3k msg/s | 130 MB |
| 100,000 | 564 ms | 100,000 | 0 | 6.99 s | ≈14.3k msg/s | 324 MB |

Interpretation: logic isn't the bottleneck; a 100k burst enqueues in ~0.5 s and drains in ~7 s under a deliberately pessimistic setup ⇒ reactive autoscaling (alarm + Fargate start + image pull) is probably slower than the burst. **Not** valid as an AWS/HiveMQ throughput claim.

### Conclusions so far (see context doc §7)
- Scale **Priority** only; pin **Rescue = 1**; keep **Emergency** small/fixed and never scale it on request count; broker plan is the true ceiling.
- Recommended mechanism: ECS Fargate + Application Auto Scaling **step scaling** on `SUM(IncomingRequests)` keyed to the tier constants, **warm minimum** sized for a max event, slow scale-in; optional feed-forward on sensor WARNING/CRITICAL. Best structural fix: durable queue + backlog-per-task scaling.
- Scale-in is a correctness risk under QoS0.

### Corrections / caveats made during the session
- First aedes run hung: aedes v1 exports `{ Aedes }` and requires `await Aedes.createBroker()`; a stale process then held port 1884; re-ran on 1893. No effect on results.
- Web-search-derived numbers are unverified secondary sources; must be re-checked on official quota pages before sizing/pricing.

### Open at end of session
See context doc §9 (esp. Q1 missing sensor→Emergency link, Q2 HiveMQ plan/region & where services run, Q3 success criterion, Q5 real per-message work).

### Files changed this session
- Created `docs/CLAUDE_PROJECT_CONTEXT.md`, `docs/CLAUDE_INVESTIGATION_LOG.md`. **No application files modified.**

---

## Session 2 — 2026-09-27

### Requests from the user
- "/emergency - yes throw script": the sensor-to-`/emergency` gap (Open Q #1) should be filled by a trigger script.
- "check my aws configure list": the deployment target must come from the local AWS config.
- "proceed with docker compose and terraform (include start and terminate script)".

### Discoveries
1. `aws configure list`: default profile, static keys, **region ap-south-1** (also a `vengatatdev` profile). `sts get-caller-identity`: account 943138168360, IAM user `Vengatesh`. ap-southeast-2 has 3 AZs and only the default VPC. **Conflict:** the CloudWatch client hard-codes `ap-southeast-2` (an explicit SDK region beats the environment), so the metric and therefore the scaling alarms must be in ap-southeast-2. Decision D6: deploy there and ignore the CLI default.
2. The unmodified services can run against a local broker: Docker network alias equal to the hard-coded HiveMQ hostname, a Mosquitto TLS cert with that SAN, and `NODE_EXTRA_CA_CERTS`. Verified end to end.
3. **Scaling result contradicts the naive expectation.** 300k event: 1 Priority replica 10.3-11.8 s vs 4 replicas 23.1-28.4 s (3 runs each, after discarding an invalid first attempt). The shared subscription split load exactly 75k x 4. Mosquitto pinned at ~100% of one core. See context doc §12.2 for interpretation and caveats (Mosquitto is single-threaded; HiveMQ may differ).
4. Terraform plan against the real account (read-only): 38 resources to add; step-scaling bounds verified (0-15000 +1, 15000-55000 +2, 55000-145000 +4, >=145000 +6).
5. Windows / Git Bash pitfalls found and fixed: (a) MSYS rewrote `/ecs/sdr` and `/sdr` CLI arguments to `C:/Program Files/Git/...`, fixed with `MSYS_NO_PATHCONV=1` in the AWS helper scripts; (b) long multi-heredoc shell commands failed with an EOF quoting error and wrote nothing, so files were written with the editor tool.
6. The first replica-timing loop read stale result lines (a 4-replica value identical to an earlier 1-replica value); replaced by a before/after counter of "Execution Time" lines. All reported numbers come from the counter method.

### Actions performed
- Created the files listed in context doc §12.1. Ran the local stack: up, functional events, 6 timed 300k runs, scaled priority 1 and 4, then `local-down.sh` (containers and volumes removed; verified none left).
- Ran `terraform init/validate/plan` (no resources created). Ran `aws-terminate.sh -y` against empty state: verification queries work (tag API clean; ECR/log-group/SSM prefixes empty).
- **NOT done:** `aws-start.sh` / `terraform apply` were not run. They create billable resources and need HiveMQ credentials that are not in the repo. The deploy path is validated only by syntax checks, plan and component tests, not by a real deployment.

### Open at end of session
- User go-ahead and HiveMQ credentials to run the real deployment; HiveMQ plan/region; Open Q #3-#8 unchanged.
- Re-measure scaling against the real broker (and/or a multi-threaded local broker).

### Files changed this session
New: docker-compose.yml, docker/*, {Emergency_Request_Service,Rescue_Service}/{Dockerfile,.dockerignore}, Priority_Service/Dockerfile.slim, scripts/*, infra/terraform/*.tf and `.terraform.lock.hcl`. Modified: `.gitignore` (terraform ignores), docs. **No application `.js` file was touched.**

---

## Session 3 — 2026-09-27

### Requests from the user
- "Now let's continue and run and test it." (i.e. actually deploy to AWS and fire events, not just plan/validate.)
- "Region can we use ap-south-1 and also as configurable."
- "Is it possible to populate data outside access" — clarified as: can events be triggered from outside AWS (from the local machine)? Answer: yes, already true by design (Emergency gets a public IP restricted to the caller's IP in no-ALB mode).
- "make sure cost optimization is there for this project i don't want to put more money" (said while choosing to build the test broker as an opt-in, off-by-default feature).
- Mid-session: "stop it. will do after sometimes" (after a deployment had already finished running in the background — not something a chat message can retroactively stop).
- Later: "not able to see ec2 instance from my aws" + "update the readme file and what our progress did in the corresponding docs."

### Discoveries
1. **Region conflict is real, not cosmetic.** `emergency_service.js:16` hard-codes the CloudWatch client to `ap-southeast-2`. A CloudWatch alarm cannot watch a metric published in a different region, and an Application Auto Scaling policy must be in the same region as the ECS service it scales. So deploying to `ap-south-1` as asked would either require (a) accepting broken/no autoscaling, or (b) a one-line app-code change to make the region configurable. Presented to the user as an explicit choice; they chose to keep the real deployment in ap-southeast-2 (D9). The region remains a Terraform variable for later.
2. **"No EC2 instance" is expected, not a bug.** The whole stack runs on Fargate (serverless), which never appears in the EC2 console; Fargate Spot also doesn't appear under EC2 Spot Requests. The user was very likely also looking in the wrong console region (their CLI default is `ap-south-1`; the deployment is in `ap-southeast-2`).
3. Built an **optional test broker** (`infra/terraform/broker.tf`, `var.use_test_broker`, default false): Mosquitto on Fargate + Cloud Map private DNS that makes the hard-coded HiveMQ hostname resolve to it inside the VPC, plus a throwaway CA/cert issued via the Terraform `tls` provider. Lets the whole system be deployed and tested on AWS with zero HiveMQ account/credentials. Verified locally first (broker container + a real Emergency image using the same command-override CA-injection trick as the ECS task definition) before spending anything on AWS.
4. Added cost controls, all defaulting to the cheap/off option: Fargate Spot for Emergency/Priority (on, but not for Rescue or the test broker — an interruption there is a functional problem, not just a blip), no ALB by default (public IP + security group instead, saves the ALB's fixed hourly cost), `priority_max_capacity` lowered from 8 to 4, `emergency_desired_count` lowered from 2 to 1, an ECR lifecycle policy capping stored images at 3 per repo.
5. **Two full real deployments this session** (both `--test-broker`, ap-southeast-2):
   - First: deploy → confirm URL reachable → user said stop (deployment had already finished) → user chose to tear down immediately → verified clean via `aws ecs describe-clusters` (`INACTIVE`, 0 tasks) plus checks for leftover ALBs/VPCs/ECR/log groups/SSM params.
   - Second: redeployed, then **fired real events**: 35,000-request event completed correctly in 15.020 s; 300,000-request event completed correctly in 38.498 s. Both numbers are end-to-end on real Fargate/network, notably slower than the Session 2 local-loopback numbers (1.75 s / ~11 s), as expected.
6. **Autoscaling fired for real and was observed directly**, not inferred: CloudWatch alarm `sdr-priority-incoming-high` went to ALARM and `describe-scaling-activities` showed two successful triggers of the `sdr-priority-scale-out` policy. Priority scaled 1 to 3 (after the 35k event) to 4/4 = max capacity (after the 300k event). The Emergency IAM task role correctly published `PutMetricData` (log line `CloudWatch workload metric sent: 100000`, no permission errors).
7. **New measured finding, not just hypothesis:** summed per-task `Total Processed` counters across both events (~335,000 messages total) showed the original warm task processed 201,000 (~60%), two tasks added mid-burst processed 66,000 each, and the last task (added once the 300k event hit max capacity) connected roughly 25 seconds after that burst started and processed almost nothing. This is direct evidence that reactive scale-out capacity often arrives after most of a burst has already drained through whatever was already warm — consistent with the Session 2 local hypothesis, now confirmed on real infrastructure (though still against the test broker, not real HiveMQ).
8. Windows/Git Bash + AWS CLI: `aws logs tail` (and similar) crashed with a `charmap` Unicode encoding error caused by a Unicode character in the app's own dotenv startup banner hitting the Windows console codepage. Fixed per-call with `PYTHONIOENCODING=utf-8 PYTHONUTF8=1` (must be re-exported every Bash tool call; shell state doesn't persist between calls in this environment). An earlier, similar `describe-services` read during this same investigation showed `running: 0` for several polls while 4 tasks were independently confirmed `RUNNING` — an ECS API eventual-consistency lag during the scale-out window, not a real stuck deployment; re-querying moments later showed `running: 4` correctly.

### Actions performed
- Edited `infra/terraform/variables.tf`, `network.tf`, `alb.tf`, `iam.tf`, `versions.tf`, `ecr.tf`, `ecs.tf`, `outputs.tf`; added `infra/terraform/broker.tf`; added `docker/mosquitto/{Dockerfile.aws,entrypoint.sh,mosquitto-aws.conf}`; added `scripts/aws-url.sh`; rewrote `scripts/aws-start.sh` with `--test-broker`/`--alb`/`--no-spot` flags.
- `terraform fmt`, `init -upgrade` (added the `hashicorp/tls` provider), `validate`, and `plan` in three configurations, all before any apply.
- Local Docker tests of the new broker image and the CA-injection command override, using the same env vars/command Terraform generates, before deploying to AWS.
- Ran `bash scripts/aws-start.sh -y --test-broker` twice (full deploy each time, ~50 resources).
- First deployment: teared down via `bash scripts/aws-terminate.sh -y`; verified with `aws ecs describe-clusters` (INACTIVE), `list-tasks` (empty), `elbv2 describe-load-balancers` (none), `ec2 describe-vpcs` (none tagged).
- Second deployment: fired a 35k and a 300k event via `scripts/fire-event.js` against the real AWS public IP; read back results via `aws logs tail` (rescue, priority, emergency) and `aws ecs describe-services` / `application-autoscaling describe-scaling-activities` / `cloudwatch describe-alarms`.
- Updated `README.md` (EC2/Fargate clarification, region caveat, test-broker instructions, new script flags, `aws-url.sh` usage, encoding troubleshooting entry, project-status section) and this pair of docs.

### Open at end of session — IMPORTANT
- **The second deployment (§discoveries 5-7 above) had not been torn down when this entry was written.** The session moved on to documentation requests before a teardown decision was confirmed. **Whoever resumes must check `bash scripts/aws-status.sh` / `aws ecs describe-clusters --clusters sdr --region ap-southeast-2` first** and run `bash scripts/aws-terminate.sh` if anything is still active, per the user's explicit low-cost preference.
- Real-HiveMQ deployment still untested (no credentials available).
- Full scale-in cycle (idle alarm actually removing a task) not observed this session — skipped to avoid extra idle billing.
- If ap-south-1 becomes a firm requirement, the actual fix is a one-line app change (CloudWatch region from env var) — the user was not asked to approve that this session; D9 recorded them choosing to keep ap-southeast-2 instead.

### Files changed this session
Modified: `infra/terraform/{variables,network,alb,iam,versions,ecr,ecs,outputs}.tf`, `scripts/aws-start.sh`, `README.md`, both docs files. New: `infra/terraform/broker.tf`, `docker/mosquitto/{Dockerfile.aws,entrypoint.sh,mosquitto-aws.conf}`, `scripts/aws-url.sh`. **No application `.js` file was touched.**
