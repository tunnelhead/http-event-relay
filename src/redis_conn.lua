local redis = require "resty.redis"

local _M = {}

function _M.get_connection()
    local red = redis:new()
    red:set_timeout(1000) -- 1 second timeout

    -- Connect to Redis
    local ok, err = red:connect(redis_config.host, redis_config.port)
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to Redis at '", red_host, ":", red_port, "': ", err)
        return nil, err
    end

    -- Authentication (if needed)
    if redis_config.password then
        local auth_ok, auth_err = red:auth(redis_config.password)
        if not auth_ok then
            ngx.log(ngx.ERR, "Failed to authenticate with Redis: ", auth_err)
            return nil, auth_err
        end
    end

    return red
end

function _M.release_connection(red)
    if not red then return end

    if redis_config.pool_size > 0 then
        -- Put connection back to connection pool
        local ok, err = red:set_keepalive(redis_config.pool_keepalive * 1000, redis_config.pool_size)
        if not ok then
            ngx.log(ngx.ERR, "Failed to set keepalive on redis connection: ", err)
        end
    else
        -- Close the connection right away
        local ok, err = red:close()
        if not ok then
            ngx.log(ngx.ERR, "Failed to close redis connection: ", err)
            return
        end
    end
end

function _M.multi_exec(red, commands)
    local ok, err = red:multi()
    if not ok then
        ngx.log(ngx.ERR, "Failed to run multi: ", err)
        return nil, err
    end

    for i, args in pairs(commands) do
        local cmd = table.remove(args, 1)
        local status_queue, err_queue = red[cmd](red, unpack(args))
        if not status_queue or status_queue ~= "QUEUED" then
            local err = "Failed to queue command " .. cmd .. ": " .. (err_queue or ("status was " .. tostring(status_queue)))
            ngx.log(ngx.ERR, err)

            -- If a command fails to queue, discard the transaction
            local ok_discard, err_discard = red:discard()
            if not ok_discard then
                ngx.log(ngx.ERR, "Failed to discard transaction after queue error: ", err_discard)
                -- Try to close the connection, as we can't use it with something still queued
                local ok_close, err_close = red:close()
                if not ok_close then
                    ngx.log(ngx.ERR, "Failed to close redis connection: ", err_close)
                end
                return nil, err, true
            end

            return nil, err
        end
    end

    local res, err = red:exec()
    if err then
        ngx.log(ngx.ERR, "Failed to run exec: ", err)
        return nil, err
    end
    return res
end

return _M
