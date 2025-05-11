# HTTP Event Relay

One to one message delivery system.

Built on top of OpenResty and KeyDB, inheriting their scalability and performance.

[Fancy Live Demo!](https://relay.tunnelhead.dev/demo/)

## Potential uses

* Communication between two parties behind NAT
* Converting webhook updates into long polling endpoint

## Concepts

_Because you can't be a Tunnelhead without tunnels_

- __Relay__ - a software, which repeats the message send by a producer to a consumer
- __Tunnel__ - a one-way path for messages between two parties
- __Producer__ - a party sending a message
- __Consumer__ - a party receiving a message
- __Message__ - a single blob of data sent from one party to another
- __Event__ - a detectable occurrence which causes a message to be sent
- __Queue__ - a list of messages sent by one party, but not yet accepted by a second party
- __Backpressure__ - a mechanism, which production of new messages when queue is congested
- __Pending__ - a message, which was accepted by a second party, but not yet processed

## How to run

This software is designed to work in a Docker container. OpenResty DNS resolver is hardcoded to use Docker.

### Docker

`Dockerfile` is provided for a standalone setup.

Example usage (requies having docker container with redis in docker network `my-network`):

```
git clone https://github.com/tunnelhead/http-event-relay.git
cd http-event-relay
docker build -t http-event-relay .
docker run -p 8080:80 -e REDIS_HOST=my-redis-instance --network=my-network --name test-relay http-event-relay
curl -s http://localhost:8080/health
```

### Docker Compose

Various docker compose files are provided for easy development and testing.

Docker compose configuration includes both keydb (redis alternative) and relay containers.

Example usage:

```
git clone https://github.com/tunnelhead/http-event-relay.git
cd http-event-relay
docker-compose up -d
docker run --rm --network http-event-relay_default alpine/curl -s http://tunnel-server/health
```

__Development:__

For relay development purposes, a separate docker compose configuration is provided.

It disables lua cache and mounts the sources directory to the container, which acts as a "hot reload".
Once container is running, any changes in `src` directory will be reflected immediately.

```
git clone https://github.com/tunnelhead/http-event-relay.git
cd http-event-relay
docker-compose -f 'docker-compose.dev.yml' up -d
curl http://localhost:8080/health
curl -v -H "Authorization: Bearer thisisasecret" http://localhost:8080/t/my-secret-tunnel
```

Development version has demo enabled by default http://localhost:8080/demo/

__Tests:__

When development containers are up and running, you can execute some automatic tests to validate the changes.

NodeJs is required to run the tests.

```
cd tests
npm install
npm run tests
```

### Configuration options

Event relay can be configured using the following environmental variables:

| Env var                     | Description                                            | Default    |
|-----------------------------|--------------------------------------------------------|------------|
| REDIS_HOST                  | Redis hostname                                         | 127.0.0.1  |
| REDIS_PORT                  | Redis port                                             | 6379       |
| REDIS_PASSWORD              | Redis password (optional, use if required)             |            |
| REDIS_POOL_SIZE             | How much connections to keep alive after use           | 100        |
| REDIS_POOL_KEEPALIVE        | How long to keep connections alive after use (seconds) | 10         |
| TUNNEL_ACCESS_TOKEN         | Access token to authenticate requests to the relay     |            |
| TUNNEL_SIGNATURE_SECRET     | Secret for validating request data signature           |            |
| TUNNEL_MAXLEN               | Maximum queue size for a single tunnel                 | 1000       |
| TUNNEL_BACKPRESSURE         | If backpressure should be enabled by default (1 or 0)  | 1          |
| TUNNEL_MAX_POLL_TIMEOUT     | Maximum wait time for long polling (seconds)           | 60         |
| TUNNEL_DEFAULT_POLL_TIMEOUT | Default wait time for long polling (seconds)           | 30         |
| TUNNEL_DEFAULT_CONTENT_TYPE | Content-Type header to use if not provided by producer | text/plain |
| TUNNEL_REPLY_TTL            | How much seconds to keep a message reply               | 3600       |

### Limits

Max message size is set to 128kb by default using `client_max_body_size` option in [nginx.conf](conf/nginx.conf).

## Protocol

### Authorization

By default relay server is not protected and accepts any requests.
But one or more options can be configured to protect it.

#### Access Token

If access token is provided in `TUNNEL_ACCESS_TOKEN` configuration option,
requests to tunnel endpoints (`/t/...`) will require authorization header:

```
Authorization: Bearer <access-token>
```

#### Signature Validation

Producers can be protected via payload signature validation instead of the access token.

HMAC secret must be provided in `TUNNEL_SIGNATURE_SECRET` configuration option,
requests to producer endpoints will require valid signature in the header (e.g. for GitHub Webhooks):

```
X-Hub-Signature-256: sha256=<signature>
```

### Tunnel IDs

Protocol description mentions `<tunnel-id>` in urls, which must be replaced with user-selected identifier.

It must match on the producer and the receiver side for the message to be delivered.

It's advised to use UUIDv4 or similar large random unique identifier for tunnel id, especially in public networks.

Acceptable characters in the identifier:

- Any letter
- Any digit
- Characters '-' and '_'

Tunnel IDs can be up to 1024 characters long.

### Two-Way Communication

A single tunnel provides one-way communiation between two parties (from a producer to a consumer)
with optional replies on [acknowledgement](#acknowledgement).

For robust two-way communication, use two tunnels with different ids (one in each direction).


### Backpressure

With the default configuration, backpressure is enabled by default.

This means that if producer sends messages faster than consumer is able to read them,
producer will start receiving errors from the relay once queue size limit is reached.

This behaviour can be disabled in configuration or per tunnel on the producer side.
In this case, if consumer is unable to keep up and queue size limit is reached,
oldest messages can be discarded even if they are not yet read by the consumer.

It makes sense to disable backpressure if optimising for delivery speed and data loss is acceptable.

### Acknowledgement

By default the consumed message is automatically acknowledged and deleted.

However, if using pending mode on the consumer, the relay will keep returning the same message over and over again,
until it's manually [acknowledged](#3-acknowledge-a-message).

Alternatively, it's possible to [acknowledge with reply](#4-acknowledge-with-reply) to send some information back to the producer.
Producer then must [read](#read-reply-non-blocking) or [poll](#read-reply-long-polling) for the reply.

Replies are stored for limited time (as [configured](#configuration-options)) and removed immediately after read.
If more reliable way is required, consider using a separate tunnel for communication in other direction.

## Endpoints

- [Common Placeholders](#common-placeholders)
- [Common Errors](#common-errors)
- [1. Produce a Message](#1-produce-a-message)
- [2. Consume Messages](#2-consume-messages)
  - [Consume a Message (Non-blocking)](#consume-a-message-non-blocking)
  - [Consume a Message (Long Polling)](#consume-a-message-long-polling)
- [3. Acknowledge a Message](#3-acknowledge-a-message)
- [4. Acknowledge with Reply](#4-acknowledge-with-reply)
- [5. Read Message Reply](#5-read-message-reply)
  - [Read Reply (Non-blocking)](#read-reply-non-blocking)
  - [Read Reply (Long Polling)](#read-reply-long-polling)
- [6. Get Message Status](#6-get-message-status)
- [7. Get Queue Size](#7-get-queue-size)
- [8. Clear Tunnel (Delete All Messages)](#8-clear-tunnel-delete-all-messages)
- [9. Health Check](#9-health-check)

### Common Placeholders

-   `<tunnel-id>`: A unique string identifying a specific tunnel.
-   `<message-id>`: A unique string identifying a specific message within a tunnel.

### Common Errors

Generally, these errors can occur on any endpoint.

| Status Code                | Description |
| :------------------------- | :------------------------- |
| `400 Bad Request`          | Invalid URL or parameter provided. |
| `500 Internal Server Error`| Internal error occurred. The response body contains an error description. See OpenResty log for more details. |

### 1. Produce a Message

`POST /t/<tunnel-id>`

Stores a message in the specified tunnel. The `Content-Type` header of the request is stored with the message and sent to the consumer.

#### URL Parameters

| Parameter | Type    | Description | Required | Default |
| :-------- | :------ | :---------- | :------- | :------ |
| `limit`   | Integer | Sets the maximum queue size for backpressure. A value of `0` disables backpressure. | No | As [configured](#configuration-options) |

#### Request Headers

| Header         | Description                     | Example            | Required | Default  |
| :------------- | :------------------------------ | :----------------- | :------- | :------- |
| `Content-Type` | The format of the message body. | `application/json` | No       | As [configured](#configuration-options) |

#### Response Headers

| Header         | Description                                                        | Example           |
| :------------- | :----------------------------------------------------------------- | :---------------- |
| `X-Message-Id` | The ID of the created message.                                     | `1746450313373-0` |
| `X-Queue-Size` | Current queue size (returned if backpressure is enabled via `limit`). | `1`               |

#### Responses

**Success:**

| Status Code   | Description                                |
| :------------ | :----------------------------------------- |
| `201 Created` | Message successfully produced. Empty body. |

**Errors:**

| Status Code                | Description |
| :------------------------- | :------------------------- |
| `507 Insufficient Storage` | Backpressure enabled and queue size limit reached. `X-Queue-Size` header indicates the current queue size.   |

#### Example

**Request:**

```bash
curl -d '{"text": "Hello, World!"}' \
     -H "Content-Type: application/json" \
     -X POST https://relay.tunnelhead.dev/t/demo?limit=100
```

**Response:**

```http
HTTP/1.1 201 Created
X-Message-Id: 1746450313373-0
X-Queue-Size: 1
```

---

### 2. Consume Messages

#### Consume a Message (Non-blocking)

`GET /t/<tunnel-id>`

Checks for new messages in the tunnel in a non-blocking manner. The request completes immediately.

#### URL Parameters

| Parameter | Type | Description                                                                                                | Required |
| :-------- | :--- | :--------------------------------------------------------------------------------------------------------- | :------- |
| `pending` | Flag | If present, the consumed message is not automatically deleted and must be [acknowledged](#3-acknowledge-a-message) manually. | No       |

#### Response Headers

| Header         | Description                        | Example            |
| :------------- | :--------------------------------- | :----------------- |
| `Content-Type` | The format of the message body.    | `application/json` |
| `X-Message-Id` | The ID of the consumed message.    | `1746450313373-0`  |

#### Responses

**Success:**

| Status Code      | Description |
| :--------------- | :---------- |
| `200 OK`         | New message found. The response body contains the message. `Content-Type` and `X-Message-Id` are present. |
| `204 No Content` | No new messages were found. Empty body. |

#### Example

**Request:**

```bash
curl -v https://relay.tunnelhead.dev/t/demo
```

**Response (if message exists):**

```http
HTTP/1.1 200 OK
X-Message-Id: 1746450313373-0
Content-Type: application/json
Content-Length: 25

{"text": "Hello, World!"}
```

**Response (if no message):**

```http
HTTP/1.1 204 No Content
```

---

#### Consume a Message (Long Polling)

`GET /t/<tunnel-id>/poll`

Checks for new messages in the tunnel in a blocking manner. The request will complete when a new message appears or if a timeout is reached, whichever comes first.

#### URL Parameters

| Parameter | Type    | Description  | Required | Default        |
| :-------- | :------ | :----------- | :------- | :------------- |
| `timeout` | Integer | Timeout in seconds. If larger than the max timeout configured for the relay instance, max timeout is used. | No      | As [configured](#configuration-options) |
| `pending` | Flag    | If present, the consumed message is not automatically deleted and must be [acknowledged](#3-acknowledge-a-message) manually. | No      | N/A            |

*Both `timeout` and `pending` can be used together: `GET /t/<tunnel-id>/poll?timeout=10&pending`*

#### Response Headers

(Same as non-blocking consume: `Content-Type`, `X-Message-Id`)

#### Responses

**Success:**

| Status Code      | Description                                                                                                   |
| :--------------- | :------------------------------------------------------------------------------------------------------------ |
| `200 OK`         | New message found. The response body contains the message. `Content-Type` and `X-Message-Id` are present.       |
| `204 No Content` | No new messages were found within the timeout period. Empty body.                                               |

#### Example

**Request:**

```bash
curl -v "https://relay.tunnelhead.dev/t/demo/poll?timeout=10"
```

**Response (if message arrives within 10s):**

```http
HTTP/1.1 200 OK
X-Message-Id: 1746450313373-1
Content-Type: application/json
Content-Length: 25

{"text": "Another message"}
```

**Response (if timeout occurs):**

```http
HTTP/1.1 204 No Content
```

---

### 3. Acknowledge a Message

`DELETE /t/<tunnel-id>/<message-id>`

This endpoint is used by consumers in `pending` mode to acknowledge message delivery and delete it from the tunnel.

#### Responses

**Success:**

| Status Code      | Description              |
| :--------------- | :----------------------- |
| `204 No Content` | Message acknowledged and deleted. Empty body. |

#### Example

**Request:**

```bash
curl -X DELETE https://relay.tunnelhead.dev/t/demo/1746483376267-0
```

**Response:**

```http
HTTP/1.1 204 No Content
```

---

### 4. Acknowledge with Reply

`POST /t/<tunnel-id>/<message-id>/reply`

This endpoint acknowledges a message and stores the reply for the producer to [read](#5-read-message-reply).

The `Content-Type` header of the request is stored with the reply and sent back to the producer.

#### Request Headers

| Header         | Description                     | Example            | Required | Default |
| :------------- | :------------------------------ | :----------------- | :------- | :------ |
| `Content-Type` | The format of the message body. | `application/json` | No       | As [configured](#configuration-options) |

#### Responses

**Success:**

| Status Code   | Description                           |
| :------------ | :------------------------------------ |
| `201 Created` | Reply successfully saved. Empty body. |

**Errors:**

| Status Code                | Description |
| :------------------------- | :------------------------- |
| `204 No Content`           | Message to reply to is not found or not in pending state. |

#### Example

**Request:**

```bash
curl -d '{"text": "Hello, World!"}' \
     -H "Content-Type: application/json" \
     -X POST https://relay.tunnelhead.dev/t/demo/1746483376267-0/reply
```

**Response:**

```http
HTTP/1.1 201 Created
```

---

### 5. Read Message Reply

#### Read Reply (Non-blocking)

`GET /t/<tunnel-id>/<message-id>/reply`

This endpoint allows producer to read a reply to a message, if a consumer has sent one during [acknowledgement](#acknowledgement) in pending mode.

#### Response Headers

| Header         | Description                        | Example            |
| :------------- | :--------------------------------- | :----------------- |
| `Content-Type` | The format of the message body.    | `application/json` |

#### Responses

**Success:**

| Status Code      | Description |
| :--------------- | :---------- |
| `200 OK`         | Reply found. The response body contains the message. `Content-Type` is present. |
| `204 No Content` | No reply was found. Empty body. |

#### Example

**Request:**

```bash
curl -v https://relay.tunnelhead.dev/t/demo/1746483376267-0/reply
```

**Response (if reply exists):**

```http
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 25

{"text": "Hello, World!"}
```

**Response (if no reply):**

```http
HTTP/1.1 204 No Content
```

---

#### Read Reply (Long Polling)

`GET /t/<tunnel-id>/<message-id>/reply/poll`

This endpoint allows producer to wait for a reply to a message (in a blocking manner).

#### URL Parameters

| Parameter | Type    | Description  | Required | Default        |
| :-------- | :------ | :----------- | :------- | :------------- |
| `timeout` | Integer | Timeout in seconds. If larger than the max timeout configured for the relay instance, max timeout is used. | No      | As [configured](#configuration-options) |

#### Response Headers

| Header         | Description                        | Example            |
| :------------- | :--------------------------------- | :----------------- |
| `Content-Type` | The format of the message body.    | `application/json` |

#### Responses

**Success:**

| Status Code      | Description        |
| :--------------- | :----------------- |
| `200 OK`         | Reply found. The response body contains the message. `Content-Type` is present. |
| `204 No Content` | No reply was found within the timeout period. Empty body. |

#### Example

**Request:**

```bash
curl -v "https://relay.tunnelhead.dev/t/demo/1746483376267-0/reply?timeout=10"
```

**Response (if reply arrives within 10s):**

```http
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 25

{"text": "Another message"}
```

**Response (if timeout occurs):**

```http
HTTP/1.1 204 No Content
```

---

### 6. Get Message Status

`GET /t/<tunnel-id>/<message-id>`

Retrieves the status of a message in a tunnel.

#### Responses

**Success:**

| Status Code      | Description                                                            |
| :--------------- | :--------------------------------------------------------------------- |
| `201 Created`    | Message was created by producer, but not seen by consumer yet          |
| `202 Accepted`   | Message was seen by consumer, but not acknowledged yet (pending mode)  |
| `204 No Content` | Message never existed or was already consumed and acknowledged         |

#### Example

**Request:**

```bash
curl -v https://relay.tunnelhead.dev/t/demo/1746483376267-0
```

**Response:**

```http
HTTP/1.1 202 Accepted
```

---

### 7. Get Queue Size

`GET /t/<tunnel-id>/len`

Retrieves the current size of the message queue for a tunnel. This is particularly useful when backpressure is enabled. The queue size includes both seen (pending) and unseen messages.

#### Response Headers

| Header         | Description           | Example |
| :------------- | :-------------------- | :------ |
| `X-Queue-Size` | Current queue size.   | `3`     |

#### Responses

**Success:**

| Status Code      | Description                                                              |
| :--------------- | :----------------------------------------------------------------------- |
| `204 No Content` | Success. Current queue size is in the `X-Queue-Size` header. Empty body. |

#### Example

**Request:**

```bash
curl -v https://relay.tunnelhead.dev/t/demo/len
```

**Response:**

```http
HTTP/1.1 204 No Content
X-Queue-Size: 3
```

---

### 8. Clear Tunnel (Delete All Messages)

`DELETE /t/<tunnel-id>/all`

Clears all messages from the specified tunnel, including pending and not-yet-seen messages. This effectively deletes the tunnel and its contents.

#### Response Headers

| Header         | Description                                  | Example |
| :------------- | :------------------------------------------- | :------ |
| `X-Queue-Size` | Current queue size (will always be `0`).     | `0`     |

#### Responses

**Success:**

| Status Code      | Description                                                                |
| :--------------- | :------------------------------------------------------------------------- |
| `204 No Content` | Tunnel cleared. `X-Queue-Size` header indicates `0`. Empty body.           |

#### Example

**Request:**

```bash
curl -X DELETE https://relay.tunnelhead.dev/t/demo/all
```

**Response:**

```http
HTTP/1.1 204 No Content
X-Queue-Size: 0
```

---

### 9. Health Check

`GET /health`

This endpoint can be used to verify that the OpenResty service is up and running.

#### Responses

**Success:**

| Status Code | Description                                      |
| :---------- | :----------------------------------------------- |
| `200 OK`    | Service is healthy. Body contains "OK".          |

#### Example

**Request:**

```bash
curl https://relay.tunnelhead.dev/health
```

**Response:**

```http
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 2

OK
```

## Load testing

WIP
