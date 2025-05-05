local redis_conn = require "redis_conn"

-- Helper function to generate Redis keys
local function get_stream_key(tunnel_id)
    return "t:" .. tunnel_id .. ":s"
end

-- Helper function to generate consumer group name
local function get_consumer_group(tunnel_id)
    return "t:" .. tunnel_id .. ":g"
end

-- Helper function to generate consumer id, consumers are shared per tunnel
local function get_consumer_id(tunnel_id)
    return "c-" .. tunnel_id
end

local function check_access_token()
    if not tunnel_config.token then
        return nil
    end

    local auth_header = ngx.var.http_Authorization
    if auth_header then
        _, _, token = string.find(auth_header, "Bearer%s+(.+)")
    end

    if not token or token ~= tunnel_config.token then
        ngx.status = 403
        ngx.print("Access denied")
        return ngx.exit(403)
    end
end

local _M = {}

-- POST a message to a tunnel
function _M.post_message()
    check_access_token()

    local tunnel_id = ngx.var.tunnel_id
    if not tunnel_id then
        ngx.status = 400
        ngx.print("Tunnel ID is required")
        return ngx.exit(400)
    end

    local limit = tonumber(ngx.req.get_uri_args().limit)
    local enable_backpressure = limit == nil and tunnel_config.enable_backpressure or limit > 0
    if limit == nil or limit <= 0 then
        limit = tunnel_config.maxlen
    end
    if limit > tunnel_config.maxlen then
        ngx.status = 400
        ngx.print("Limit must be less than the tunnel max length")
        return ngx.exit(400)
    end

    -- Get request body
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        local body_file = ngx.req.get_body_file()
        if body_file then
            local f = io.open(body_file, "rb")
            if f then
                body = f:read("*all")
                f:close()
            end
        end
    end

    if not body then
        body = ""
    end

    local content_type = ngx.req.get_headers()["Content-Type"]

    -- Connect to Redis
    local red, err = redis_conn.get_connection()
    if not red then
        ngx.status = 500
        ngx.print("Redis connection error")
        return ngx.exit(500)
    end

    -- Add message to the stream
    local stream_key = get_stream_key(tunnel_id)

    -- Check size limit
    local len
    if enable_backpressure then
        local err
        len, err = red:xlen(stream_key)
        if err then
            ngx.log(ngx.ERR, "Failed to get stream length '", stream_key, "': ", err)
            ngx.status = 500
            ngx.print("Failed to get stream length")
            redis_conn.release_connection(red)
            return ngx.exit(500)
        end
        if len >= limit then
            ngx.status = 507
            ngx.header["X-Queue-Size"] = len
            ngx.print("Queue limit reached, consumers are not keeping up")
            redis_conn.release_connection(red)
            return ngx.exit(507)
        end
    end

    local msg_id, err
    if content_type then
        msg_id, err = red:xadd(stream_key, "MAXLEN", "~", limit, "*", "data", body, "ct", content_type)
    else
        msg_id, err = red:xadd(stream_key, "MAXLEN", "~", limit, "*", "data", body)
    end

    redis_conn.release_connection(red)

    if not msg_id then
        ngx.log(ngx.ERR, "Failed to add message to stream: ", err)
        ngx.status = 500
        ngx.print("Failed to store message")
        return ngx.exit(500)
    end

    -- Return success
    ngx.status = 201
    ngx.header["X-Message-Id"] = msg_id
    if len ~= nil then
        ngx.header["X-Queue-Size"] = len + 1
    end
    return ngx.exit(201)
end

