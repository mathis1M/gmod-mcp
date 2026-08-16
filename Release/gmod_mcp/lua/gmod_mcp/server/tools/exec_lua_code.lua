local gmod_mcp = GModMCP
local bridge = gmod_mcp_bridge
local EXEC_NETWORK_MESSAGE = "gmod_mcp_exec_lua_code"
local EXEC_RESULT_MESSAGE = "gmod_mcp_exec_lua_result"
local EXEC_RESULT_TIMEOUT = 10
local pending_results = {}

util.AddNetworkString(EXEC_NETWORK_MESSAGE)
util.AddNetworkString(EXEC_RESULT_MESSAGE)

local function encode_result(value)
    return util.TableToJSON({value = value}, false, true)
end

local function respond_encoded_result(request_id, ok, payload)
    if not request_id then
        return false
    end
    local reported, report_error = pcall(bridge.respond_lua, request_id, ok, payload)
    if not reported then
        ErrorNoHalt("[gmod-mcp] Lua result response failed: " .. tostring(report_error) .. "\n")
    end
    return true
end

function gmod_mcp.respond_result(request_id, ok, payload)
    if ok then
        payload = encode_result(payload)
        if not isstring(payload) then
            ok = false
            payload = "Lua result is not JSON serializable."
        end
    end
    return respond_encoded_result(request_id, ok, payload)
end

local function compile_and_run(code, identifier, request_id)
    local compile_ok, compiled = pcall(CompileString, code, identifier, false)
    if not compile_ok then
        gmod_mcp.respond_result(request_id, false, tostring(compiled))
        return false, compiled
    end
    if isstring(compiled) then
        gmod_mcp.respond_result(request_id, false, compiled)
        return false, compiled
    end
    if not isfunction(compiled) then
        gmod_mcp.respond_result(request_id, false, "Lua compiler returned an invalid chunk.")
        return false, "Lua compiler returned an invalid chunk."
    end

    local previous_return = gmod_mcp.return_result
    local result_sent = false
    if request_id then
        gmod_mcp.return_result = function(value)
            if result_sent then
                return
            end
            result_sent = true
            gmod_mcp.respond_result(request_id, true, value)
        end
    end

    local run_ok, run_error = pcall(compiled)
    if not run_ok then
        if request_id and not result_sent then
            result_sent = true
            gmod_mcp.respond_result(request_id, false, tostring(run_error))
        end
        if request_id then
            gmod_mcp.return_result = previous_return
        end
        return false, run_error
    end
    if request_id and run_error ~= nil and not result_sent then
        result_sent = true
        gmod_mcp.respond_result(request_id, true, run_error)
    end
    if request_id then
        gmod_mcp.return_result = previous_return
    end
    return true
end

local function position(vector)
    return {x = vector.x, y = vector.y, z = vector.z}
end

local function active_weapon_class(player)
    local weapon = player:GetActiveWeapon()
    return IsValid(weapon) and weapon:GetClass() or nil
end

function gmod_mcp.get_players()
    local players = {}
    for _, player in ipairs(player.GetAll()) do
        if IsValid(player) then
            players[#players + 1] = {
                name = player:Nick(),
                steam_id = player:SteamID(),
                steam_id64 = player:SteamID64(),
                team = team.GetName(player:Team()),
                team_id = player:Team(),
                alive = player:Alive(),
                health = player:Health(),
                armor = player:Armor(),
                position = position(player:GetPos()),
                model = player:GetModel(),
                weapon = active_weapon_class(player),
            }
        end
    end
    return players
end

function gmod_mcp.get_entities(class_filter, custom_check, limit)
    local entities, truncated = {}, false
    local filter = class_filter and string.lower(class_filter) or nil
    local check
    if custom_check then
        local compiled = CompileString("return function(entity)\n" .. custom_check .. "\nend", "gmod_mcp:customCheck", false)
        if isstring(compiled) then
            error("customCheck compilation failed: " .. compiled)
        end
        local ok, result = pcall(compiled)
        if not ok or not isfunction(result) then
            error("customCheck must compile to a Lua function: " .. tostring(result))
        end
        check = result
    end
    for _, entity in ipairs(ents.GetAll()) do
        if IsValid(entity) and not entity:IsPlayer() then
            local class = entity:GetClass()
            if not filter or string.find(string.lower(class), filter, 1, true) then
                if check then
                    local ok, matches = pcall(check, entity)
                    if not ok then error("customCheck failed: " .. tostring(matches)) end
                    if matches ~= true then continue end
                end
                if #entities == limit then
                    truncated = true
                    break
                end
                entities[#entities + 1] = {
                    index = entity:EntIndex(),
                    class = class,
                    model = entity:GetModel(),
                    position = position(entity:GetPos()),
                }
            end
        end
    end
    return {entities = entities, truncated = truncated}
