local utils = require "utils"
local redis_conn = require "redis_conn"
local access_control = require "access_control"

-- Helper functions to generate Redis keys

local function get_stream_key(tunnel_id)
    return "t:" .. tunnel_id .. ":s"
end

local function get_consumer_group(tunnel_id)
    return "t:" .. tunnel_id .. ":g"
end

local function get_consumer_id(tunnel_id)
    return "c-" .. tunnel_id
end

local function get_reply_key(tunnel_id, msg_id)
    return "t:" .. tunnel_id .. ":r-" .. msg_id
end

local function get_reply_type_key(tunnel_id, msg_id)
    return "t:" .. tunnel_id .. ":rt-" .. msg_id
end

-- Tunnel helpers

local function check_access(tunnel_id)
    if access_control.is_public_tunnel(tunnel_id) then
        return
    end

    access_control.ensure_access()
end

local function get_validated_tunnel_id()
    local tunnel_id = ngx.var.tunnel_id
    if not tunnel_id then
        ngx.status = 400
        ngx.print("Tunnel ID is required")
        return ngx.exit(400)
    end

    check_access(tunnel_id)

    return tunnel_id
end

local function get_validated_message_id()
    local msg_id = ngx.var.msg_id
    if not msg_id then
        ngx.status = 400
        ngx.print("Message ID is required")
        return ngx.exit(400)
    end
    return msg_id
end

local function get_redis_connection()
    local red, err = redis_conn.get_connection()
    if not red then
        return release_and_exit(red, 500, "Redis connection error")
    end
    return red
end

local function release_and_exit(red, status_code, message)
    if red ~= nil then
        redis_conn.release_connection(red)
    end

    ngx.status = status_code
    if message ~= nil then
        ngx.print(message)
    end
    return ngx.exit(status_code)
end

-- Module

local _M = {}

-- POST a message to a tunnel
function _M.post_message()
    local tunnel_id = get_validated_tunnel_id()

    local limit = tonumber(ngx.req.get_uri_args().limit)
    local enable_backpressure = limit == nil and tunnel_config.enable_backpressure or limit > 0
    if limit == nil or limit <= 0 then
        limit = tunnel_config.maxlen
    end
    if limit > tunnel_config.maxlen then
        return release_and_exit(nil, 400, "Limit must be less than the tunnel max length")
    end

    local body = utils.get_request_body()
    local content_type = ngx.req.get_headers()["Content-Type"]

    local stream_key = get_stream_key(tunnel_id)

    local red = get_redis_connection()

    -- Check size limit
    local len
    if enable_backpressure then
        local err
        len, err = red:xlen(stream_key)
        if err then
            ngx.log(ngx.ERR, "Failed to get stream length '", stream_key, "': ", err)
            return release_and_exit(red, 500, "Failed to get stream length")
        end
        if len >= limit then
            ngx.header["X-Queue-Size"] = len
            return release_and_exit(red, 507, "Queue limit reached, consumers are not keeping up")
        end
    end

    local msg_id, err
    if content_type then
        msg_id, err = red:xadd(stream_key, "MAXLEN", "~", limit, "*", "data", body, "ct", content_type)
    else
        msg_id, err = red:xadd(stream_key, "MAXLEN", "~", limit, "*", "data", body)
    end

    if not msg_id then
        ngx.log(ngx.ERR, "Failed to add message to stream: ", err)
        return release_and_exit(red, 500, "Failed to store message")
    end

    -- Return success
    ngx.header["X-Message-Id"] = msg_id
    if len ~= nil then
        ngx.header["X-Queue-Size"] = len + 1
    end
    return release_and_exit(red, 201, nil) -- Created
end

-- Common logic for reading messages
local function read_message(tunnel_id, block_timeout, use_pending)
    local red = get_redis_connection()

    local stream_key = get_stream_key(tunnel_id)
    local group_name = get_consumer_group(tunnel_id)
    local consumer_id = get_consumer_id(tunnel_id)

    local msg_id, msg_fields

    if use_pending then
        local result, err = red:xautoclaim(stream_key, group_name, consumer_id, 0, "0-0", "COUNT", 1)
        if err and string.sub(err,1,7) ~= "NOGROUP" then
            ngx.log(ngx.ERR, "Failed to claim pending from stream '", stream_key, "' id ", msg_id, ": ", err)
            return release_and_exit(red, 500, "Error getting pending messages")
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
                    return release_and_exit(red, 500, "Error reading from tunnel")
                end
            else
                break
            end
        end

        if err then
            ngx.log(ngx.ERR, "Failed to read from stream '", stream_key, "': ", err)
            return release_and_exit(red, 500, "Error reading from tunnel")
        end

        if not result or result == ngx.null then
            -- No new messages
            return release_and_exit(red, 204, nil) -- No Content
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
        ngx.print("Error reading from tunnel")
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
    local tunnel_id = get_validated_tunnel_id()
    local use_pending = ngx.req.get_uri_args().pending ~= nil

    return read_message(tunnel_id, 0, use_pending)
