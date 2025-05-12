const { v4: uuidv4 } = require("uuid");
const client = require("../test-client");
const apiClient = client.getApiClient();

describe("Basic Integration Tests", () => {
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

    describe("Health Check", () => {
        it("GET /health should return 200 OK with 'OK' body", async () => {
            const response = await apiClient.get("/health");
            expect(response.status).toBe(200);
            expect(response.headers["content-type"]).toContain("text/plain");
            expect(response.data).toBe("OK");
        });
    });

    describe("Basic Operations", () => {
        it("should produce and consume a JSON message", async () => {
            const message = { greeting: "Hello, World!", id: 1 };
            const produceRes = await client.produceMessage(testTunnelId, message, "application/json");
            expect(produceRes.status).toBe(201);
            const messageId = produceRes.headers["x-message-id"];
            expect(messageId).toBeDefined();
            expect(produceRes.headers["x-queue-size"]).toBe("1");

            const consumeRes = await client.consumeMessage(testTunnelId);
            expect(consumeRes.status).toBe(200);
            expect(consumeRes.headers["content-type"]).toContain("application/json");
            expect(consumeRes.headers["x-message-id"]).toBe(messageId);
            expect(consumeRes.data).toEqual(message);
        });

        it("should produce and consume a plain text message", async () => {
            const message = "Hello, text world!";
            // don't add a header, it must fallback to text/plain
            const produceRes = await client.produceMessage(testTunnelId, message, false);
            expect(produceRes.status).toBe(201);
            const messageId = produceRes.headers["x-message-id"];

            const consumeRes = await client.consumeMessage(testTunnelId);
            expect(consumeRes.status).toBe(200);
            expect(consumeRes.headers["content-type"]).toContain("text/plain");
            expect(consumeRes.headers["x-message-id"]).toBe(messageId);
            expect(consumeRes.data).toBe(message);
        });

        it("should return 204 when consuming an empty tunnel", async () => {
            const consumeRes = await client.consumeMessage(testTunnelId);
            expect(consumeRes.status).toBe(204);
            expect(consumeRes.data).toBe("");
        });

        it("should have case-sensitive tunnel ids", async () => {
            const message = "HELLO, WORLD!";
            const produceRes = await client.produceMessage(testTunnelId, message, false);
            expect(produceRes.status).toBe(201);

            const upperConsumeRes = await client.consumeMessage(testTunnelId.toUpperCase());
            expect(upperConsumeRes.status).toBe(204);

            const consumeRes = await client.consumeMessage(testTunnelId);
            expect(consumeRes.status).toBe(200);
        });

        it("should report message status", async () => {
            // Tunnel not created yet
            let statusRes = await client.getMessageStatus(testTunnelId, '0-0');
            expect(statusRes.status).toBe(204); // No Content

            const message = { data: "pending test" };
            const produceRes = await client.produceMessage(testTunnelId, message);
            expect(produceRes.status).toBe(201);
            const messageId = produceRes.headers["x-message-id"];

            // Message created, but not accepted yet
            statusRes = await client.getMessageStatus(testTunnelId, messageId);
            expect(statusRes.status).toBe(201); // Created

            let consumeRes = await client.consumeMessage(testTunnelId, false);
            expect(consumeRes.status).toBe(200);

            // Message accepted and processed
            statusRes = await client.getMessageStatus(testTunnelId, messageId);
            expect(statusRes.status).toBe(204); // No Content
        });
    });

    describe("Long Polling", () => {
        jest.setTimeout(10000); // Increase timeout for long polling tests

        it("should consume existing message via long polling instantly", async () => {
            const message = { poll: "success" };
            await client.produceMessage(testTunnelId, message);

            const pollRes = await client.pollMessage(testTunnelId, 1);
            expect(pollRes.status).toBe(200);
            expect(pollRes.data).toEqual(message);
            expect(pollRes.headers["x-message-id"]).toBeDefined();
        });

        it("should consume message via long polling when message arrives later", async () => {
            const message = { poll: "success" };

            // Start polling, then produce message after a short delay
            const pollPromise = client.pollMessage(testTunnelId, 5); // 5s timeout
            await new Promise(resolve => setTimeout(resolve, 500)); // Wait 0.5s
            await client.produceMessage(testTunnelId, message);

            const pollRes = await pollPromise;
            expect(pollRes.status).toBe(200);
            expect(pollRes.data).toEqual(message);
            expect(pollRes.headers["x-message-id"]).toBeDefined();
        });

        it("should timeout (204) on long polling if no message arrives", async () => {
            const pollRes = await client.pollMessage(testTunnelId, 1); // 1s timeout
            expect(pollRes.status).toBe(204);
        });
    });

    describe("Backpressure", () => {
        it("should enforce backpressure when limit is reached (producer receives 507)", async () => {
            const message = { item: 1 };
            // Set limit to 1
            let produceRes = await client.produceMessage(testTunnelId, message, "application/json", 1);
            expect(produceRes.status).toBe(201);
            expect(produceRes.headers["x-queue-size"]).toBe("1");

            // Try to produce another message, should hit backpressure
            produceRes = await client.produceMessage(testTunnelId, { item: 2 }, "application/json", 1);
            expect(produceRes.status).toBe(507); // Insufficient Storage
            expect(produceRes.headers["x-queue-size"]).toBe("1");

            // Consume the first message
            const consumeRes = await client.consumeMessage(testTunnelId);
            expect(consumeRes.status).toBe(200);

            // Now producing another should succeed
            produceRes = await client.produceMessage(testTunnelId, { item: 3 }, "application/json", 1);
            expect(produceRes.status).toBe(201);
            expect(produceRes.headers["x-queue-size"]).toBe("1");
        });

        it("should not enforce backpressure for producer when limit=0 (producer receives 201)", async () => {
            // With limit=0, producer should not get 507.
            let produceRes = await client.produceMessage(testTunnelId, { item: 1 }, "application/json", 0);
            expect(produceRes.status).toBe(201);

            produceRes = await client.produceMessage(testTunnelId, { item: 2 }, "application/json", 0);
            expect(produceRes.status).toBe(201);

            produceRes = await client.produceMessage(testTunnelId, { item: 3 }, "application/json", 0);
            expect(produceRes.status).toBe(201);
        });
    });
});
