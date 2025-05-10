const { v4: uuidv4 } = require("uuid");
const client = require("../test-client");

describe("Validation Tests", () => {
    describe("Tunnel ID Validation", () => {
        it("should allow tunnel ID with letters, digits, hyphens, and underscores", async () => {
            const validTunnelId = `valid-Tunnel_123-${uuidv4()}`;
            const res = await client.produceMessage(validTunnelId, { test: "data" });
            expect(res.status).toBe(201);
            await client.cleanQueue(validTunnelId); // Explicit cleanup for custom ID
        });

        it("should allow tunnel ID up to 1024 characters long", async () => {
            const longTunnelId = "a".repeat(1024);
            const res = await client.produceMessage(longTunnelId, { test: "data" });
            expect(res.status).toBe(201);
            expect(res.headers["x-message-id"]).toBeDefined();
            await client.cleanQueue(longTunnelId); // Explicit cleanup
        });

        it("should return 400 for tunnel ID longer than 1024 characters", async () => {
            const tooLongTunnelId = "a".repeat(1025);
            const res = await client.produceMessage(tooLongTunnelId, { test: "data" });
            // The protocol states 400 for invalid URL or parameter.
            expect(res.status).toBe(400);
        });

        it("should return 400 for tunnel ID with invalid characters (e.g., space, !)", async () => {
            const invalidIds = ["invalid tunnel id", "invalid!", "invalid/char"];
            for (const invalidId of invalidIds) {
                const res = await client.produceMessage(invalidId, { test: "data" });
                expect(res.status).toBe(400);
            }
        });
    });
});
