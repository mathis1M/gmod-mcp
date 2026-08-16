local EXEC_NETWORK_MESSAGE = "gmod_mcp_exec_lua_code"
local EXEC_RESULT_MESSAGE = "gmod_mcp_exec_lua_result"

local function encode_result(value)
    return util.TableToJSON({value = value}, false, true)
end

local function send_result(request_id, ok, payload)
    if not request_id or request_id == "" then
        return
    end
    if ok then
        payload = encode_result(payload)
        if not isstring(payload) then
            ok = false
            payload = "Lua result is not JSON serializable."
        end
    end
    net.Start(EXEC_RESULT_MESSAGE)
    net.WriteString(request_id)
    net.WriteBool(ok)
    net.WriteString(payload or "")
    net.SendToServer()
end

local function execute_lua_code(code, request_id)
    local compile_ok, compiled = pcall(CompileString, code, "gmod_mcp:client", false)
    if not compile_ok then
        ErrorNoHalt("[gmod-mcp] client Lua compilation failed: " .. tostring(compiled) .. "\n")
        send_result(request_id, false, tostring(compiled))
        return
    end
    if isstring(compiled) then
        ErrorNoHalt("[gmod-mcp] client Lua compilation failed: " .. compiled .. "\n")
        send_result(request_id, false, compiled)
        return
    end
    if not isfunction(compiled) then
        ErrorNoHalt("[gmod-mcp] client Lua compiler returned an invalid chunk\n")
        send_result(request_id, false, "Lua compiler returned an invalid chunk.")
        return
    end

    local previous_return = GModMCP.return_result
    local result_sent = false
    if request_id ~= "" then
        GModMCP.return_result = function(value)
            if result_sent then
                return
            end
            result_sent = true
            send_result(request_id, true, value)
        end
    end

    local run_ok, run_error = pcall(compiled)
    if not run_ok then
        ErrorNoHalt("[gmod-mcp] client Lua execution failed: " .. tostring(run_error) .. "\n")
        if request_id ~= "" and not result_sent then
            result_sent = true
            send_result(request_id, false, tostring(run_error))
        end
        if request_id ~= "" then
            GModMCP.return_result = previous_return
        end
        return
    end
    if request_id ~= "" and run_error ~= nil and not result_sent then
        result_sent = true
        send_result(request_id, true, run_error)
    end
    if request_id ~= "" then
        GModMCP.return_result = previous_return
    end
end

net.Receive(EXEC_NETWORK_MESSAGE, function()
    execute_lua_code(net.ReadString(), net.ReadString())
end)
