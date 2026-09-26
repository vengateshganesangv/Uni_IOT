require("dotenv").config();
const mqtt = require("mqtt");

const client = mqtt.connect(
    "mqtts://1490e7aa531c43e6af66775dcb39171b.s1.eu.hivemq.cloud:8883",
    {
        username: process.env.HIVEMQ_USERNAME,
        password: process.env.HIVEMQ_PASSWORD
    }
);

const rescueQueue = [];
const rescueTeams = [];
const floodEvents = {};

// Create 50 rescue teams, with 10 teams for each emergency type
for (let i = 1; i <= 10; i++) {
    rescueTeams.push(
        { id: `RESCUE-${i}`, type: "CHILD_TRAPPED", available: true },
        { id: `MEDICAL-${i}`, type: "MEDICAL_EMERGENCY", available: true },
        { id: `ASSIST-${i}`, type: "ELDERLY_NEEDS_HELP", available: true },
        { id: `FLOOD-${i}`, type: "HOUSE_FLOODED", available: true },
        { id: `RELIEF-${i}`, type: "FOOD_WATER_REQUEST", available: true }
    );
}

const priorityValue = {
    CRITICAL: 1,
    HIGH: 2,
    MEDIUM: 3,
    LOW: 4
};

client.on("connect", () => {
    console.log("Rescue Service connected to MQTT");
    console.log("50 specialised rescue teams ready");
    console.log("Waiting for prioritized emergency requests...");
});

client.subscribe("disaster/emergency/prioritized");

client.on("message", (topic, message) => {
    const request = JSON.parse(message.toString());

    // Store the details when a new flood event is received
    if (!floodEvents[request.eventId]) {
        floodEvents[request.eventId] = {
            eventStartTime: request.eventStartTime,
            totalEventRequests: request.totalEventRequests,
            zoneA: request.zoneA,
            zoneB: request.zoneB,
            zoneC: request.zoneC,
            received: 0,
            assigned: 0,
            completed: 0,
            resultPrinted: false
        };
    }

    floodEvents[request.eventId].received++;
    rescueQueue.push(request);
    assignTeams();
});

// Find the highest priority request that matches the rescue team
function findHighestPriorityRequest(teamType) {
    let bestIndex = -1;
    let bestPriority = Infinity;

    for (let i = 0; i < rescueQueue.length; i++) {
        const request = rescueQueue[i];

        if (request.emergencyType !== teamType) {
            continue;
        }

        const value = priorityValue[request.priority];

        if (value < bestPriority) {
            bestPriority = value;
            bestIndex = i;
        }
    }

    return bestIndex;
}

// Assign available teams to suitable emergency requests
function assignTeams() {
    for (const team of rescueTeams) {
        if (!team.available) {
            continue;
        }

        const requestIndex = findHighestPriorityRequest(team.type);

        if (requestIndex === -1) {
            continue;
        }

        const request = rescueQueue[requestIndex];
        rescueQueue.splice(requestIndex, 1);

        team.available = false;

        const event = floodEvents[request.eventId];
        event.assigned++;

        team.available = true;
        event.completed++;

        checkEventComplete(request.eventId);
    }
}

// Display the result when all requests for the flood event are completed
function checkEventComplete(eventId) {
    const event = floodEvents[eventId];

    if (
        event.completed === event.totalEventRequests &&
        !event.resultPrinted
    ) {
        event.resultPrinted = true;

        const eventEndTime = Date.now();
        const executionTime =
            (eventEndTime - event.eventStartTime) / 1000;

        console.log("\n========== FLOOD EVENT RESULT ==========");
        console.log("Zone A Water Level:", event.zoneA);
        console.log("Zone B Water Level:", event.zoneB);
        console.log("Zone C Water Level:", event.zoneC);
        console.log("Simulated Requests:", event.totalEventRequests);
        console.log("Requests Completed:", event.completed);
        console.log(
            "Execution Time:",
            executionTime.toFixed(3),
            "seconds"
        );
        console.log("========================================\n");
    }
}