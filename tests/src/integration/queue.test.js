const { v4: uuidv4 } = require("uuid");
const client = require("../test-client");

describe("Queue Management Tests", () => {
    let testTunnelId;

    beforeEach(() => {
        // Generate a unique tunnel ID for each test to ensure isolation
        testTunnelId = `test-${uuidv4()}`;
    });

    afterEach(async () => {
        // Clean up the tunnel created for the test
        if (testTunnelId) {
            await client.cleanQueue(testTunnelId);
        }
    });

    it("should correctly report queue size via GET /t/<tunnel-id>/len", async () => {
        let lenRes = await client.getQueueLength(testTunnelId);
        expect(lenRes.status).toBe(204);
        expect(lenRes.headers["x-queue-size"]).toBe("0");

        await client.produceMessage(testTunnelId, { m: 1 });
        await client.produceMessage(testTunnelId, { m: 2 });
        lenRes = await client.getQueueLength(testTunnelId);
        expect(lenRes.status).toBe(204);
        expect(lenRes.headers["x-queue-size"]).toBe("2");

        // Consume one (auto-ack)
        await client.consumeMessage(testTunnelId);
        lenRes = await client.getQueueLength(testTunnelId);
        expect(lenRes.status).toBe(204);
        expect(lenRes.headers["x-queue-size"]).toBe("1");

        // Produce one, consume with pending
        await client.produceMessage(testTunnelId, { m: 3 }); // Queue: m2(pending from above if not acked), m3
        const consumePendingRes = await client.consumeMessage(testTunnelId, true); // Consumes m2
        const pendingMessageId = consumePendingRes.headers["x-message-id"];
        lenRes = await client.getQueueLength(testTunnelId);
        expect(lenRes.status).toBe(204);
        // Queue size includes pending and unseen. Now has one pending (m2), one unseen (m3).
        expect(lenRes.headers["x-queue-size"]).toBe("2");

        await client.ackMessage(testTunnelId, pendingMessageId); // Ack m2
        lenRes = await client.getQueueLength(testTunnelId);
        expect(lenRes.status).toBe(204);
        expect(lenRes.headers["x-queue-size"]).toBe("1"); // Only m3 left
    });

    it("should clean the queue via DELETE /t/<tunnel-id>/all", async () => {
        await client.produceMessage(testTunnelId, { data: "msg1" });
        await client.produceMessage(testTunnelId, { data: "msg2" });

        let lenRes = await client.getQueueLength(testTunnelId);
        expect(lenRes.headers["x-queue-size"]).toBe("2");

        const cleanRes = await client.cleanQueue(testTunnelId);
        expect(cleanRes.status).toBe(204);
        expect(cleanRes.headers["x-queue-size"]).toBe("0");

        // Verify queue is empty
        lenRes = await client.getQueueLength(testTunnelId);
        expect(lenRes.headers["x-queue-size"]).toBe("0");
        const consumeRes = await client.consumeMessage(testTunnelId);
        expect(consumeRes.status).toBe(204);
    });
});
