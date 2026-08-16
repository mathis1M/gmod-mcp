AddCSLuaFile("autorun/client/gmod_mcp.lua")
AddCSLuaFile("gmod_mcp/client/init.lua")
AddCSLuaFile("gmod_mcp/client/tools/exec_lua_code.lua")
AddCSLuaFile("gmod_mcp/client/tools/screenshot.lua")
AddCSLuaFile("gmod_mcp/client/ui.lua")

GModMCP = GModMCP or {}
include("gmod_mcp/server/logs.lua")
GModMCP.reset_logs()

local loaded, error_message = pcall(require, "gmod_mcp_bridge")

if not loaded then
    ErrorNoHalt("[gmod-mcp] failed to load gmod_mcp_bridge: " .. tostring(error_message) .. "\n")
elseif not istable(gmod_mcp_bridge)
    or not isfunction(gmod_mcp_bridge.set_status)
    or not isfunction(gmod_mcp_bridge.poll_command)
    or not isfunction(gmod_mcp_bridge.shutdown)
    or not isfunction(gmod_mcp_bridge.respond_lua) then
    ErrorNoHalt("[gmod-mcp] native bridge API is unavailable\n")
else
    include("gmod_mcp/server/init.lua")
end
