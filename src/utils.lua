
local _M = {}

function _M.get_request_body()
    if ngx.ctx.validated_body ~= nil then
        return ngx.ctx.validated_body
    end

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

    return body or ""
end

return _M
