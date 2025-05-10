const { v4: uuidv4 } = require("uuid");
const client = require("../test-client");
const apiClient = client.getApiClient();

describe("Authorization Tests", () => {
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

    it("should FAIL to produce message if token is required and NOT provided", async () => {
        const res = await apiClient.post(
            `/t/${testTunnelId}`,
            { data: "auth test" },
            { headers: { "Content-Type": "application/json" } }, // No Auth header
        );
        expect(res.status).toBe(403);
    });

    it("should FAIL to produce message if token is required and INCORRECT token provided", async () => {
        const res = await apiClient.post(
            `/t/${testTunnelId}`,
            { data: "auth test" },
            {
                headers: {
                    "Content-Type": "application/json",
                    Authorization: "Bearer incorrectbearertoken",
                },
            },
        );
        expect(res.status).toBe(403);
    });

    it("should SUCCEED to produce message if token is required and CORRECT token provided", async () => {
        const res = await client.produceMessage(testTunnelId, { data: "auth success" });
        expect(res.status).toBe(201);
    });

    it("should SUCCEED to consume message in DEMO tunnel if token is required and NOT provided", async () => {
        const res = await apiClient.get(`/t/${client.DEMO_TUNNEL_ID}`, { headers: {} });
        expect([200, 204]).toContain(res.status);
    });

    it("should FAIL to consume message if token is required and NOT provided", async () => {
        const res = await apiClient.get(`/t/${testTunnelId}`, { headers: {} });
        expect(res.status).toBe(403);
    });

    it("should FAIL to acknowledge message if token is required and NOT provided", async () => {
        const pres = await client.produceMessage(testTunnelId, { data: "produce for auth ack" });
        const mid = pres.headers["x-message-id"];
        await client.consumeMessage(testTunnelId, true); // Consume to make it pending (with token)

        const res = await apiClient.delete(`/t/${testTunnelId}/${mid}`, { headers: {} });
        expect(res.status).toBe(403);
    });
});