end

-- GET messages using long polling
function _M.poll_message()
    local tunnel_id = get_validated_tunnel_id()
    local use_pending = ngx.req.get_uri_args().pending ~= nil

    -- Get timeout in seconds
    local timeout = tonumber(ngx.req.get_uri_args().timeout) or tunnel_config.def_poll_timeout
    if timeout > tunnel_config.max_poll_timeout then
        timeout = tunnel_config.max_poll_timeout
    end

    return read_message(tunnel_id, timeout, use_pending)
end

-- DELETE a message from a tunnel (acknowledge)
function _M.ack_message()
    local tunnel_id = get_validated_tunnel_id()
    local msg_id = get_validated_message_id()

    local red = get_redis_connection()

    local stream_key = get_stream_key(tunnel_id)
    local group_name = get_consumer_group(tunnel_id)

    -- Acknowledge the message
    local res, err = red:xack(stream_key, group_name, msg_id)
    if err then
        ngx.log(ngx.ERR, "Failed to acknowledge '", stream_key, "' id ", msg_id, ": ", err)
        return release_and_exit(red, 500, "Failed to acknowledge message")
    end

    -- Delete acknowledged message from stream
    local res, err = red:xdel(stream_key, msg_id)
    if err then
        ngx.log(ngx.ERR, "Failed to delete from stream '", stream_key, "' id ", msg_id, ": ", err)
       return release_and_exit(red, 500, "Failed to acknowledge message")
    end

    return release_and_exit(red, 204, nil) -- No Content
end

-- POST message reply
function _M.post_reply()
    local tunnel_id = get_validated_tunnel_id()
    local msg_id = get_validated_message_id()

    local red = get_redis_connection()

    local stream_key = get_stream_key(tunnel_id)
    local group_name = get_consumer_group(tunnel_id)
    local consumer_id = get_consumer_id(tunnel_id)
    local reply_key = get_reply_key(tunnel_id, msg_id)
    local reply_type_key = get_reply_type_key(tunnel_id, msg_id)

    local res_pending, err = red:xpending(stream_key, group_name, msg_id, msg_id, 1, consumer_id)
    local no_tunnel = err and string.sub(err,1,7) == "NOGROUP"
    if err and not no_tunnel then
        ngx.log(ngx.ERR, "Failed to get pending from stream '", stream_key, "' id ", msg_id, ": ", err)
        return release_and_exit(red, 500, "Failed to get pending message")
    end
    if not res_pending or not next(res_pending) then
        return release_and_exit(red, 204, nil) -- No Content
    end

    local body = utils.get_request_body()
    local content_type = ngx.req.get_headers()["Content-Type"]

    local commands = {
        {"xack", stream_key, group_name, msg_id},
        {"xdel", stream_key, msg_id},
        {"rpush", reply_key, body},
        {"expire", reply_key, tunnel_config.reply_ttl},
    }
    if content_type then
        table.insert(commands, {"set", reply_type_key, content_type})
        table.insert(commands, {"expire", reply_type_key, tunnel_config.reply_ttl})
    end
    local res, err, closed = redis_conn.multi_exec(red, commands)
    if err then
        if closed then
            red = nil
        end
        return release_and_exit(red, 500, "Failed to send reply")
    end

    return release_and_exit(red, 201, nil) -- Created
end

-- GET message reply (non-blocking)
function _M.get_reply()
    local tunnel_id = get_validated_tunnel_id()
    local msg_id = get_validated_message_id()

    local red = get_redis_connection()

    local reply_key = get_reply_key(tunnel_id, msg_id)
    local reply_type_key = get_reply_type_key(tunnel_id, msg_id)

    local res, err = red:rpop(reply_key)
    if err then
        ngx.log(ngx.ERR, "Failed to pop reply '", reply_key, "': ", err)
        return release_and_exit(red, 500, "Failed to read reply")
    end

    if res == nil or res == ngx.null then
        return release_and_exit(red, 204, nil) -- No Content
    end

    local content_type, err = red:getdel(reply_type_key)
    if err then
        ngx.log(ngx.ERR, "Failed to get reply type '", reply_key, "': ", err)
    end
    if content_type == ngx.null then
        content_type = nil
    end

    redis_conn.release_connection(red)

    local content_body = res
    ngx.status = 200
    ngx.header["Content-Type"] = content_type or tunnel_config.def_content_type
    ngx.header["Content-Length"] = #content_body
    ngx.print(content_body)
    return ngx.exit(200)
