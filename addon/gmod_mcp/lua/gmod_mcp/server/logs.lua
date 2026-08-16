local gmod_mcp = GModMCP

local LOG_DIRECTORY = "gmod_mcp"
local LOG_FILE = LOG_DIRECTORY .. "/logs.json"
local MAX_LOGS = 100

local REQUEST_LOGS_MESSAGE = "gmod_mcp_request_logs"
local LOGS_BEGIN_MESSAGE = "gmod_mcp_logs_begin"
local LOG_ENTRY_MESSAGE = "gmod_mcp_log_entry"
local LOGS_DENIED_MESSAGE = "gmod_mcp_logs_denied"
local CLOSE_LOGS_MESSAGE = "gmod_mcp_close_logs"

local logs = {}
local viewers = {}

util.AddNetworkString(REQUEST_LOGS_MESSAGE)
util.AddNetworkString(LOGS_BEGIN_MESSAGE)
util.AddNetworkString(LOG_ENTRY_MESSAGE)
util.AddNetworkString(LOGS_DENIED_MESSAGE)
util.AddNetworkString(CLOSE_LOGS_MESSAGE)

local function can_view_logs(player)
    return IsValid(player) and player:IsPlayer() and player:IsSuperAdmin()
end

local function persist_logs()
    local encoded = util.TableToJSON(logs, false) or "[]"
    file.Write(LOG_FILE, encoded)
end

local function load_logs()
    local content = file.Read(LOG_FILE, "DATA")
    local decoded = content and util.JSONToTable(content)

    if istable(decoded) then
        logs = decoded
    else
        logs = {}
    end

    return logs
end

local function write_log_entry(entry)
    net.WriteString(tostring(entry.tool or "unknown"))
    net.WriteUInt(math.max(0, math.floor(tonumber(entry.timestamp) or 0)), 32)
    net.WriteString(tostring(entry.state or ""))
    net.WriteString(tostring(entry.target or ""))
    net.WriteString(tostring(entry.payload or ""))
end

local function send_log_entry(player, entry)
    net.Start(LOG_ENTRY_MESSAGE)
    write_log_entry(entry)
    net.Send(player)
end

local function send_logs(player)
    local stored_logs = load_logs()

    net.Start(LOGS_BEGIN_MESSAGE)
    net.WriteUInt(math.min(#stored_logs, MAX_LOGS), 8)
    net.Send(player)

    for _, entry in ipairs(stored_logs) do
        send_log_entry(player, entry)
    end
end

local function deny_logs(player)
    net.Start(LOGS_DENIED_MESSAGE)
    net.Send(player)
end

function gmod_mcp.reset_logs()
    file.CreateDir(LOG_DIRECTORY)
    logs = {}
    persist_logs()
end

function gmod_mcp.open_logs(player)
    if not can_view_logs(player) then
        deny_logs(player)
        return false
    end

    viewers[player] = true
    send_logs(player)
    return true
end

function gmod_mcp.log_tool(tool, command)
    local entry = {
        tool = tool,
        timestamp = os.time(),
        state = command.state,
        target = command.target,
        payload = command.code,
    }

    logs[#logs + 1] = entry
    if #logs > MAX_LOGS then
        table.remove(logs, 1)
    end

    persist_logs()

    for player in pairs(viewers) do
        if can_view_logs(player) then
            send_log_entry(player, entry)
        else
            viewers[player] = nil
        end
    end
end

net.Receive(REQUEST_LOGS_MESSAGE, function(_, player)
    gmod_mcp.open_logs(player)
end)

net.Receive(CLOSE_LOGS_MESSAGE, function(_, player)
    viewers[player] = nil
end)

hook.Add("PlayerSay", "gmod_mcp_open_chat", function(player, text)
    if string.lower(string.Trim(text)) ~= "!mcp" then
        return
    end

    gmod_mcp.open_logs(player)
    return ""
end)

hook.Add("PlayerDisconnected", "gmod_mcp_remove_log_viewer", function(player)
    viewers[player] = nil
end)

