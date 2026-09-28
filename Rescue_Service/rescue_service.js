require("dotenv").config();
const mqtt = require("mqtt");
const { createClient } = require("redis");

// Connect to the MQTT broker configured for this environment
const mqttClient = mqtt.connect(
    process.env.MQTT_URL || "mqtts://localhost:8883"
);

const redisClient = createClient({
    url: process.env.REDIS_URL || "redis://localhost:6379"
});

const teamTypes = [
    "CHILD_TRAPPED",
    "MEDICAL_EMERGENCY",
    "ELDERLY_NEEDS_HELP",
    "HOUSE_FLOODED",
    "FOOD_WATER_REQUEST"
];

const teamPrefixes = {
    CHILD_TRAPPED: "RESCUE",
    MEDICAL_EMERGENCY: "MEDICAL",
    ELDERLY_NEEDS_HELP: "ASSIST",
    HOUSE_FLOODED: "FLOOD",
    FOOD_WATER_REQUEST: "RELIEF"
};

redisClient.on("error", (error) => {
    console.error("Redis error:", error.message);
});

// Create the 50 rescue teams once in the shared Redis store
async function initialiseRescueTeams() {
    const created = await redisClient.set(
        "rescue:teams:initialized",
        "true",
        { NX: true }
    );

    if (created) {
        for (const type of teamTypes) {
            const teams = [];

            for (let i = 1; i <= 10; i++) {
                teams.push(`${teamPrefixes[type]}-${i}`);
            }

            await redisClient.rPush(`rescue:teams:${type}`, teams);
        }

        console.log("50 shared specialised rescue teams created");
    } else {
        console.log("Using existing 50 shared rescue teams");
    }
}

// Store flood event information once so every Rescue worker can access it.
//
// Performance note (Session 5): originally 6 sequential hSetNX round trips PER MESSAGE (not just the
// first). Under a real burst this dominates per-request latency: with only 50 teams total and each
// request now taking several real Redis round trips (vs. the original always-instant in-memory
// version), throughput became low enough that many requests exceeded getAvailableTeam's wait budget
// under a 35k-message event, surfacing as "No <type> team became available" errors - not data loss or
// incorrect results, just a real throughput ceiling. This cuts it to 2 round trips, sent concurrently
// (not awaited one after another), so node-redis pipelines them onto the wire together:
//   - the 5 static fields (identical on every message for a given event) are safely overwritten
//     unconditionally - same value every time, so redundant writes are harmless;
//   - "completed" is the one mutable field and MUST stay hSetNX (never reset by a later message).
async function initialiseFloodEvent(request) {
    const eventKey = `flood:event:${request.eventId}`;

    await Promise.all([
        redisClient.hSet(eventKey, {
            eventStartTime: String(request.eventStartTime),
            totalEventRequests: String(request.totalEventRequests),
            zoneA: String(request.zoneA),
            zoneB: String(request.zoneB),
            zoneC: String(request.zoneC)
        }),
        redisClient.hSetNX(eventKey, "completed", "0")
    ]);

    return eventKey;
}

// Get one team from the shared pool.
//
// Uses a non-blocking LPOP + short retry instead of BLPOP: a blocking Redis command occupies
// its connection until it resolves, and this function is called concurrently, by every worker,
// for every emergency type, on a single shared connection. With BLPOP, a wait for one type
// (e.g. CHILD_TRAPPED, only 10 teams) would queue up every other pending command on that same
// connection behind it - including checkouts for completely different, immediately-available
// team types - stalling the whole service under real concurrent load. LPOP never blocks the
// connection, so unrelated checkouts are unaffected regardless of how long any one type waits.
// maxWaitMs bounds how long a request waits if a team is never released (e.g. a worker crashed
// mid-request without releasing its team) - it fails with a clear error instead of hanging forever;
// the caller (the MQTT message handler) already logs and moves on.
async function getAvailableTeam(emergencyType, { retryDelayMs = 25, maxWaitMs = 30000 } = {}) {
    const deadline = Date.now() + maxWaitMs;

    for (;;) {
        const teamId = await redisClient.lPop(`rescue:teams:${emergencyType}`);

        if (teamId) {
            return teamId;
        }

        if (Date.now() >= deadline) {
            throw new Error(
                `No ${emergencyType} team became available within ${maxWaitMs}ms`
            );
        }

        await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
    }
}