end

-- GET message reply (long polling)
function _M.poll_reply()
    
    -- Get timeout in seconds
    local timeout = tonumber(ngx.req.get_uri_args().timeout) or tunnel_config.def_poll_timeout
    if timeout > tunnel_config.max_poll_timeout then
        timeout = tunnel_config.max_poll_timeout
    end

    local tunnel_id = get_validated_tunnel_id()
    local msg_id = get_validated_message_id()

    local red = get_redis_connection()

    local reply_key = get_reply_key(tunnel_id, msg_id)
    local reply_type_key = get_reply_type_key(tunnel_id, msg_id)

    red:set_timeout((timeout * 1000) + 1000)
    local res, err = red:brpop(reply_key, timeout)
    if err then
        ngx.log(ngx.ERR, "Failed to pop reply '", reply_key, "' (blocking): ", err)
        return release_and_exit(red, 500, "Failed to read reply")
    end

    if not res or res == ngx.null or not next(res) then
        return release_and_exit(red, 204, nil) -- No Content
    end

    local content_type, err = red:getdel(reply_type_key)
    if err then
        ngx.log(ngx.ERR, "Failed to get reply type '", reply_key, "': ", err)
    end
    if content_type == ngx.null then
        content_type = nil
    end

    redis_conn.release_connection(red)

    local content_body = res[2]
    ngx.status = 200
    ngx.header["Content-Type"] = content_type or tunnel_config.def_content_type
    ngx.header["Content-Length"] = #content_body
    ngx.print(content_body)
    return ngx.exit(200)
end

-- GET message status
function _M.get_msg_status()
    local tunnel_id = get_validated_tunnel_id()
    local msg_id = get_validated_message_id()

    local red = get_redis_connection()

    local stream_key = get_stream_key(tunnel_id)
    local group_name = get_consumer_group(tunnel_id)
    local consumer_id = get_consumer_id(tunnel_id)

    local res_pending, err = red:xpending(stream_key, group_name, msg_id, msg_id, 1, consumer_id)
    local no_tunnel = err and string.sub(err,1,7) == "NOGROUP"
    if err and not no_tunnel then
        ngx.log(ngx.ERR, "Failed to get pending from stream '", stream_key, "' id ", msg_id, ": ", err)
        return release_and_exit(red, 500, "Failed to get pending message")
    end
    if res_pending and next(res_pending) then
        return release_and_exit(red, 202, nil) -- Accepted
    end

    local res_range, err = red:xrange(stream_key, msg_id, msg_id, 'COUNT', 1)
    if err then
        ngx.log(ngx.ERR, "Failed to check stream '", stream_key, "' message '", msg_id, "': ", err)
        return release_and_exit(red, 500, "Failed to get queued message")
    end

    if res_range and next(res_range) then
        return release_and_exit(red, 201, nil) -- Created
    end

    return release_and_exit(red, 204, nil) -- No Content
end

-- GET queue length for the tunnel
function _M.get_length()
    local tunnel_id = get_validated_tunnel_id()

    local red = get_redis_connection()

    local stream_key = get_stream_key(tunnel_id)

    local len, err = red:xlen(stream_key)

    if err then
        ngx.log(ngx.ERR, "Failed to get stream length '", stream_key, "': ", err)
        return release_and_exit(red, 500, "Failed to get stream length")
    end

    -- Return the length
    ngx.header["X-Queue-Size"] = len
    return release_and_exit(red, 204, nil) -- No Content
end

-- DELETE tunnel to clean the queue
function _M.clean_queue()
    local tunnel_id = get_validated_tunnel_id()

    local red = get_redis_connection()

    local stream_key = get_stream_key(tunnel_id)

    local res, err = red:del(stream_key)
    if err then
        ngx.log(ngx.ERR, "Failed to delete stream '", stream_key, "': ", err)
        return release_and_exit(red, 500, "Error cleaning the queue")
    end

    ngx.header["X-Queue-Size"] = 0
    return release_and_exit(red, 204, nil) -- No Content
end

return _M
