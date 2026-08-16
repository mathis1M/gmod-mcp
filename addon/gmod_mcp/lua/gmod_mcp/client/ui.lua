local REQUEST_LOGS_MESSAGE = "gmod_mcp_request_logs"
local LOGS_BEGIN_MESSAGE = "gmod_mcp_logs_begin"
local LOG_ENTRY_MESSAGE = "gmod_mcp_log_entry"
local LOGS_DENIED_MESSAGE = "gmod_mcp_logs_denied"
local CLOSE_LOGS_MESSAGE = "gmod_mcp_close_logs"
local GITHUB_URL = "https://github.com/mathis1M/gmod-mcp"

local COLOR_BACKGROUND = Color(0, 0, 0)
local COLOR_ROW = Color(34, 34, 34)
local COLOR_CODE = Color(10, 10, 10)
local COLOR_TEXT = Color(247, 241, 242)
local COLOR_MUTED = Color(187, 171, 204)
local COLOR_ACCENT = Color(211, 190, 231)
local COLOR_SELECTION = Color(78, 64, 92)
local COLOR_INVISIBLE = Color(0, 0, 0, 0)

local HEADER_HEIGHT = 48
local DETAILS_TOP = 54
local META_HEIGHT = 24
local CODE_TOP = 84

surface.CreateFont("GModMCP.Title", {
    font = "Roboto",
    size = 24,
    weight = 900,
    extended = true,
})

surface.CreateFont("GModMCP.Link", {
    font = "Roboto",
    size = 12,
    weight = 700,
    extended = true,
})

surface.CreateFont("GModMCP.Tool", {
    font = "Roboto",
    size = 18,
    weight = 800,
    extended = true,
})

surface.CreateFont("GModMCP.Time", {
    font = "Roboto",
    size = 15,
    weight = 700,
    extended = true,
})

surface.CreateFont("GModMCP.Meta", {
    font = "Roboto",
    size = 12,
    weight = 700,
    extended = true,
})

surface.CreateFont("GModMCP.Code", {
    font = "Consolas",
    size = 16,
    weight = 500,
    extended = true,
})

local menu
local rows = {}

local function time_ago(timestamp)
    local elapsed = math.max(0, os.time() - (tonumber(timestamp) or os.time()))

    if elapsed < 60 then
        return "now"
    end
    if elapsed < 3600 then
        return math.floor(elapsed / 60) .. "min ago"
    end
    if elapsed < 86400 then
        return math.floor(elapsed / 3600) .. "h ago"
    end
    return math.floor(elapsed / 86400) .. "day ago"
end

