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

return _M
