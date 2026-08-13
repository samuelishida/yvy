-- test_server_response.lua — status-line construction in send_response
--
-- Regression test for the TI/UC overlay crash: send_response built the status
-- line as `"HTTP/1.1 " .. status .. " " .. ({...})[status] or "Unknown"`. In
-- Lua, `..` binds tighter than `or`, so a status missing from the map (e.g.
-- 304) concatenated `nil` and raised before the fallback could apply — the
-- handler died and the browser got ERR_EMPTY_RESPONSE on ETag revalidation.
--
-- send_response is exported as _M.send_response (test-only) so we can exercise
-- it with a fake socket that captures the written bytes.

local server = require("app.server")

-- Fake socket capturing bytes written to skt:send(...).
local function fake_socket()
    local buf = {}
    return {
        sent = buf,
        send = function(_, data) buf[#buf + 1] = data end,
    }
end

local function first_line(bytes)
    local joined = table.concat(bytes, "")
    return joined:match("^([^\r\n]+)")
end

describe("send_response status line", function()
    it("returns 304 Not Modified without raising", function()
        local skt = fake_socket()
        assert.has_no.errors(function()
            server.send_response(skt, 304, "", "application/json", {})
        end)
        assert.is_equal("HTTP/1.1 304 Not Modified", first_line(skt.sent))
    end)

    it("falls back to Unknown for a status missing from the map", function()
        local skt = fake_socket()
        assert.has_no.errors(function()
            server.send_response(skt, 418, "", "application/json", {})
        end)
        assert.is_equal("HTTP/1.1 418 Unknown", first_line(skt.sent))
    end)

    it("keeps known statuses intact", function()
        local skt = fake_socket()
        server.send_response(skt, 200, "{}", "application/json", {})
        assert.is_equal("HTTP/1.1 200 OK", first_line(skt.sent))
    end)
end)
