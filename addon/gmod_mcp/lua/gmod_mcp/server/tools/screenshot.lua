local gmod_mcp = GModMCP
local bridge = gmod_mcp_bridge

local REQUEST_MESSAGE = "gmod_mcp_screenshot_request"
local CHUNK_MESSAGE = "gmod_mcp_screenshot_chunk"
local CHUNK_BYTES = 24 * 1024
local MAX_SCREENSHOT_BYTES = 1024 * 1024
local MAX_CHUNKS = math.ceil(MAX_SCREENSHOT_BYTES / CHUNK_BYTES)
local SCREENSHOT_TIMEOUT = 10

local pending = {}

util.AddNetworkString(REQUEST_MESSAGE)
util.AddNetworkString(CHUNK_MESSAGE)

local function report(request_id, ok, payload)
    local reported, report_error = pcall(bridge.respond_screenshot, request_id, ok, payload)
    if not reported then
        ErrorNoHalt("[gmod-mcp] screenshot response failed: " .. tostring(report_error) .. "\n")
    end
end

local function complete(request_id, ok, payload)
    if pending[request_id] == nil then
        return
    end

    pending[request_id] = nil
    report(request_id, ok, payload)
end

function gmod_mcp.request_screenshot(command)
    local request_id = command.request_id
    if not isstring(request_id) or request_id == "" then
        error("screenshot request is missing its id")
    end

    local player, resolve_error = gmod_mcp.resolve_player(command.target)
    if not IsValid(player) then
        report(request_id, false, resolve_error)
        return
    end

    pending[request_id] = {
        player = player,
        chunks = {},
        next_chunk = 1,
        bytes = 0,
    }

    net.Start(REQUEST_MESSAGE)
    net.WriteString(request_id)
    net.Send(player)

    timer.Simple(SCREENSHOT_TIMEOUT, function()
        complete(request_id, false, "Screenshot timed out.")
    end)
end

net.Receive(CHUNK_MESSAGE, function(_, player)
    local request_id = net.ReadString()
    local ok = net.ReadBool()
    local request = pending[request_id]
    if request == nil or request.player ~= player then
        return
    end

    if not ok then
        complete(request_id, false, net.ReadString())
        return
    end

    local chunk_index = net.ReadUInt(16)
    local chunk_count = net.ReadUInt(16)
    local chunk_size = net.ReadUInt(16)
    local chunk = net.ReadData(chunk_size)

    if chunk_count < 1
        or chunk_count > MAX_CHUNKS
        or chunk_index ~= request.next_chunk
        or (request.chunk_count ~= nil and chunk_count ~= request.chunk_count)
        or chunk_size < 1
        or chunk_size > CHUNK_BYTES
        or request.bytes + #chunk > MAX_SCREENSHOT_BYTES then
        complete(request_id, false, "Invalid screenshot data.")
        return
    end

    request.chunk_count = chunk_count
    request.chunks[chunk_index] = chunk
    request.next_chunk = chunk_index + 1
    request.bytes = request.bytes + #chunk

    if chunk_index == chunk_count then
        complete(request_id, true, table.concat(request.chunks))
    end
end)
