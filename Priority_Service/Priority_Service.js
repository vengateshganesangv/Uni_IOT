require("dotenv").config();
const mqtt = require("mqtt");

const client = mqtt.connect(
    "mqtts://1490e7aa531c43e6af66775dcb39171b.s1.eu.hivemq.cloud:8883",
    {
        username: process.env.HIVEMQ_USERNAME,
        password: process.env.HIVEMQ_PASSWORD
    }
);

let counts = {
    CRITICAL: 0,
    HIGH: 0,
    MEDIUM: 0,
    LOW: 0
};

let totalProcessed = 0;

function getPriority(emergencyType) {

    if (emergencyType === "CHILD_TRAPPED")
        return "CRITICAL";

    if (
        emergencyType === "MEDICAL_EMERGENCY" ||
        emergencyType === "ELDERLY_NEEDS_HELP"
    )
        return "HIGH";

    if (emergencyType === "HOUSE_FLOODED")
        return "MEDIUM";

    return "LOW";
}

client.on("connect", () => {

    console.log("Priority Service connected to MQTT");

    client.subscribe("$share/priority-workers/disaster/emergency/requests", () => {
        console.log("Waiting for emergency requests...");
    });
});

client.on("message", (topic, message) => {

    const request = JSON.parse(message.toString());

    const priority = getPriority(request.emergencyType);

    const prioritizedRequest = {
        ...request,
        priority: priority
    };

    counts[priority]++;
    totalProcessed++;

    // Send every request to Rescue Service
    client.publish(
        "disaster/emergency/prioritized",
        JSON.stringify(prioritizedRequest)
    );

    // Print summary every 1000 requests
    if (totalProcessed % 1000 === 0) {

        console.log("\n--- Priority Summary ---");
        console.log("Total Processed:", totalProcessed);
        console.log("CRITICAL:", counts.CRITICAL);
        console.log("HIGH:", counts.HIGH);
        console.log("MEDIUM:", counts.MEDIUM);
        console.log("LOW:", counts.LOW);
    }
});