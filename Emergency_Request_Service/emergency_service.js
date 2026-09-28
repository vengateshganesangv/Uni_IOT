require("dotenv").config();

const express = require("express");
const mqtt = require("mqtt");
const {
    CloudWatchClient,
    PutMetricDataCommand
} = require("@aws-sdk/client-cloudwatch");

const app = express();
app.use(express.json());

const PORT = 3001;

const cloudwatch = new CloudWatchClient({
    region: "ap-southeast-2"
});

// Connect to the MQTT broker configured for this environment
const client = mqtt.connect(
    process.env.MQTT_URL || "mqtts://localhost:8883"
);

client.on("connect", () => {
    console.log("Emergency Request Service connected to MQTT");
});

function getRequestCount(waterLevel) {
    if (waterLevel >= 90) return 100000;
    if (waterLevel >= 80) return 50000;
    if (waterLevel >= 70) return 20000;
    if (waterLevel >= 60) return 10000;
    if (waterLevel >= 50) return 5000;

    return 0;
}

// Send the number of incoming requests to CloudWatch
async function sendWorkloadMetric(requestCount) {
    const command = new PutMetricDataCommand({
        Namespace: "SmartDisasterRelief",
        MetricData: [
            {
                MetricName: "IncomingRequests",
                Value: requestCount,
                Unit: "Count",
                StorageResolution: 1
            }
        ]
    });

    try {
        await cloudwatch.send(command);
        console.log(
            "CloudWatch workload metric sent:",
            requestCount
        );
    } catch (error) {
        console.log(
            "Could not send CloudWatch metric:",
            error.message
        );
    }
}

const emergencyTypes = [
    "CHILD_TRAPPED",
    "MEDICAL_EMERGENCY",
    "ELDERLY_NEEDS_HELP",
    "HOUSE_FLOODED",
    "FOOD_WATER_REQUEST"
];

app.post("/emergency", (req, res) => {
    const event = req.body;

    const location = event.location;
    const waterLevel = Number(event.waterLevel);
    const sensorId = event.sensorId;

    // Information for the complete A + B + C flood event
    const eventId = event.eventId;
    const eventStartTime = event.eventStartTime;
    const totalEventRequests = Number(event.totalEventRequests);

    const zoneA = event.zoneA;
    const zoneB = event.zoneB;
    const zoneC = event.zoneC;

    // Requests generated only for this particular zone
    const requestCount = getRequestCount(waterLevel);

    // Send the incoming workload to CloudWatch
    sendWorkloadMetric(requestCount);

    const batchId = Date.now();

    for (let i = 1; i <= requestCount; i++) {
        const emergencyType =
            emergencyTypes[
                Math.floor(
                    Math.random() * emergencyTypes.length
                )
            ];

        const emergencyRequest = {
            requestId: `REQ-${batchId}-${i}`,

            location: location,
            waterLevel: waterLevel,
            sensorId: sensorId,

            emergencyType: emergencyType,
            status: "PENDING",

            // Same event information is carried by every request
            eventId: eventId,
            eventStartTime: eventStartTime,
            totalEventRequests: totalEventRequests,

            // Original A + B + C values
            zoneA: zoneA,
            zoneB: zoneB,
            zoneC: zoneC,

            timestamp: new Date().toISOString()
        };

        client.publish(
            "disaster/emergency/requests",
            JSON.stringify(emergencyRequest)
        );
    }

    console.log("\n-------------------------------");
    console.log("FLOOD EMERGENCY DETECTED");
    console.log("Location:", location);
    console.log("Water Level:", waterLevel);
    console.log("Requests Generated:", requestCount);
    console.log("-------------------------------");

    res.status(201).json({
        location: location,
        waterLevel: waterLevel,
        requestsGenerated: requestCount
    });
});

app.listen(PORT, () => {
    console.log(
        `Emergency Request Service running on port ${PORT}`
    );
});