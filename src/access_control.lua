local hmac = require "resty.hmac"
local str = require "resty.string"
local utils = require "utils"

local CRED_MAX_LEN = 1024

-- Performs a safe string comparison to protect against time-based attacks. Time depends on an external string length.
-- Returns true if strings are equal, false otherwise.
local function cred_compare(internal_str, external_str)
    if type(internal_str) ~= "string" or type(external_str) ~= "string" then
        return false
    end

    local internal_len = #internal_str
    local external_len = #external_str

    -- Shortcut only if one of the strings are empty
    if internal_len == 0 or external_len == 0 then
        return internal_len == external_len
    end

    local comp_len = math.min(external_len, CRED_MAX_LEN)
    local diff = 0
    for i = 1, comp_len do
        local internal_pos = i % internal_len
        if internal_pos == 0 then
            internal_pos = internal_len
        end
        -- XOR corresponding bytes and OR with accumulated diff
        diff = bit.bor(diff, bit.bxor(string.byte(external_str, i), string.byte(internal_str, internal_pos)))
    end

    if internal_len ~= external_len then
        return false
    end

    -- If diff is 0, all bytes were identical.
    return diff == 0
end

local function check_token()
    if not tunnel_config.token then
        return false
    end

    local auth_header = ngx.var.http_Authorization
    if auth_header then
        _, _, token = string.find(auth_header, "Bearer%s+(.+)")
    end

    return token and cred_compare(tunnel_config.token, token)
end

local function check_signature()
    if not tunnel_config.sig_secret then
        return false
    end

    local github_header = ngx.req.get_headers()["X-Hub-Signature-256"]
    if github_header then
        _, _, algo, request_sig = string.find(github_header, "(.+)=(.+)")
    end
    if not request_sig then
        return false
    end
    if algo ~= "sha256" then
        ngx.log(ngx.err, "Unsupported signature algo: ", algo)
        return false
    end

    local request_body = utils.get_request_body()
    if not request_body or #request_body == 0 then
        return false
    end

    local hmac_inst = hmac:new(tunnel_config.sig_secret, hmac.ALGOS.SHA256)
    if not hmac_inst then
        ngx.log(ngx.err, "Failed to create hmac instance")
        return false
    end

    local ok = hmac_inst:update(request_body)
    if not ok then
        ngx.log(ngx.err, "Failed to update hmac instance with request data")
        return
    end

    local mac = hmac_inst:final()
    local actual_sig = str.to_hex(mac)

    if not hmac_inst:reset() then
        ngx.log(ngx.err, "Failed to reset hmac instance")
    end

    local is_valid = actual_sig and cred_compare(actual_sig, request_sig)
    if is_valid then
        -- Save loaded body to request context
        ngx.ctx.validated_body = request_body
    end

    return is_valid
end

-- Module

local _M = {}

function _M.is_public_tunnel(tunnel_id)
    return tunnel_config.public_ids and tunnel_config.public_ids[tunnel_id]
end

function _M.ensure_access()
    if not tunnel_config.token and not tunnel_config.sig_secret and not tunnel_config.public_ids then
        -- No auth methods configured, run unprotected
        return
    end

    if check_token() then
        return
    end
    if check_signature() then
        return
    end

    ngx.status = 403
    ngx.print("Access denied")
    return ngx.exit(403)
end

return _M
