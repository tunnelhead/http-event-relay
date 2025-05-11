const crypto = require("crypto");
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

    describe("Access Token", () => {
        it("should FAIL to produce message if token NOT provided", async () => {
            const res = await apiClient.post(
                `/t/${testTunnelId}`,
                { data: "auth test" },
                { headers: { "Content-Type": "application/json" } }, // No Auth header
            );
            expect(res.status).toBe(403);
        });

        it("should FAIL to produce message if INCORRECT token provided", async () => {
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

        it("should SUCCEED to produce message if CORRECT token provided", async () => {
            const res = await client.produceMessage(testTunnelId, { data: "auth success" });
            expect(res.status).toBe(201);
        });

        it("should SUCCEED to consume message in DEMO tunnel if token is NOT provided", async () => {
            const res = await apiClient.get(`/t/${client.DEMO_TUNNEL_ID}`, { headers: {} });
            expect([200, 204]).toContain(res.status);
        });

        it("should FAIL to consume message if token is NOT provided", async () => {
            const res = await apiClient.get(`/t/${testTunnelId}`, { headers: {} });
            expect(res.status).toBe(403);
        });

        it("should FAIL to acknowledge message if token is NOT provided", async () => {
            const pres = await client.produceMessage(testTunnelId, { data: "produce for auth ack" });
            const mid = pres.headers["x-message-id"];
            await client.consumeMessage(testTunnelId, true); // Consume to make it pending (with token)

            const res = await apiClient.delete(`/t/${testTunnelId}/${mid}`, { headers: {} });
            expect(res.status).toBe(403);
        });
    });

    describe("HMAC Signature", () => {
        async function createSignature(secret, payload) {
            const encoder = new TextEncoder();

            const algorithm = { name: "HMAC", hash: { name: 'SHA-256' } };
            const keyBytes = encoder.encode(secret);
            const key = await crypto.subtle.importKey(
                "raw",
                keyBytes,
                algorithm,
                false,
                [ "sign", "verify" ],
            );

            const dataBytes = encoder.encode(payload);
            const sigBytes = await crypto.subtle.sign(algorithm, key, dataBytes);
            return Buffer.from(sigBytes).toString("hex");
        }

        it("should SUCCEED to produce message if CORRECT signature provided", async () => {
            const payload = "Hello, World!";
            const signature = await createSignature(client.SIGNATURE_SECRET, payload);
            const res = await apiClient.post(
                `/t/${testTunnelId}`,
                payload,
                {
                    headers: {
                        "Content-Type": "text/plain",
                        "X-Hub-Signature-256": "sha256=" + signature,
                    },
                },
            );
            expect(res.status).toBe(201);
        });

        it("should FAIL to produce message if INCORRECT signature provided", async () => {
            const payload = "Hello, World!";
            const signature = await createSignature("wrong secret", payload);
            const res = await apiClient.post(
                `/t/${testTunnelId}`,
                payload,
                {
                    headers: {
                        "Content-Type": "text/plain",
                        "X-Hub-Signature-256": "sha256=" + signature,
                    },
                },
            );
            expect(res.status).toBe(403);
        });
    });
});