local function code_height(payload)
    local line_count = 1

    for _ in string.gmatch(payload, "\n") do
        line_count = line_count + 1
    end

    local wrapped_lines = math.ceil(math.max(#payload, 1) / 78)
    return math.Clamp(math.max(line_count, wrapped_lines) * 18 + 18, 64, 240)
end

local function create_copy_box(parent, text, font, multiline, selectable)
    local box = vgui.Create("DTextEntry", parent)
    box:SetMultiline(multiline)
    box:SetEditable(false)
    box:SetKeyboardInputEnabled(selectable)
    box:SetMouseInputEnabled(selectable)
    box:SetCursor(selectable and "ibeam" or "arrow")
    box:SetCursorColor(COLOR_INVISIBLE)
    box:SetFont(font)
    box:SetTextColor(COLOR_TEXT)
    box:SetHighlightColor(COLOR_SELECTION)
    box:SetDrawBorder(false)
    if multiline then
        box:SetVerticalScrollbarEnabled(true)
    end
    box:SetText(text)

    box.Paint = function(panel, width, height)
        draw.RoundedBox(8, 0, 0, width, height, COLOR_CODE)
        panel:DrawTextEntryText(COLOR_TEXT, COLOR_SELECTION, COLOR_INVISIBLE)
    end

    return box
end

local function draw_chevron(x, y, expanded)
    surface.SetDrawColor(COLOR_MUTED)
    local direction = expanded and -1 or 1
    draw.NoTexture()
    surface.DrawPoly({
        {x = x - 5, y = y - direction * 3},
        {x = x - 3, y = y - direction * 3},
        {x = x, y = y + direction},
        {x = x + 3, y = y - direction * 3},
        {x = x + 5, y = y - direction * 3},
        {x = x, y = y + direction * 4},
        {x = x - 1, y = y + direction * 3},
    })
end

local function reorder_rows()
    for index, row in ipairs(rows) do
        if IsValid(row) then
            row:SetZPos(index - 1)
        end
    end
end

local function create_row(entry, scroll)
    local row = vgui.Create("DPanel", scroll:GetCanvas())
    row:Dock(TOP)
    row:DockMargin(10, 8, 18, 0)
    row:SetTall(HEADER_HEIGHT)
    row.entry = entry
    row.expandable = entry.tool == "exec_lua_code"
    row.expanded = false
    row.state_box = nil
    row.target_box = nil
    row.code_box = nil
    row.code_box_height = 0

    if row.expandable then
        row:SetCursor("hand")
    end

    function row:SetExpanded(expanded)
        if not self.expandable then
            return
        end

        self.expanded = expanded

        if expanded and not IsValid(self.code_box) then
            local state = self.entry.state ~= "" and self.entry.state or "unknown"
            local target = self.entry.target ~= "" and self.entry.target or "none"
            self.state_box = create_copy_box(self, "state: " .. state, "GModMCP.Meta", false, false)
            self.target_box = create_copy_box(self, "target: " .. target, "GModMCP.Meta", false, false)
            self.code_box = create_copy_box(self, self.entry.payload or "", "GModMCP.Code", true, true)
        end

        self.code_box_height = expanded and code_height(self.entry.payload or "") or 0
        if IsValid(self.state_box) then
            self.state_box:SetVisible(expanded)
            self.target_box:SetVisible(expanded)
            self.code_box:SetVisible(expanded)
        end

        local target_height = expanded and CODE_TOP + self.code_box_height + 10 or HEADER_HEIGHT
        local row_width = math.max(self:GetWide(), scroll:GetCanvas():GetWide() - 28, 1)
        self:SizeTo(row_width, target_height, 0.18, 0, 0.2)
        self:InvalidateLayout(true)

        if expanded then
            timer.Simple(0.2, function()
                if IsValid(self) and IsValid(scroll) then
                    scroll:ScrollToChild(self)
                end
            end)
        end
    end

    row.PerformLayout = function(panel, width)
        if not IsValid(panel.state_box) then
            return
        end

        local field_width = math.max(1, (width - 48) / 2)
        panel.state_box:SetPos(20, DETAILS_TOP)
        panel.state_box:SetSize(field_width, META_HEIGHT)
        panel.target_box:SetPos(28 + field_width, DETAILS_TOP)
        panel.target_box:SetSize(field_width, META_HEIGHT)
        panel.code_box:SetPos(20, CODE_TOP)
        panel.code_box:SetSize(math.max(1, width - 40), panel.code_box_height)
    end

    row.OnMousePressed = function(panel, mouse_code)
        if panel.expandable and mouse_code == MOUSE_LEFT then
            panel:SetExpanded(not panel.expanded)
        end
    end

    row.Paint = function(panel, width, height)
        draw.RoundedBox(14, 0, 0, width, height, COLOR_ROW)

        local text_x = 24
        if panel.expandable then
            draw_chevron(28, 24, panel.expanded)
            text_x = 48
        end

        draw.SimpleText(panel.entry.tool or "unknown", "GModMCP.Tool", text_x, 24, COLOR_TEXT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        draw.SimpleText(time_ago(panel.entry.timestamp), "GModMCP.Time", width - 18, 24, COLOR_TEXT, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
    end

    table.insert(rows, 1, row)
    reorder_rows()
    return row
end

local function clear_rows()
    for _, row in ipairs(rows) do
        if IsValid(row) then
            row:Remove()
        end
    end

    rows = {}
end

local function create_menu()
    if IsValid(menu) then
        menu:MakePopup()
        return menu
    end

    local width = math.min(math.max(math.floor(ScrW() * 0.58), 480), 640)
    local height = math.min(math.max(math.floor(ScrH() * 0.62), 380), 560)

    menu = vgui.Create("DFrame")
    menu:SetSize(width, height)
    menu:Center()
    menu:SetTitle("")
    menu:ShowCloseButton(false)
    menu:SetDraggable(false)
    menu:SetDeleteOnClose(true)
    menu:MakePopup()

    menu.Paint = function(_, frame_width, frame_height)
        draw.RoundedBox(22, 0, 0, frame_width, frame_height, COLOR_BACKGROUND)
        draw.SimpleText("GMod MCP", "GModMCP.Title", frame_width / 2, 22, COLOR_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
    end

    local link = vgui.Create("DButton", menu)
    link:SetText("github.com/mathislM/gmod-mcp")
    link:SetFont("GModMCP.Link")
    link:SetTextColor(COLOR_ACCENT)
    link:SetCursor("hand")
    link.Paint = function() end
    link.DoClick = function()
        gui.OpenURL(GITHUB_URL)
    end

    local close = vgui.Create("DButton", menu)
    close:SetText("x")
    close:SetFont("GModMCP.Link")
    close:SetTextColor(COLOR_MUTED)
    close:SetCursor("hand")
    close.Paint = function() end
    close.DoClick = function()
        menu:Close()
    end

    local scroll = vgui.Create("DScrollPanel", menu)
    scroll.Paint = function(_, scroll_width, scroll_height)
        draw.RoundedBox(15, 0, 0, scroll_width, scroll_height, COLOR_BACKGROUND)
    end

    local bar = scroll:GetVBar()
    bar:SetWide(11)
    bar.Paint = function(_, bar_width, bar_height)
        draw.RoundedBox(6, 2, 0, bar_width - 4, bar_height, Color(8, 8, 8))
    end
    bar.btnUp.Paint = function() end
    bar.btnDown.Paint = function() end
    bar.btnGrip.Paint = function(_, grip_width, grip_height)
        draw.RoundedBox(6, 2, 0, grip_width - 4, grip_height, Color(52, 52, 52))
    end

    local empty = vgui.Create("DLabel", scroll:GetCanvas())
    empty:Dock(TOP)
    empty:SetTall(100)
    empty:SetText("nothing to show yet")
    empty:SetFont("GModMCP.Time")
    empty:SetTextColor(COLOR_MUTED)
    empty:SetContentAlignment(5)

    local function update_layout()
        link:SizeToContents()
        link:SetPos((width - link:GetWide()) / 2, 50)
        close:SetSize(24, 24)
        close:SetPos(width - 36, 12)
        scroll:SetPos(32, 88)
        scroll:SetSize(width - 64, height - 112)
    end

    menu.PerformLayout = update_layout
    update_layout()

    menu._scroll = scroll
    menu._empty = empty

    menu.OnClose = function(panel)
        net.Start(CLOSE_LOGS_MESSAGE)
        net.SendToServer()

        if menu == panel then
            menu = nil
        end
    end

    return menu
end

local function add_entry(entry)
    if not IsValid(menu) then
        return
    end

    local empty = menu._empty
    if IsValid(empty) then
        empty:SetVisible(false)
    end

    create_row(entry, menu._scroll)
end

net.Receive(LOGS_BEGIN_MESSAGE, function()
    local log_count = net.ReadUInt(8)
    local frame = create_menu()

    clear_rows()
    if IsValid(frame._empty) then
        frame._empty:SetVisible(log_count == 0)
    end
end)

net.Receive(LOG_ENTRY_MESSAGE, function()
    add_entry({
        tool = net.ReadString(),
        timestamp = net.ReadUInt(32),
        state = net.ReadString(),
        target = net.ReadString(),
        payload = net.ReadString(),
    })
end)

net.Receive(LOGS_DENIED_MESSAGE, function()
    chat.AddText(Color(220, 120, 120), "[GMod MCP] ", color_white, "Access denied. You do not have permission to view the logs.")
end)

local function request_logs()
    net.Start(REQUEST_LOGS_MESSAGE)
    net.SendToServer()
end

concommand.Add("gmod_mcp", request_logs)