// Return the team to the same shared pool after completing the request
async function releaseTeam(emergencyType, teamId) {
    await redisClient.rPush(
        `rescue:teams:${emergencyType}`,
        teamId
    );
}

// Display the final result only once across all Rescue workers.
//
// Performance note (Session 5): previously called hGetAll (fetches the whole event hash) on every
// single message just to read totalEventRequests for this comparison - one more avoidable round trip
// on the hot path, for every message, not just the last one. totalEventRequests is already on the
// incoming MQTT message itself (request.totalEventRequests), so no Redis read is needed for the check
// at all; hGetAll now only runs once, for the final summary, after completion is confirmed.
async function checkEventComplete(eventKey, request, completed) {
    const totalRequests = Number(request.totalEventRequests);

    if (completed !== totalRequests) {
        return;
    }

    const resultLock = await redisClient.set(
        `flood:result:${request.eventId}`,
        "printed",
        { NX: true }
    );

    if (!resultLock) {
        return;
    }

    const event = await redisClient.hGetAll(eventKey);
    const eventEndTime = Date.now();
    const executionTime =
        (eventEndTime - Number(event.eventStartTime)) / 1000;

    console.log("\n========== FLOOD EVENT RESULT ==========");
    console.log("Zone A Water Level:", event.zoneA);
    console.log("Zone B Water Level:", event.zoneB);
    console.log("Zone C Water Level:", event.zoneC);
    console.log("Simulated Requests:", totalRequests);
    console.log("Requests Completed:", completed);
    console.log(
        "Execution Time:",
        executionTime.toFixed(3),
        "seconds"
    );
    console.log("========================================\n");
}

// Process one request using one of the same 50 shared rescue teams
async function processRequest(request) {
    const eventKey = await initialiseFloodEvent(request);

    const teamId = await getAvailableTeam(
        request.emergencyType
    );

    try {
        const completed = await redisClient.hIncrBy(
            eventKey,
            "completed",
            1
        );

        await checkEventComplete(
            eventKey,
            request,
            completed
        );
    } finally {
        await releaseTeam(
            request.emergencyType,
            teamId
        );
    }
}


// ONLY FIX:
// Attach MQTT connect listener immediately so AWS cannot miss the connect event
mqttClient.on("connect", () => {
    console.log("Rescue Service connected to MQTT");
    console.log("50 shared specialised rescue teams ready");
    console.log("Waiting for prioritized emergency requests...");

    // Shared subscription distributes requests between Rescue workers
    mqttClient.subscribe(
        "$share/rescue-workers/disaster/emergency/prioritized"
    );
});


// Local backpressure valve (Session 5): only 50 teams exist, and each held team now costs a handful
// of real Redis round trips (vs. the original's zero-cost in-memory instant assignment). Without a
// cap, a burst of thousands of MQTT messages starts that many concurrent processRequest() calls at
// once; almost all of them find every team pool empty and poll again every 25ms - with a large
// backlog, that flood of mostly-empty polls competes with the small number of calls that are actually
// making progress, so the backlog grows faster than it drains and requests start missing their
// getAvailableTeam wait budget. Capping concurrent in-flight requests keeps the rest queued cheaply in
// process memory (no Redis calls at all while waiting for a slot) instead of hammering Redis.
const MAX_CONCURRENT_REQUESTS = 200;
let activeRequestCount = 0;
const requestSlotQueue = [];

function acquireRequestSlot() {
    if (activeRequestCount < MAX_CONCURRENT_REQUESTS) {
        activeRequestCount++;
        return Promise.resolve();
    }
    return new Promise((resolve) => requestSlotQueue.push(resolve));
}

function releaseRequestSlot() {
    const next = requestSlotQueue.shift();
    if (next) {
        next(); // hand the slot straight to the next waiter; activeRequestCount is unchanged
    } else {
        activeRequestCount--;
    }
}

mqttClient.on("message", async (topic, message) => {
    await acquireRequestSlot();
    try {
        const request = JSON.parse(message.toString());
        await processRequest(request);
    } catch (error) {
        console.error(
            "Error processing rescue request:",
            error && error.stack ? error.stack : error
        );
    } finally {
        releaseRequestSlot();
    }
});


async function startService() {
    await redisClient.connect();

    console.log("Rescue Service connected to Redis");

    await initialiseRescueTeams();
}

startService().catch((error) => {
    console.error("Failed to start Rescue Service:", error);
    process.exit(1);
});