-- Common logic for reading messages
local function read_message(tunnel_id, block_timeout)
    local use_pending = ngx.req.get_uri_args().pending ~= nil

    -- Connect to Redis
    local red, err = redis_conn.get_connection()
    if not red then
        ngx.status = 500
        ngx.print("Redis connection error")
        return ngx.exit(500)
    end

    local stream_key = get_stream_key(tunnel_id)
    local group_name = get_consumer_group(tunnel_id)
    local consumer_id = get_consumer_id(tunnel_id)

    local msg_id, msg_fields

    if use_pending then
        -- XAUTOCLAIM key group consumer min-idle-time start [COUNT count]
        local result, err = red:xautoclaim(stream_key, group_name, consumer_id, 0, "0-0", "COUNT", 1)
        if err and string.sub(err,1,7) ~= "NOGROUP" then
            ngx.log(ngx.ERR, "Failed to claim pending from stream '", stream_key, "' id ", msg_id, ": ", err)
            ngx.status = 500
            ngx.print("Error getting pending messages")
            redis_conn.release_connection(red)
            return ngx.exit(500)
        end

        if result and next(result[2]) then
            msg_id = result[2][1][1]
            msg_fields = result[2][1][2]
        end
    end

    if msg_id == nil then
        local result, err
        for i=1,2 do
            if block_timeout > 0 then
                -- Use blocking read with timeout
                red:set_timeout((block_timeout * 1000) + 1000)
                if use_pending then
                    result, err = red:xreadgroup("GROUP", group_name, consumer_id, "COUNT", 1, "BLOCK", block_timeout * 1000, "STREAMS", stream_key, ">")
                else
                    result, err = red:xreadgroup("GROUP", group_name, consumer_id, "COUNT", 1, "NOACK", "BLOCK", block_timeout * 1000, "STREAMS", stream_key, ">")
                end
            else
                -- Non-blocking read
                if use_pending then
                    result, err = red:xreadgroup("GROUP", group_name, consumer_id, "COUNT", 1, "STREAMS", stream_key, ">")
                else
                    result, err = red:xreadgroup("GROUP", group_name, consumer_id, "COUNT", 1, "NOACK", "STREAMS", stream_key, ">")
                end
            end
            if err and string.sub(err,1,7) == "NOGROUP" then
                create_result, err = red:xgroup("CREATE", stream_key, group_name, 0, "MKSTREAM")
                if err then
                    ngx.log(ngx.ERR, "Failed to create stream '", stream_key, "' group '", group_name, "': ", err)
                    ngx.status = 500
                    ngx.print("Error reading from stream")
                    redis_conn.release_connection(red)
                    return ngx.exit(500)
                end
            else
                break
            end
        end

        if err then
            ngx.log(ngx.ERR, "Failed to read from stream '", stream_key, "': ", err)
            ngx.status = 500
            ngx.print("Error reading from stream")
            redis_conn.release_connection(red)
            return ngx.exit(500)
        end

        if not result or result == ngx.null then
            -- No new messages
            ngx.status = 204 -- No Content
            redis_conn.release_connection(red)
            return ngx.exit(204)
        end

        -- Get the message ID and data
        msg_id = result[1][2][1][1]
        msg_fields = result[1][2][1][2]
    end

    -- Delete received message from stream
    if not use_pending then
        local del_result, err = red:xdel(stream_key, msg_id)
        if err then
            ngx.log(ngx.ERR, "Failed to delete from stream '", stream_key, "' id ", msg_id, ": ", err)
            ngx.status = 500
            ngx.print("Error reading from stream")
            redis_conn.release_connection(red)
            return ngx.exit(500)
        end
    end

    redis_conn.release_connection(red)

    local content_type, content_body
    for i = 1, #msg_fields, 2 do
        if msg_fields[i] == "ct" then
            content_type = msg_fields[i + 1]
        elseif msg_fields[i] == "data" then
            content_body = msg_fields[i + 1]
        end
    end

    if content_body == nil then
        ngx.log(ngx.ERR, "Empty content body in stream '", stream_key, "' message '", msg_id, "'")
        ngx.status = 500
        ngx.print("Error reading from stream")
        return ngx.exit(500)
    end

    ngx.status = 200
    ngx.header["X-Message-Id"] = msg_id
    ngx.header["Content-Type"] = content_type or tunnel_config.def_content_type
    ngx.header["Content-Length"] = #content_body
    ngx.print(content_body)
    return ngx.exit(200)
end

-- GET a message from a tunnel (non-blocking)
function _M.get_message()
    check_access_token()

    local tunnel_id = ngx.var.tunnel_id
    if not tunnel_id then
        ngx.status = 400
        ngx.print("Tunnel ID is required")
        return ngx.exit(400)
    end

    return read_message(tunnel_id, 0)
end

-- GET messages using long polling
function _M.poll_message()
    check_access_token()

    local tunnel_id = ngx.var.tunnel_id
    if not tunnel_id then
        ngx.status = 400
        ngx.print("Tunnel ID is required")
        return ngx.exit(400)
    end

    -- Get timeout in seconds
    local timeout = tonumber(ngx.req.get_uri_args().timeout) or tunnel_config.def_poll_timeout
    if timeout > tunnel_config.max_poll_timeout then
        timeout = tunnel_config.max_poll_timeout
    end

    return read_message(tunnel_id, timeout)
end

-- DELETE a message from a tunnel (acknowledge)
function _M.ack_message()
    check_access_token()

    local tunnel_id = ngx.var.tunnel_id
    if not tunnel_id then
        ngx.status = 400
        ngx.print("Tunnel ID is required")
        return ngx.exit(400)
    end

    local msg_id = ngx.var.msg_id
    if not msg_id then
        ngx.status = 400
        ngx.print("Message ID is required")
        return ngx.exit(400)
    end

    -- Connect to Redis
    local red, err = redis_conn.get_connection()
    if not red then
        ngx.status = 500
        ngx.print("Redis connection error")
        return ngx.exit(500)
    end

    local stream_key = get_stream_key(tunnel_id)
    local group_name = get_consumer_group(tunnel_id)

    -- Acknowledge the message
    local res, err = red:xack(stream_key, group_name, msg_id)
    if err then
        ngx.log(ngx.ERR, "Failed to acknowledge '", stream_key, "' id ", msg_id, ": ", err)
        ngx.status = 500
        ngx.print("Failed to acknowledge message")
        redis_conn.release_connection(red)
        return ngx.exit(500)
    end

    -- Delete acknowledged message from stream
    local res, err = red:xdel(stream_key, msg_id)
    if err then
        ngx.log(ngx.ERR, "Failed to delete from stream '", stream_key, "' id ", msg_id, ": ", err)
        ngx.status = 500
        ngx.print("Failed to acknowledge message")
        redis_conn.release_connection(red)
        return ngx.exit(500)
    end

    ngx.status = 204 -- No Content
    redis_conn.release_connection(red)
    return ngx.exit(204)
end

-- GET queue length for the tunnel
function _M.get_length()
    check_access_token()

    local tunnel_id = ngx.var.tunnel_id
    if not tunnel_id then
        ngx.status = 400
        ngx.print("Tunnel ID is required")
        return ngx.exit(400)
    end

    -- Connect to Redis
    local red, err = redis_conn.get_connection()
    if not red then
        ngx.status = 500
        ngx.print("Redis connection error")
        return ngx.exit(500)
    end

    local stream_key = get_stream_key(tunnel_id)

    local len, err = red:xlen(stream_key)
    redis_conn.release_connection(red)

    if err then
        ngx.log(ngx.ERR, "Failed to get stream length '", stream_key, "': ", err)
        ngx.status = 500
        ngx.print("Failed to get stream length")
        return ngx.exit(500)
    end

    -- Return the length
    ngx.status = 204
    ngx.header["X-Queue-Size"] = len
    return ngx.exit(204)
end

return _M