end

function gmod_mcp.resolve_player(target)
    local normalized_target = string.Trim(target)
    local lowered_target = string.lower(normalized_target)
    local matches = {}

    for _, player in ipairs(player.GetAll()) do
        if string.lower(player:Nick()) == lowered_target
            or player:SteamID() == normalized_target
            or player:SteamID64() == normalized_target then
            matches[#matches + 1] = player
        end
    end

    if #matches == 1 then
        return matches[1]
    end
    if #matches > 1 then
        return nil, "client target matches multiple players; use SteamID64."
    end
    return nil, "no connected player matches client target " .. normalized_target .. "."
end

local function send_to_clients(code, target, request_id)
    local lowered_target = string.lower(string.Trim(target))

    if lowered_target == "all" or lowered_target == "tout le monde" then
        net.Start(EXEC_NETWORK_MESSAGE)
        net.WriteString(code)
        net.WriteString(request_id or "")
        net.Broadcast()
        return true
    end

    local player, resolve_error = gmod_mcp.resolve_player(target)
    if not IsValid(player) then
        return false, resolve_error
    end

    if request_id then
        pending_results[request_id] = player
        timer.Simple(EXEC_RESULT_TIMEOUT, function()
            if pending_results[request_id] == player then
                pending_results[request_id] = nil
            end
        end)
    end
    net.Start(EXEC_NETWORK_MESSAGE)
    net.WriteString(code)
    net.WriteString(request_id or "")
    net.Send(player)
    return true
end

function gmod_mcp.execute_command(command)
    if not istable(command) or not isstring(command.state) or not isstring(command.code) then
        error("invalid exec_lua_code command")
    end

    local tool = command.tool or "exec_lua_code"
    if tool == "gmod_status" then
        gmod_mcp.log_tool(tool, command)
        return
    end

    if tool == "screenshot" then
        if command.state ~= "client" or not isstring(command.target) or string.Trim(command.target) == "" then
            error("screenshot requires one client target")
        end
        gmod_mcp.log_tool(tool, command)
        gmod_mcp.request_screenshot(command)
        return
    end

    if tool == "gmod_players" then
        gmod_mcp.log_tool(tool, command)
        gmod_mcp.respond_result(command.request_id, true, gmod_mcp.get_players())
        return
    end

    if tool == "gmod_entities" then
        gmod_mcp.log_tool(tool, command)
        gmod_mcp.respond_result(
            command.request_id,
            true,
            gmod_mcp.get_entities(command.class_filter, command.custom_check, command.limit)
        )
        return
    end

    if tool ~= "exec_lua_code" then
        error("unknown MCP tool " .. tostring(tool))
    end

    gmod_mcp.log_tool(tool, command)

    if command.state == "server" then
        local executed, execute_error = compile_and_run(
            command.code,
            "gmod_mcp:server",
            command.request_id
        )
        if not executed then
            ErrorNoHalt("[gmod-mcp] server Lua execution failed: " .. tostring(execute_error) .. "\n")
        end
        return
    end

    if command.state ~= "client" or not isstring(command.target) or string.Trim(command.target) == "" then
        error("client exec_lua_code requires a target")
    end

    local sent, send_error = send_to_clients(command.code, command.target, command.request_id)
    if not sent then
        ErrorNoHalt("[gmod-mcp] client Lua execution skipped: " .. tostring(send_error) .. "\n")
    end
end

net.Receive(EXEC_RESULT_MESSAGE, function(_, player)
    local request_id = net.ReadString()
    if pending_results[request_id] ~= player then
        return
    end

    pending_results[request_id] = nil
    respond_encoded_result(request_id, net.ReadBool(), net.ReadString())
end)
