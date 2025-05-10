const { v4: uuidv4 } = require("uuid");
const client = require("../test-client");

describe("Pending Mode Tests", () => {
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

    describe("Acknowledgement", () => {
        it("should handle messages in pending mode and allow acknowledgement", async () => {
            const message = { data: "pending test" };
            const produceRes = await client.produceMessage(testTunnelId, message);
            expect(produceRes.status).toBe(201);
            const messageId = produceRes.headers["x-message-id"];

            // 1. Consume in pending mode
            let consumeRes = await client.consumeMessage(testTunnelId, true);
            expect(consumeRes.status).toBe(200);
            expect(consumeRes.data).toEqual(message);
            expect(consumeRes.headers["x-message-id"]).toBe(messageId);

            // 2. Consume again in pending mode, should get the same message
            consumeRes = await client.consumeMessage(testTunnelId, true);
            expect(consumeRes.status).toBe(200);
            expect(consumeRes.data).toEqual(message);
            expect(consumeRes.headers["x-message-id"]).toBe(messageId);

            // 3. Acknowledge the message
            const ackRes = await client.ackMessage(testTunnelId, messageId);
            expect(ackRes.status).toBe(204);

            // 4. Consume again (pending or not), should be no message
            consumeRes = await client.consumeMessage(testTunnelId, true);
            expect(consumeRes.status).toBe(204);

            consumeRes = await client.consumeMessage(testTunnelId, false);
            expect(consumeRes.status).toBe(204);
        });

        it("should handle pending mode with long polling", async () => {
            const message = { pollPending: "data" };
            await client.produceMessage(testTunnelId, message);

            // Poll in pending mode
            let pollRes = await client.pollMessage(testTunnelId, 5, true);
            expect(pollRes.status).toBe(200);
            const messageId = pollRes.headers["x-message-id"];
            expect(pollRes.data).toEqual(message);

            // Poll again in pending mode, should get same message
            pollRes = await client.pollMessage(testTunnelId, 1, true);
            expect(pollRes.status).toBe(200);
            expect(pollRes.headers["x-message-id"]).toBe(messageId);

            // Acknowledge
            await client.ackMessage(testTunnelId, messageId);

            // Poll again, should be empty (timeout)
            pollRes = await client.pollMessage(testTunnelId, 1, true);
            expect(pollRes.status).toBe(204);
        });

        it("should report message status in pending mode", async () => {
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

            let consumeRes = await client.consumeMessage(testTunnelId, true);
            expect(consumeRes.status).toBe(200);

            // Message accepted, but not processed yet
            statusRes = await client.getMessageStatus(testTunnelId, messageId);
            expect(statusRes.status).toBe(202); // Accepted

            const ackRes = await client.ackMessage(testTunnelId, messageId);
            expect(ackRes.status).toBe(204);

            // Message accepted and processed
            statusRes = await client.getMessageStatus(testTunnelId, messageId);
            expect(statusRes.status).toBe(204); // No Content
        });

        it("should return 204 when acknowledging a non-existent or already acknowledged message", async () => {
            const nonExistentMessageId = `999-123`;
            const ackRes = await client.ackMessage(testTunnelId, nonExistentMessageId);
            // Deleting a non-existent resource is often idempotent, resulting in 204.
            expect(ackRes.status).toBe(204);
        });
    });

    describe("Message replies", () => {
        it("should fallback to default content type for reply", async () => {
            const message = { data: "pending test" };
            const produceRes = await client.produceMessage(testTunnelId, message);
            expect(produceRes.status).toBe(201);
            const messageId = produceRes.headers["x-message-id"];

            // Consume in pending mode
            let consumeRes = await client.consumeMessage(testTunnelId, true);
            expect(consumeRes.status).toBe(200);
            expect(consumeRes.headers["x-message-id"]).toBe(messageId);

            const replyText = "This is a reply";
            let replyRes = await client.sendMessageReply(testTunnelId, messageId, replyText, false);
            expect(replyRes.status).toBe(201);

            const readReplyRes = await client.getMessageReply(testTunnelId, messageId);
            expect(readReplyRes.status).toBe(200);
            expect(readReplyRes.headers["content-type"]).toContain("text/plain");
            expect(readReplyRes.data).toBe(replyText);
        });

        it("should be able to reply to a pending message", async () => {
            const message = { data: "pending test" };
            const produceRes = await client.produceMessage(testTunnelId, message);
            expect(produceRes.status).toBe(201);
            const messageId = produceRes.headers["x-message-id"];

            // Try sending reply before message was consumed
            const replyBody = { data: "reply test" };
            let replyRes = await client.sendMessageReply(testTunnelId, messageId, replyBody);
            expect(replyRes.status).toBe(204);

            // Consume in pending mode
            let consumeRes = await client.consumeMessage(testTunnelId, true);
            expect(consumeRes.status).toBe(200);
            expect(consumeRes.headers["x-message-id"]).toBe(messageId);

            // Read reply before it was sent
            let readReplyRes = await client.getMessageReply(testTunnelId, messageId);
            expect(readReplyRes.status).toBe(204);

            // Send reply
            replyRes = await client.sendMessageReply(testTunnelId, messageId, replyBody);
            expect(replyRes.status).toBe(201);

            // Try send again (will not find message as it was auto acked)
            replyRes = await client.sendMessageReply(testTunnelId, messageId, replyBody);
            expect(replyRes.status).toBe(204);

            // Read reply
            readReplyRes = await client.getMessageReply(testTunnelId, messageId);
            expect(readReplyRes.status).toBe(200);
            expect(readReplyRes.headers["content-type"]).toContain("application/json");
            expect(readReplyRes.data).toEqual(replyBody);

            // Read reply again
            readReplyRes = await client.getMessageReply(testTunnelId, messageId);
            expect(readReplyRes.status).toBe(204);
        });

        it("should be able to get reply via long polling", async () => {
            jest.setTimeout(10000);

            const message = { data: "pending test" };
            const produceRes = await client.produceMessage(testTunnelId, message);
            expect(produceRes.status).toBe(201);
            const messageId = produceRes.headers["x-message-id"];

            // Consume in pending mode
            let consumeRes = await client.consumeMessage(testTunnelId, true);
            expect(consumeRes.status).toBe(200);
            expect(consumeRes.data).toEqual(message);
            expect(consumeRes.headers["x-message-id"]).toBe(messageId);

            // Poll reply before it was sent
            let pollReplyRes = await client.pollMessageReply(testTunnelId, messageId, 1);
            expect(pollReplyRes.status).toBe(204);

            // Send reply
            const replyBody = { data: "reply test" };
            let replyRes = await client.sendMessageReply(testTunnelId, messageId, replyBody);
            expect(replyRes.status).toBe(201);

            // Poll existing reply
            pollReplyRes = await client.pollMessageReply(testTunnelId, messageId, 1);
            expect(pollReplyRes.status).toBe(200);
            expect(pollReplyRes.headers["content-type"]).toContain("application/json");
            expect(pollReplyRes.data).toEqual(replyBody);

            // Poll reply after it was already read
            pollReplyRes = await client.pollMessageReply(testTunnelId, messageId, 1);
            expect(pollReplyRes.status).toBe(204);
        });

        it("should be able to poll reply which wasn't yet send", async () => {
            jest.setTimeout(10000);

            const message = { data: "pending test" };
            const produceRes = await client.produceMessage(testTunnelId, message);
            expect(produceRes.status).toBe(201);
            const messageId = produceRes.headers["x-message-id"];

            // Consume in pending mode
            let consumeRes = await client.consumeMessage(testTunnelId, true);
            expect(consumeRes.status).toBe(200);

            // Poll reply and send it shortly after
            let pollReplyPromise = client.pollMessageReply(testTunnelId, messageId, 5);

            await new Promise(resolve => setTimeout(resolve, 500));
            const replyBody = { data: "reply test" };
            let replyRes = await client.sendMessageReply(testTunnelId, messageId, replyBody);
            expect(replyRes.status).toBe(201);

            let pollReplyRes = await pollReplyPromise;
            expect(pollReplyRes.status).toBe(200);
            expect(pollReplyRes.headers["content-type"]).toContain("application/json");
            expect(pollReplyRes.data).toEqual(replyBody);
        });

        it("should not send reply in non-pending mode", async () => {
            const message = { data: "pending test" };
            const produceRes = await client.produceMessage(testTunnelId, message);
            expect(produceRes.status).toBe(201);
            const messageId = produceRes.headers["x-message-id"];

            // Consume in non-pending mode
            let consumeRes = await client.consumeMessage(testTunnelId, false);
            expect(consumeRes.status).toBe(200);
            expect(consumeRes.data).toEqual(message);
            expect(consumeRes.headers["x-message-id"]).toBe(messageId);

            // Send reply (will not find message as it was auto acked)
            const replyBody = { data: "reply test" };
            let replyRes = await client.sendMessageReply(testTunnelId, messageId, replyBody);
            expect(replyRes.status).toBe(204);
        });
    });
});
