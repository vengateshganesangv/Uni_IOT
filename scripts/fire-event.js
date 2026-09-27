#!/usr/bin/env node
// Trigger a flood event without the interactive sensor: POSTs one request per zone to
// Emergency_Request_Service /emergency, using the same payload/fields the sensor computes
// (eventId, eventStartTime, totalEventRequests, zoneA/B/C). Zero dependencies (Node 18+).
//
//   node scripts/fire-event.js <A> <B> <C> [--url http://host:3001] [--repeat N] [--every SECONDS] [--parallel]
//   node scripts/fire-event.js 90 90 90                  # max event: 300,000 requests
//   node scripts/fire-event.js 70 60 50 --repeat 5 --every 10
//
// URL defaults to $EMERGENCY_URL or http://localhost:3001

const args = process.argv.slice(2);
const flag = (name, def) => {
    const i = args.indexOf(`--${name}`);
    if (i === -1) return def;
    const v = args[i + 1];
    args.splice(i, 2);
    return v;
};
const parallel = args.includes("--parallel");
if (parallel) args.splice(args.indexOf("--parallel"), 1);

const baseUrl = (flag("url", process.env.EMERGENCY_URL || "http://localhost:3001")).replace(/\/$/, "");
const repeat = Number(flag("repeat", 1));
const every = Number(flag("every", 0));
const [zoneA, zoneB, zoneC] = args.map(Number);

if ([zoneA, zoneB, zoneC].some((v) => Number.isNaN(v))) {
    console.error("usage: node scripts/fire-event.js <A> <B> <C> [--url URL] [--repeat N] [--every SECONDS] [--parallel]");
    process.exit(1);
}

// Same tiers as water_sensor.js / emergency_service.js
function getRequestCount(level) {
    if (level >= 90) return 100000;
    if (level >= 80) return 50000;
    if (level >= 70) return 20000;
    if (level >= 60) return 10000;
    if (level >= 50) return 5000;
    return 0;
}

async function fireOnce(n) {
    const eventStartTime = Date.now();
    const eventId = `EVENT-${eventStartTime}`;
    const totalEventRequests = getRequestCount(zoneA) + getRequestCount(zoneB) + getRequestCount(zoneC);
    const zones = [
        { location: "Zone_A", waterLevel: zoneA, sensorId: "W001" },
        { location: "Zone_B", waterLevel: zoneB, sensorId: "W002" },
        { location: "Zone_C", waterLevel: zoneC, sensorId: "W003" },
    ];

    console.log(`[${n}/${repeat}] ${eventId}  A=${zoneA} B=${zoneB} C=${zoneC}  expected requests=${totalEventRequests}`);

    const post = async (z) => {
        const t0 = Date.now();
        const res = await fetch(`${baseUrl}/emergency`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ ...z, eventId, eventStartTime, totalEventRequests, zoneA, zoneB, zoneC }),
        });
        const body = await res.text();
        console.log(`   ${z.location}: HTTP ${res.status} in ${Date.now() - t0} ms  ${body}`);
    };

    if (parallel) await Promise.all(zones.map(post));
    else for (const z of zones) await post(z);
}

(async () => {
    for (let n = 1; n <= repeat; n++) {
        try {
            await fireOnce(n);
        } catch (err) {
            console.error(`   request failed: ${err.message} (is Emergency Request Service reachable at ${baseUrl}?)`);
            process.exit(1);
        }
        if (n < repeat && every > 0) await new Promise((r) => setTimeout(r, every * 1000));
    }
    console.log("Done. Result prints in the Rescue service log (\"FLOOD EVENT RESULT\").");
})();
