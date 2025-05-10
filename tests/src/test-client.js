const axios = require("axios");

// --- Configuration ---
const BASE_URL = process.env.BASE_URL || "http://localhost:8080";
const ACCESS_TOKEN = process.env.TUNNEL_ACCESS_TOKEN || "thisisasecret";
const DEMO_TUNNEL_ID = process.env.TUNNEL_DEMO_ID || "demo";

// --- API Client Setup ---
const apiClient = axios.create({
  baseURL: BASE_URL,
  validateStatus: () => true, // Important: allows us to assert on all HTTP status codes
});

function getAuthHeaders(customHeaders = {}) {
  const headers = { ...customHeaders };
  if (ACCESS_TOKEN) {
    headers["Authorization"] = `Bearer ${ACCESS_TOKEN}`;
  }
  return headers;
};

module.exports = {
    DEMO_TUNNEL_ID,
    getApiClient: () => apiClient,
    produceMessage: async function (
        tunnelId,
        body,
        contentType = "application/json",
        limit = undefined,
        additionalHeaders = {},
    ) {
        const headers = getAuthHeaders({
            "Content-Type": contentType,
            ...additionalHeaders,
        });
        let url = `/t/${tunnelId}`;
        if (limit !== undefined) {
            url += `?limit=${limit}`;
        }
        return apiClient.post(url, body, { headers });
    },
    consumeMessage: async function (
        tunnelId,
        pending = false,
        additionalHeaders = {},
    ) {
        const headers = getAuthHeaders(additionalHeaders);
        let url = `/t/${tunnelId}`;
        if (pending) {
            url += `?pending`;
        }
        return apiClient.get(url, { headers });
    },
    pollMessage: async function(
        tunnelId,
        timeout = undefined,
        pending = false,
        additionalHeaders = {},
    ) {
        const headers = getAuthHeaders(additionalHeaders);
        let url = `/t/${tunnelId}/poll`;
        const params = [];
        if (timeout !== undefined) {
            params.push(`timeout=${timeout}`);
        }
        if (pending) {
            params.push(`pending`);
        }
        if (params.length > 0) {
            url += `?${params.join("&")}`;
        }
        return apiClient.get(url, { headers });
    },
    ackMessage: async function(tunnelId, messageId, additionalHeaders = {}) {
        const headers = getAuthHeaders(additionalHeaders);
        return apiClient.delete(`/t/${tunnelId}/${messageId}`, { headers });
    },
    sendMessageReply: async function(
        tunnelId,
        messageId,
        replyBody,
        contentType = "application/json",
        additionalHeaders = {},
    ) {
        const headers = getAuthHeaders({
            "Content-Type": contentType,
            ...additionalHeaders,
        });
        return apiClient.post(`/t/${tunnelId}/${messageId}/reply`, replyBody, { headers });
    },
    getMessageReply: async function(tunnelId, messageId, additionalHeaders = {}) {
        const headers = getAuthHeaders(additionalHeaders);
        return apiClient.get(`/t/${tunnelId}/${messageId}/reply`, { headers });
    },
    pollMessageReply: async function(tunnelId, messageId, timeout = undefined, additionalHeaders = {}) {
        const headers = getAuthHeaders(additionalHeaders);
        let url = `/t/${tunnelId}/${messageId}/reply/poll`;
        if (timeout !== undefined) {
            url += `?timeout=${timeout}`;
        }
        return apiClient.get(url, { headers });
    },
    getMessageStatus: async function(tunnelId, messageId, additionalHeaders = {}) {
        const headers = getAuthHeaders(additionalHeaders);
        return apiClient.get(`/t/${tunnelId}/${messageId}`, { headers });
    },
    getQueueLength: async function(tunnelId, additionalHeaders = {}) {
        const headers = getAuthHeaders(additionalHeaders);
        return apiClient.get(`/t/${tunnelId}/len`, { headers });
    },
    cleanQueue: async function(tunnelId, additionalHeaders = {}) {
        const headers = getAuthHeaders(additionalHeaders);
        return apiClient.delete(`/t/${tunnelId}/all`, { headers });
    },
};
