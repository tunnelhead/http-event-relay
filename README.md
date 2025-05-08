# HTTP Event Relay

One to one message delivery system.

Built on top of OpenResty and KeyDB, inheriting their scalability and performance.

[Fancy Live Demo!](https://relay.tunnelhead.dev/demo/)

## Original purpose

Easy communication between two parties behind NAT.

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
curl http://localhost:8080/t/my-secret-tunnel
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
| TUNNEL_MAXLEN               | Maximum queue size for a single tunnel                 | 1000       |
| TUNNEL_BACKPRESSURE         | If backpressure should be enabled by default (1 or 0)  | 1          |
| TUNNEL_MAX_POLL_TIMEOUT     | Maximum wait time for long polling (seconds)           | 60         |
| TUNNEL_DEFAULT_POLL_TIMEOUT | Default wait time for long polling (seconds)           | 30         |
| TUNNEL_DEFAULT_CONTENT_TYPE | Content-Type header to use if not provided by producer | text/plain |

### Limits

Max message size is set to 128kb by default using `client_max_body_size` option in [nginx.conf](conf/nginx.conf).

## Protocol

__Authorization:__

By default relay server is not protected and accepts any requests.

If access token is provided in `TUNNEL_ACCESS_TOKEN` configuration option,
requests to tunnel endpoints (`/t/...`) will require authorization header:

```
Authorization: Bearer <access-token>
```

__Tunnel IDs:__

Protocol description mentions `<tunnel-id>` in urls, which must be replaced with user-selected identifier.

It must match on the producer and the receiver side for the message to be delivered.

It's advised to use UUIDv4 or similar large random unique identifier for tunnel id, especially in public networks.

Acceptable characters in the identifier:

- Any letter
- Any digit
- Characters '-' and '_'

Tunnel IDs can be up to 1024 characters long.

__Two-Way Communication:__

A single tunnel provides one-way communiation between two parties (from a producer to a consumer).

For two-way communication, use two tunnels with different ids (one in each direction).


__Backpressure:__

With the default configuration, backpressure is enabled by default.

This means that if producer sends messages faster than consumer is able to read them,
producer will start receiving errors from the relay once queue size limit is reached.

This behaviour can be disabled in configuration or per tunnel on the producer side.
In this case, if consumer is unable to keep up and queue size limit is reached,
oldest messages can be discarded even if they are not yet read by the consumer.

It makes sense to disable backpressure if optimising for delivery speed and data loss is acceptable.

__Acknowledgement__:

By default the consumed message is automatically acknowledged and deleted.

However, if using pending mode on the consumer, the relay will keep returning the same message over and over again,
until it's manually acknowledged (deleted).

### Produce a message

`POST /t/<tunnel-id>` with the request body containing a message in any format.

This endpoint stores `Content-Type` header with the message and sends it to the consumer.

Backpressure can be configured on the consumer side by using a numeric `limit` url parameter: `POST /t/<tunnel-id>?limit=100` (in this case, max queue size is set to 100).

Backpressure can be disabled by setting the `limit` to `0`

__Success response:__

201 with empty body.

Created message id can be obtained from `X-Message-Id` header in the response.

If backpressure is enabled, current queue size can be obtained from `X-Queue-Size` header in the response.

__Error responses:__

- 400 if invalid url or parameter is provided.
- 500 with text body containing error description, if internal error has occured (see OpenResty log for more details).
- 507 in case of backpressure (if queue size limit reached), current queue size can be obtained from `X-Queue-Size` header in the response.

__Example request:__

```
curl -d '{"text": "Hello, World!"}' -H "Content-Type: application/json" -X POST https://relay.tunnelhead.dev/t/my-secret-tunnel
```

__Example response:__

```
201 Created
X-Message-Id: 1746450313373-0
X-Queue-Size: 1
```

### Consume a message

`GET /t/<tunnel-id>`

This endpoint checks for new messages in the tunnel in a non-blocking manner.
The request will be complete immediately.

Pending mode can be enabled by adding `pending` url parameter: `GET /t/<tunnel-id>?pending`.
In pending mode, message has to be acknowledged (deleted) manually using acknowledgement endpoint.

__Success responses:__

- 204 with empty body if no new messages were found.
- 200 with body containing the new message. Content type can be obtained from `Content-Type` header in the response. Message id can be obtained from `X-Message-Id` header in the response.

__Error responses:__

- 500 with text body containing error description, if internal error has occured (see OpenResty log for more details).

__Example request:__

```
curl https://relay.tunnelhead.dev/t/my-secret-tunnel
```

__Example response:__

```
200 OK
X-Message-Id: 1746450313373-0
Content-Type: application/json
Content-Length: 25
{"text": "Hello, World!"}
```

### Consume a message (long polling)

`GET /t/<tunnel-id>/poll`

This endpoint checks for new messages in the tunnel in a blocking manner.
The request will be complete when a new message appears or if timeout reached, whatever comes first.

Timeout can be customised by providing a number of seconds in the `timeout` url parameter: `GET /t/<tunnel-id>/poll?timeout=10`. If timeout is larger than max timeout configured for the relay instance, a max timeout will be used instead.

Pending mode can be enabled by adding `pending` url parameter: `GET /t/<tunnel-id>/poll?pending`.
In pending mode, message has to be acknowledged (deleted) manually using acknowledgement endpoint.

Both url parameters can be used together: `GET /t/<tunnel-id>/poll?timeout=10&pending`.

__Success responses:__

- 204 with empty body if no new messages were found or timeout reached.
- 200 with body containing the new message. Content type can be obtained from `Content-Type` header in the response. Message id can be obtained from `X-Message-Id` header in the response.

__Error responses:__

- 500 with text body containing error description, if internal error has occured (see OpenResty log for more details).

### Acknowledge a message

`DELETE /t/<tunnel-id>/<message-id>`

This endpoint is used for consumers in pending mode to acknowledge message delivery and delete it from the tunnel.

__Success responses:__

- 204 with empty body

__Error responses:__

- 500 with text body containing error description, if internal error has occured (see OpenResty log for more details).

__Example request:__

```
curl -X DELETE https://relay.tunnelhead.dev/t/my-secret-tunnel/1746483376267-0
```

__Example response:__

```
204 No Content
```

### Get queue size (length)

`GET /t/<tunnel-id>/len`

When backpressure is enabled, queue size can be checked using this endpoint.

Queue size includes both seen (pending) and unseen by the consumer messages.

__Success responses:__

- 204 with empty body. Current queue size can be obtained from `X-Queue-Size` header in the response.

__Error responses:__

- 500 with text body containing error description, if internal error has occured (see OpenResty log for more details).

__Example request:__

```
curl https://relay.tunnelhead.dev/t/my-secret-tunnel/len
```

__Example response:__

```
204 No Content
X-Queue-Size: 3
```

### Clean the queue (delete tunnel)

`DELETE /t/<tunnel-id>/all`

Clean all messages from the tunnel, including pending and not yet seen.

This effectively deletes the tunnel.

__Success responses:__

- 204 with empty body. Current queue size (always 0 for this request) can be obtained from `X-Queue-Size` header in the response.

__Error responses:__

- 500 with text body containing error description, if internal error has occured (see OpenResty log for more details).

__Example request:__

```
curl -X DELETE https://relay.tunnelhead.dev/t/my-secret-tunnel/all
```

__Example response:__

```
204 No Content
X-Queue-Size: 0
```

### Health check

`GET /health`

This endpoint ensures that OpenResty is up and running. It must always return http code 200 and text "OK".

__Example request:__

```
curl https://relay.tunnelhead.dev/health
```

__Example response:__

```
200 OK
Content-Type: text/plain
OK
```

## Load testing

WIP