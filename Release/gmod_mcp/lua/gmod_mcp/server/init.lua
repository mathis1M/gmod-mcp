GModMCP = GModMCP or {}

local gmod_mcp = GModMCP
local bridge = gmod_mcp_bridge

include("gmod_mcp/server/tools/screenshot.lua")
include("gmod_mcp/server/tools/exec_lua_code.lua")

local status_sent, status_error = pcall(
    bridge.set_status,
    true,
    "Garry's Mod is connected."
)

if not status_sent then
    ErrorNoHalt("[gmod-mcp] failed to send status: " .. tostring(status_error) .. "\n")
end

local function poll_commands()
    local poll_ok, command = pcall(bridge.poll_command)
    if not poll_ok then
        ErrorNoHalt("[gmod-mcp] failed to poll command: " .. tostring(command) .. "\n")
        return
    end
    if command == nil then
        return
    end

    local execute_ok, execute_error = pcall(gmod_mcp.execute_command, command)
    if not execute_ok then
        ErrorNoHalt("[gmod-mcp] command failed: " .. tostring(execute_error) .. "\n")
    end
end

timer.Create("gmod_mcp_command_poll", 0.1, 0, poll_commands) // au lieu de faire un hook think, à voir si c'est une bonne solu, vitroze ou léo je compte sur vous pour me mentionner et me dire des choses très méchantes si c'est pas bien

hook.Add("ShutDown", "gmod_mcp_bridge_shutdown", function()
    timer.Remove("gmod_mcp_command_poll")
    local shutdown_sent, shutdown_error = pcall(bridge.shutdown)
    if not shutdown_sent then
        ErrorNoHalt("[gmod-mcp] failed to stop bridge: " .. tostring(shutdown_error) .. "\n")
    end
end)
