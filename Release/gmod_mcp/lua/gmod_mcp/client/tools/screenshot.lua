local REQUEST_MESSAGE = "gmod_mcp_screenshot_request"
local CHUNK_MESSAGE = "gmod_mcp_screenshot_chunk"
local CHUNK_BYTES = 24 * 1024
local MAX_SCREENSHOT_BYTES = 1024 * 1024
local CHUNK_DELAY = 0.1


local pending = {}

local function send_error(request_id, message)
    net.Start(CHUNK_MESSAGE)
    net.WriteString(request_id)
    net.WriteBool(false)
    net.WriteString(message)
    net.SendToServer()
end

local function send_screenshot(request_id, data)
    local chunk_count = math.ceil(#data / CHUNK_BYTES)
    local chunk_index = 1

    local function send_next()
        local first_byte = (chunk_index - 1) * CHUNK_BYTES + 1
        local chunk = string.sub(data, first_byte, first_byte + CHUNK_BYTES - 1)

        net.Start(CHUNK_MESSAGE)
        net.WriteString(request_id)
        net.WriteBool(true)
        net.WriteUInt(chunk_index, 16)
        net.WriteUInt(chunk_count, 16)
        net.WriteUInt(#chunk, 16)
        net.WriteData(chunk, #chunk)
        net.SendToServer()

        chunk_index = chunk_index + 1
        if chunk_index <= chunk_count then
            timer.Simple(CHUNK_DELAY, send_next)
        end
    end

    send_next()
end

hook.Add("PostRender", "gmod_mcp_screenshot", function()
    local request_id = table.remove(pending, 1)
    if request_id == nil then
        return
    end

    local data = render.Capture({
        format = "jpeg",
        quality = 45,
        x = 0,
        y = 0,
        w = ScrW(),
        h = ScrH(),
    })
    if not isstring(data) or #data == 0 then
        send_error(request_id, "GMod cannot capture while the Escape menu is open.")
        return
    end
    if #data > MAX_SCREENSHOT_BYTES then
        send_error(request_id, "Screenshot exceeds the 1 MiB transfer limit.")
        return
    end

    send_screenshot(request_id, data)
end)

net.Receive(REQUEST_MESSAGE, function()
    local request_id = net.ReadString()
    if not isstring(request_id) or request_id == "" then
        return
    end

    if gui.IsGameUIVisible() then
        send_error(request_id, "GMod cannot capture while the Escape menu is open.")
        return
    end

    pending[#pending + 1] = request_id
end)
