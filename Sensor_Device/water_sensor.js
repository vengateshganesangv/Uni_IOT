require("dotenv").config();
const mqtt = require("mqtt");
const readline = require("readline");

const client = mqtt.connect(
    "mqtts://1490e7aa531c43e6af66775dcb39171b.s1.eu.hivemq.cloud:8883",
    {
        username: process.env.HIVEMQ_USERNAME,
        password: process.env.HIVEMQ_PASSWORD
    }
);

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

client.on("connect", () => {
    console.log("Connected to MQTT broker");
    console.log("Smart Disaster Relief - Water Sensor Simulation");
    console.log("-----------------------------------------------");

    askForWaterLevels();
});

function askQuestion(question) {
    return new Promise((resolve) => {
        rl.question(question, (answer) => {
            resolve(Number(answer));
        });
    });
}

// Calculate simulated requests for a water level
function getRequestCount(waterLevel) {

    if (waterLevel >= 90) return 100000;
    if (waterLevel >= 80) return 50000;
    if (waterLevel >= 70) return 20000;
    if (waterLevel >= 60) return 10000;
    if (waterLevel >= 50) return 5000;

    return 0;
}

async function askForWaterLevels() {

    const zoneA = await askQuestion(
        "Enter Zone A water level (0-100): "
    );

    const zoneB = await askQuestion(
        "Enter Zone B water level (0-100): "
    );

    const zoneC = await askQuestion(
        "Enter Zone C water level (0-100): "
    );

    // One complete A + B + C input = one flood event
    const eventId = `EVENT-${Date.now()}`;
    const eventStartTime = Date.now();

    // Calculate total requests for the whole flood event
    const totalEventRequests =
        getRequestCount(zoneA) +
        getRequestCount(zoneB) +
        getRequestCount(zoneC);

    // One simulated sensor for each zone
    const zones = [
        {
            name: "Zone_A",
            waterLevel: zoneA,
            sensorId: "W001"
        },
        {
            name: "Zone_B",
            waterLevel: zoneB,
            sensorId: "W002"
        },
        {
            name: "Zone_C",
            waterLevel: zoneC,
            sensorId: "W003"
        }
    ];

    zones.forEach((zone) => {

        let status;

        if (zone.waterLevel >= 70) {
            status = "CRITICAL";
        } else if (zone.waterLevel >= 50) {
            status = "WARNING";
        } else {
            status = "NORMAL";
        }

        const sensorData = {
            sensorId: zone.sensorId,
            type: "water_level",
            value: zone.waterLevel,
            location: zone.name,
            status: status,

            // Information for this complete flood event
            eventId: eventId,
            eventStartTime: eventStartTime,
            totalEventRequests: totalEventRequests,

            // Keep all three entered values with the event
            zoneA: zoneA,
            zoneB: zoneB,
            zoneC: zoneC,

            timestamp: new Date().toISOString()
        };

        const topic = `disaster/water/${zone.name}`;

        client.publish(
            topic,
            JSON.stringify(sensorData),
            () => {
                console.log(
                    `${zone.name}: ${zone.waterLevel}% published`
                );
            }
        );
    });

    console.log(
        `Total simulated requests for this event: ${totalEventRequests}`
    );

    console.log("\nEnter new values:\n");

    askForWaterLevels();
}