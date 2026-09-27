# Smart Disaster Relief (IoT + AWS scaling study)

A small flood-response simulation: a few Node.js programs that talk to each other over MQTT messaging, plus everything needed to run it on your own computer (Docker) or on AWS (Terraform).

**New to some of these tools?** Quick plain-language definitions:
| Term | In one sentence |
|---|---|
| **Docker / Docker Compose** | Lets you run this project's programs in isolated little boxes ("containers") without installing Node.js versions or a messaging server by hand. Compose starts several of them together with one command. |
| **MQTT / "broker"** | A lightweight way for programs to send each other short messages (instead of a normal web request). The "broker" is the middleman server all the messages pass through. |
| **Terraform** | A tool that creates (and later deletes) cloud resources from a text description, so setting up AWS is a repeatable command instead of manual clicking. |
| **AWS Fargate / ECS** | AWS's way of running containers "serverlessly" — you never see or manage a virtual machine, AWS just runs your containers. |

If you just want to see it work, skip to the **[Quick Start](#quick-start-5-minutes)** below.

---

## Quick start (5 minutes)

This runs everything on your own machine — no AWS account, no cost, no cloud credentials.

1. **Install two things** (skip any you already have): [Docker Desktop](#docker) and [Node.js](#nodejs). On Windows, also install [Git for Windows](#git-bash-windows-only) for the Bash terminal.
2. **Open a terminal in this folder** (macOS/Linux: any terminal; Windows: **Git Bash**, not PowerShell or cmd) and run:
   ```bash
   bash scripts/local-up.sh
   ```
   Wait about a minute for it to build and start. You should see it finish with a message that starts with `Priority replicas: 1`.
3. **In a second terminal**, trigger a simulated flood:
   ```bash
   node scripts/fire-event.js 90 90 90
   ```
4. **Watch the result:**
   ```bash
   docker compose logs -f rescue
   ```
   Within a few seconds you'll see a block that looks like this — that's the whole pipeline working end to end:
   ```
   ========== FLOOD EVENT RESULT ==========
   Simulated Requests: 300000
   Requests Completed: 300000
   Execution Time: 10.5 seconds
   ========================================
   ```
5. **When you're done**, clean up:
   ```bash
   bash scripts/local-down.sh
   ```

That's it — you've run the full system. Section ["Run it locally, step by step"](#run-it-locally-step-by-step) below explains what just happened and how to experiment further (e.g. scaling to more workers). Section ["Deploy it to AWS"](#deploy-it-to-aws) covers the cloud version.

---

## Prerequisites

You don't need to be an expert in any of these tools — just get them installed and confirm the version command works, then move on.

### For running locally (needed either way)

| Tool | Download | Install notes | Confirm it worked |
|---|---|---|---|
| <a name="docker"></a>**Docker Desktop** (includes Docker Compose) | **[docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/)** | Windows/macOS: run the installer, then **open Docker Desktop and leave it running** — the little whale icon in your system tray/menu bar should be steady, not animating. Linux: install [Docker Engine](https://docs.docker.com/engine/install/) + the [Compose plugin](https://docs.docker.com/compose/install/linux/) instead. | `docker --version` and `docker compose version` both print a version number |
| <a name="nodejs"></a>**Node.js** (18 or newer) | **[nodejs.org/en/download](https://nodejs.org/en/download)** — pick the **LTS** installer for your OS | Just run the installer with defaults. Only used for one small trigger script. | `node -v` prints `v18.x` or higher |
| <a name="git-bash-windows-only"></a>**Git for Windows** (Windows only — gives you the "Git Bash" terminal) | **[git-scm.com/download/win](https://git-scm.com/download/win)** | Run the installer with defaults. macOS/Linux already have a working Bash terminal, skip this. | Open the **"Git Bash"** app from your Start menu; run `bash --version` |
| A free port | Nothing to install | Make sure nothing else on your computer is already using port `3001`. | — |

The very first time you run the Quick Start, Docker will download some base images in the background — that first run can take a few minutes on a slower connection. Every run after that is fast.

### For deploying to AWS (only needed for the "Deploy it to AWS" section)

Everything above, plus:

| Tool | Download | Install notes | Confirm it worked |
|---|---|---|---|
| **An AWS account** | **[aws.amazon.com](https://aws.amazon.com/)** (free to create) | Inside the account, create credentials: **[console → IAM → Users → your user → Security credentials → Create access key](https://console.aws.amazon.com/iam/)**. For a personal/sandbox account, attaching the built-in `AdministratorAccess` policy to your user is the simplest way to make sure nothing gets blocked by a missing permission. | — |
| **AWS CLI v2** | **[AWS CLI install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)** (direct installer links for Windows/macOS/Linux on that page) | After installing, run `aws configure` once and paste in the access key/secret from the step above. | `aws --version`, then `aws sts get-caller-identity` prints your account details |
| **Terraform** (1.5 or newer) | **[developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install)** | Windows: easiest via `winget install Hashicorp.Terraform` or the zip on that page. macOS: `brew install terraform`. Linux: apt/yum instructions on that page. | `terraform version` prints `Terraform v1.5` or higher |

> You do **not** need a HiveMQ (MQTT broker) account to try AWS — see the `--test-broker` option in the AWS section below, which sets up a temporary broker for you automatically.

---

## What this project does

Someone enters flood water levels for three zones (A, B, C). Each zone's water level is turned into a number of simulated citizen emergency requests, and those requests flow through a pipeline that prioritises them and assigns rescue teams.

| Water level | Requests generated for that zone |
|---|---|
| below 50 | 0 |
| 50-59 | 5,000 |
| 60-69 | 10,000 |
| 70-79 | 20,000 |
| 80-89 | 50,000 |
| 90-100 | 100,000 |

The largest possible event (90/90/90) is **300,000 messages**. Three sensor readings turn into hundreds of thousands of messages, so the load depends on water level, not on the number of devices.

## Architecture

```
 Sensor_Device  (simulated water sensors, interactive CLI)          scripts/fire-event.js (trigger script)
        |  MQTT disaster/water/Zone_*                                        |  HTTP POST /emergency
        |  (nothing in this repo consumes these topics)                      v
        |                                                   Emergency_Request_Service  (Express :3001)
        |                                                     - turns water level into N requests
        |                                                     - publishes N MQTT messages
        |                                                     - sends CloudWatch metric IncomingRequests
        |                                                              |  MQTT disaster/emergency/requests
        |                                                              v
        |                                                   Priority_Service  (scalable: MQTT shared subscription)
        |                                                     - assigns CRITICAL / HIGH / MEDIUM / LOW
        |                                                              |  MQTT disaster/emergency/prioritized
        |                                                              v
        |                                                   Rescue_Service  (must run exactly ONE copy)
        |                                                     - in-memory queue + 50 rescue teams
        |                                                     - prints "FLOOD EVENT RESULT" with total time
        +---------------- all messaging goes through one MQTT broker (HiveMQ Cloud, or Mosquitto locally)
```

Read these facts before experimenting:
- **Priority Service** can run as many copies as you like (MQTT "shared subscription" — a feature that automatically splits incoming messages across however many copies are running).
- **Rescue Service** keeps its state in memory and must stay at one copy. A second copy would receive every message too and double-count.
- **The broker is a shared ceiling.** Adding Priority copies does not automatically make things faster (see "[Things worth knowing](#things-worth-knowing-when-you-experiment)").
- **Sensor to Emergency link:** the interactive sensor publishes to MQTT, but nothing in the repo forwards that to `POST /emergency`. `scripts/fire-event.js` fills that gap by calling `/emergency` directly with the same data the sensor computes.

Deeper analysis (bottlenecks, scaling decisions, measurements, open questions) is in [docs/CLAUDE_PROJECT_CONTEXT.md](docs/CLAUDE_PROJECT_CONTEXT.md). A dated history of what was investigated is in [docs/CLAUDE_INVESTIGATION_LOG.md](docs/CLAUDE_INVESTIGATION_LOG.md).

## Repository layout

```
Sensor_Device/               interactive water sensor simulator (MQTT publisher)
Emergency_Request_Service/   HTTP API + fan-out generator + CloudWatch metric   (has Dockerfile)
Priority_Service/            priority classifier, scalable worker               (Dockerfile + Dockerfile.slim)
Rescue_Service/              rescue dispatcher / result printer                 (has Dockerfile)
docker-compose.yml           local stack: Mosquitto + the three services
docker/                      local broker config + throwaway TLS certificate generator
scripts/                     fire-event.js, local-up/down, aws-start/terminate/status/logs
infra/terraform/             AWS: VPC, ALB, ECR, ECS Fargate, IAM, SSM, autoscaling, alarms
docs/                        investigation notes and findings
```

## Run it locally, step by step

(If you already did the [Quick Start](#quick-start-5-minutes), this section explains it in more depth and shows extra things to try.)

All commands are run from the repository root, in a terminal (Git Bash on Windows).

**1. Start everything**
```bash
bash scripts/local-up.sh          # 1 Priority worker
# or: bash scripts/local-up.sh 4  # 4 Priority workers
```
This builds the images and starts four things: `broker` (a local stand-in MQTT server), `emergency`, `priority`, `rescue`. You'll also see a `certgen` container that generates a throwaway security certificate and then exits — that's expected, not an error. Check everything is up:
```bash
docker compose ps
```
Expect `broker` to show `healthy` and the three services `Up`.

> **How it works:** the four application programs are completely unmodified — same code as the "real" version. Inside this local setup, the hostname they expect for their MQTT broker is quietly redirected to the local `broker` container instead, with a matching security certificate, so they connect successfully without knowing the difference.

**2. Fire a flood event** (in a second terminal)
```bash
node scripts/fire-event.js 70 60 50      # medium event: 35,000 requests
node scripts/fire-event.js 90 90 90      # maximum event: 300,000 requests
```
Optional flags: `--repeat N --every SECONDS` (repeat the event), `--parallel` (post the three zones at once), `--url http://host:3001`.

**3. Observe the result**
```bash
docker compose logs -f rescue
```
You will see:
```
========== FLOOD EVENT RESULT ==========
Zone A Water Level: 90
Zone B Water Level: 90
Zone C Water Level: 90
Simulated Requests: 300000
Requests Completed: 300000
Execution Time: 10.5 seconds
========================================
```
*Execution Time* is your main measurement: the time from the event start until the last request was completed. On the machine used for the docs, a 300k event took about 10-12 seconds with one Priority worker. Yours will differ.

Other useful views:
```bash
docker compose logs emergency          # "Requests Generated" per zone
docker compose logs priority           # "Priority Summary" every 1000 requests (per worker)
docker stats                           # CPU per container while an event runs
```
`Could not send CloudWatch metric: Could not load credentials` in the emergency log is **expected locally** — there's no AWS account involved here, and the app simply catches that error and carries on.

**4. Scale the Priority workers and compare**
```bash
docker compose up -d --scale priority=4 --no-recreate priority
node scripts/fire-event.js 90 90 90
docker compose logs rescue | grep "Execution Time"      # newest line is last
```
With 4 workers, each one processes roughly a quarter of the messages (see the `Total Processed` lines in each `docker logs smart-disaster-relief-priority-N`). Watch `docker stats` during a run to see which container is at 100% CPU.

**5. Optional: try the interactive sensor**
The sensor connects to the real HiveMQ cluster with credentials from a `.env` file, so it does not work in this local setup. Use `fire-event.js` instead.

**6. Stop and clean up**
```bash
bash scripts/local-down.sh
```
This removes the containers, network and generated certificates — your computer is left exactly as it was before.

## Deploy it to AWS

**This costs real money while it's running** (small amounts with the cost-saving defaults below, but never assume it's free — always finish with the teardown step).

**1. Prepare**

Make sure the AWS prerequisites above are done, then:
```bash
aws configure                      # once, if not already done
aws sts get-caller-identity        # confirms who you are
```
You do **not** need HiveMQ (MQTT broker) credentials to try this — see `--test-broker` below. If you *do* have credentials for the hard-coded HiveMQ cluster, either put them in a git-ignored `.env` file in the repo root:
```
HIVEMQ_USERNAME=your-user
HIVEMQ_PASSWORD=your-password
```
or just let the next step prompt you for them.

**2. Deploy**
```bash
bash scripts/aws-start.sh --test-broker            # no HiveMQ account needed; recommended first run
# or, with real HiveMQ credentials:
bash scripts/aws-start.sh
```
This one command builds everything and puts it on AWS. It takes roughly 5-15 minutes; step back and let it run. Optional flags (combine as needed): `-y` skip the confirmation prompt · `--test-broker` run a throwaway broker inside AWS instead of connecting to the real HiveMQ cluster (test only, see the warning above) · `--alb` add a load balancer in front of Emergency (small extra fixed cost; gives you a stable web address instead of one that can change — see step 3) · `--no-spot` use full-price compute instead of the cheaper "Spot" capacity.

What it actually does, in order:
1. Shows you the account, region, mode and resources it's about to create, and asks you to confirm.
2. Detects your current public IP address so that **only your computer** can reach the system — it's deliberately never opened to the whole internet, since one request here can generate 100,000 messages.
3. Builds the four container images and uploads them to AWS (ECR).
4. Uses Terraform to create everything else: a private network (VPC), the ECS cluster that runs the containers, the Priority auto-scaling rules, and (with `--test-broker`) the temporary broker.
5. Waits until everything is confirmed running, then prints the web address to use next.

**3. Find the web address**
```bash
bash scripts/aws-url.sh
```
This asks AWS directly, right now, for the current address — it never guesses or caches anything. It prints:
- **With `--alb`:** a load balancer address that stays the same for as long as the deployment exists.
- **Without `--alb` (the default):** the running task's public IP, e.g. `http://3.27.230.85:3001`.

**Will this address change?** Only if the underlying task is replaced — not on a timer, not just because time passes:

| Situation | Does the address change? |
|---|---|
| Everything just keeps running while you fire events / read logs | No |
| The task gets replaced — a new deploy, a "Spot" interruption, a crash AWS restarts, an update to the setup | **Yes**, the replacement gets a new address |

So: **don't write this address down and reuse it later** — re-run `bash scripts/aws-url.sh` right before you need it. If a request that used to work suddenly stops connecting, that's the most likely reason; just fetch the address again.

**4. Fire an event and watch it**
```bash
EMERGENCY_URL=$(bash scripts/aws-url.sh) node scripts/fire-event.js 90 90 90
bash scripts/aws-logs.sh rescue          # look for "FLOOD EVENT RESULT"
bash scripts/aws-status.sh               # how many workers are running right now, and why
```
On Windows PowerShell instead of Git Bash: `$env:EMERGENCY_URL = bash scripts/aws-url.sh; node scripts/fire-event.js 90 90 90`.

> **Windows note:** if a command like `aws logs tail` fails with a `'charmap' codec can't encode character` error, that's just a display-encoding quirk, not a real problem. Run this first in the same terminal: `export PYTHONIOENCODING=utf-8 PYTHONUTF8=1` (you'll need to repeat this each time you open a new terminal).

**5. How the autoscaling works**
- Emergency Service reports how many requests it just generated to AWS CloudWatch (a monitoring service), under the name `IncomingRequests`.
- An alarm checks that number every 10 seconds and adds Priority workers in steps: 5,000+ adds 1 worker, 20,000+ adds 2, 60,000+ adds 4, 150,000+ adds 6 (capped at 4 workers total by default).
- If things go quiet for 10 minutes, it removes one worker every 5 minutes until back down to the minimum.
- Tuning knobs live in [infra/terraform/autoscaling.tf](infra/terraform/autoscaling.tf) and [infra/terraform/variables.tf](infra/terraform/variables.tf). For example, to always keep 4 Priority workers ready: `export TF_VAR_priority_min_capacity=4` before running `aws-start.sh`.
- **Expect a delay, confirmed by an actual test, not just a theory:** in one real run, a 300,000-message event scaled Priority up to its 4-worker maximum, but the one worker that was *already running before the event started* still ended up handling the majority of the messages (201,000 out of about 335,000) — new workers simply didn't finish starting up in time to take much of the load. Full numbers: [docs/CLAUDE_INVESTIGATION_LOG.md](docs/CLAUDE_INVESTIGATION_LOG.md) (Session 3).

**6. Tear down when you're done (don't skip this)**
```bash
bash scripts/aws-terminate.sh            # add -y to skip the confirmation prompt
```
This deletes everything that was created and then double-checks nothing was left behind. That check can still list a few things like ECS "task definition" names — those are just permanent historical records AWS keeps forever and don't cost anything, not evidence something is still running. If you want to be extra sure, run: `aws ecs describe-clusters --clusters sdr --region ap-southeast-2` — it should say `status: INACTIVE`.

## Things worth knowing when you experiment

- **More Priority workers is not automatically faster.** In one local test, a 300k event took about 10-12 seconds with 1 worker and about 23-28 seconds with 4 — the local broker became the bottleneck, so extra workers just added overhead. A production-grade broker may behave differently.
- **The system doesn't guarantee delivery (MQTT "QoS 0").** If a message gets lost (a worker stopped mid-event, a slow consumer), the event never reports `FLOOD EVENT RESULT`, because the "requests completed" count never reaches the total.
- **Rescue Service keeps everything in memory.** Restarting it forgets any events that were in progress.
- **Emergency Service pauses while publishing.** A 100,000-message zone occupies it for about half a second before it can respond to anything else.

Full explanation and numbers: [docs/CLAUDE_PROJECT_CONTEXT.md](docs/CLAUDE_PROJECT_CONTEXT.md).

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Cannot connect to the Docker daemon` | Docker Desktop isn't open. Start it (from your Start menu / Applications) and wait for the whale icon to stop animating, then retry. |
| `port is already allocated` for 3001 | Something else on your computer is using port 3001. Close it, or edit the port number in `docker-compose.yml` (`"3001:3001"`). |
| `bash: command not found` or odd path errors on Windows | You're not in **Git Bash**. Open the "Git Bash" app specifically, not PowerShell or Command Prompt. |
| `fire-event.js`: `fetch failed` / `request failed` | The stack isn't up yet, or the URL is wrong. Run `docker compose ps` (local) to check, then retry. |
| No `FLOOD EVENT RESULT` appears | Give it longer for big events (up to a minute). If it still never appears, some messages were lost — just re-run the event. Check `docker compose logs rescue` for clues. |
| Old events also show in the log | `docker compose logs` shows history by default. Use the last "Execution Time" line, or add `--since 2m`. |
| `certgen` shows `Exited` | Normal — it's a one-time setup step, not a service that stays running. |
| Changed a Dockerfile but nothing's different | Rebuild it: `docker compose up -d --build`. |
| `aws-start.sh`: `terraform not found` / `aws not found` | Install the missing tool — see [Prerequisites](#prerequisites) above. |
| `AccessDenied` during deploy | Your AWS user doesn't have enough permissions. See the AWS account note in [Prerequisites](#prerequisites). |
| Web request to AWS times out or is refused | Your public IP address changed since you deployed (only your original IP is allowed through). Re-run `aws-start.sh`, or set `ALLOWED_CIDR=x.x.x.x/32` yourself and re-apply. Also re-run `bash scripts/aws-url.sh` — a replaced task gets a new address. |
| AWS logs show `Connection refused: Not authorized` | You deployed without `--test-broker` and the HiveMQ username/password don't match the built-in cluster. Either get valid credentials or redeploy with `--test-broker`. |
| `aws logs tail` (or similar) fails with `'charmap' codec can't encode character` | Just a Windows display quirk, not a real error. Run `export PYTHONIOENCODING=utf-8 PYTHONUTF8=1` in that terminal first (repeat each new terminal). |
| "Where are my EC2 instances?" | There are none, by design — this runs on Fargate ("serverless" containers), which never shows up in the EC2 console. Look in **ECS → Clusters → sdr** instead, and make sure your AWS Console region (top-right) is set to **ap-southeast-2**. |
| Worried about being billed after finishing | Run `bash scripts/aws-terminate.sh` and read what it prints at the end. See the "Tear down" step above about names that harmlessly stick around. |

## Project status and known gaps

- No automated tests, no CI, no login/authentication on the `/emergency` endpoint.
- The interactive sensor isn't wired up to Emergency Service automatically — use `scripts/fire-event.js` instead.
- The MQTT broker's address is hard-coded inside every service's source file.
- The Terraform state file (`infra/terraform/terraform.tfstate`) stays on your own computer, is git-ignored, and contains sensitive values (like the HiveMQ password if you used one). Never share it.
- **The AWS deployment path has been fully run and verified twice** (using `--test-broker`, in `ap-southeast-2`): deployed, fired real events (35,000 and 300,000 requests, both completed correctly), confirmed autoscaling actually triggers and adds workers, and confirmed a clean teardown afterward with nothing left running. Full numbers: [docs/CLAUDE_INVESTIGATION_LOG.md](docs/CLAUDE_INVESTIGATION_LOG.md), Sessions 2-3.
- Not yet tested: a deployment against the real HiveMQ Cloud cluster (needs credentials), and watching a full "scale back down" cycle end to end (needs 10+ minutes of the system sitting idle).
