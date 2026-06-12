--[[
    ServerGuides_UI.lua
    Read-only viewer window for the server's guides/rules.
    Mirrors the SurvivalGuide pattern:
      - left: ISScrollingListBox with the tree (categories = header,
        items = indented, clickable subCategory);
      - right: ISRichTextPanel with the content (native tags).
    No acknowledgement: the player opens, reads and closes. (SPEC 8)

    Data state (tree, rules version, page cache) is kept in ServerGuidesClient
    (ServerGuides_Client.lua). This window only renders.
]]

ServerGuidesUI = ISCollapsableWindow:derive("ServerGuidesUI")

local FONT_HGT_SMALL  = getTextManager():getFontHeight(UIFont.NewSmall)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.NewMedium)
local UI_BORDER_SPACING = 8
local BTN_WIDTH  = 100
local BTN_HEIGHT = 25
local LIST_WIDTH = 200
local BODY_WIDTH = 560
local BOTTOM_PANEL_HEIGHT = BTN_HEIGHT + UI_BORDER_SPACING * 2

------------------------------------------------------------------------
-- Construction
------------------------------------------------------------------------

function ServerGuidesUI:createChildren()
    ISCollapsableWindow.createChildren(self)

    local top = self:titleBarHeight()
    local listH = self.height - top - BOTTOM_PANEL_HEIGHT

    self.listBox = ISScrollingListBox:new(0, top, LIST_WIDTH, listH)
    self.listBox:initialise()
    self.listBox:instantiate()
    self.listBox:setAnchorsTBLR(true, true, true, false)
    self.listBox.itemheight = FONT_HGT_SMALL + 4
    self.listBox.drawBorder = true
    self.listBox.backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 }
    self.listBox.font = UIFont.NewSmall
    self.listBox.doDrawItem = ServerGuidesUI.doDrawItem
    self.listBox:setOnMouseDownFunction(self, ServerGuidesUI.onClickList)
    self:addChild(self.listBox)

    local scrollbarWid = 13
    self.body = ISRichTextPanel:new(self.listBox:getRight(), top,
        self.width - self.listBox:getWidth(), listH)
    self.body:initialise()
    self.body:instantiate()
    self.body:setAnchorsTBLR(true, true, true, true)
    self.body.autosetheight = false
    self.body.clip = true
    self.body.doRepaintStencil = true
    self.body:setMargins(10, 10, 10 + scrollbarWid, 10)
    self.body.backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 }
    self:addChild(self.body)
    self.body:addScrollBars()

    local btnY = self.height - BTN_HEIGHT - UI_BORDER_SPACING

    self.closeButton = ISButton:new(self.width - BTN_WIDTH - UI_BORDER_SPACING,
        btnY, BTN_WIDTH, BTN_HEIGHT,
        getText("UI_btn_close"), self, ServerGuidesUI.onClose)
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self.closeButton:setAnchorsTBLR(false, true, false, true)
    self.closeButton:setFont(UIFont.NewSmall)
    self.closeButton:enableCancelColor()
    self:addChild(self.closeButton)

    -- Staff-only editing controls ------------------------------------------------

    -- "Edit page": toggles inline edit mode over the content panel.
    self.editButton = ISButton:new(self.closeButton:getX() - BTN_WIDTH - UI_BORDER_SPACING,
        btnY, BTN_WIDTH, BTN_HEIGHT,
        getText("IGUI_ServerGuides_Edit"), self, ServerGuidesUI.onEditPage)
    self.editButton:initialise()
    self.editButton:instantiate()
    self.editButton:setAnchorsTBLR(false, true, false, true)
    self.editButton:setFont(UIFont.NewSmall)
    self:addChild(self.editButton)

    -- "Edit menu": opens the index editor window.
    self.editMenuButton = ISButton:new(self.editButton:getX() - BTN_WIDTH - UI_BORDER_SPACING,
        btnY, BTN_WIDTH, BTN_HEIGHT,
        getText("IGUI_ServerGuides_EditIndex"), self, ServerGuidesUI.onEditMenu)
    self.editMenuButton:initialise()
    self.editMenuButton:instantiate()
    self.editMenuButton:setAnchorsTBLR(false, true, false, true)
    self.editMenuButton:setFont(UIFont.NewSmall)
    self:addChild(self.editMenuButton)

    -- Save / Cancel: shown only while in edit mode (same slots as edit/close).
    self.saveButton = ISButton:new(self.editButton:getX(), btnY, BTN_WIDTH, BTN_HEIGHT,
        getText("IGUI_ServerGuides_Save"), self, ServerGuidesUI.onSaveEdit)
    self.saveButton:initialise()
    self.saveButton:instantiate()
    self.saveButton:setAnchorsTBLR(false, true, false, true)
    self.saveButton:setFont(UIFont.NewSmall)
    self.saveButton:setVisible(false)
    self:addChild(self.saveButton)

    self.cancelButton = ISButton:new(self.closeButton:getX(), btnY, BTN_WIDTH, BTN_HEIGHT,
        getText("IGUI_ServerGuides_Cancel"), self, ServerGuidesUI.onCancelEdit)
    self.cancelButton:initialise()
    self.cancelButton:instantiate()
    self.cancelButton:setAnchorsTBLR(false, true, false, true)
    self.cancelButton:setFont(UIFont.NewSmall)
    self.cancelButton:enableCancelColor()
    self.cancelButton:setVisible(false)
    self:addChild(self.cancelButton)

    -- Inline multi-line editor (over the content panel); created hidden.
    -- NOTE: every ISTextEntryBox method below is backed by its javaObject, which
    -- only exists after instantiate() -- so they MUST be called after it, never
    -- before (calling setMultipleLine on a non-instantiated box crashes).
    self.editor = ISTextEntryBox:new("", self.body:getX(), top,
        self.body:getWidth(), listH)
    self.editor:initialise()
    self.editor:instantiate()
    self.editor:setMultipleLine(true)
    -- a generous positive cap: -1 is treated as "no extra lines" and blocks Enter
    self.editor:setMaxLines(100000)
    -- raise the default length cap so long pages aren't truncated
    self.editor:setMaxTextLength(ServerGuides.MAX_FILE_BYTES)
    self.editor:setFont(UIFont.NewSmall)
    self.editor:setAnchorsTBLR(true, true, true, true)
    self.editor:setVisible(false)
    self:addChild(self.editor)

    -- Status/feedback line at the bottom-left of the window.
    self.statusLabel = ISLabel:new(UI_BORDER_SPACING, btnY + 4, BTN_HEIGHT, "",
        1, 1, 1, 1, UIFont.NewSmall, true)
    self.statusLabel:initialise()
    self.statusLabel:instantiate()
    self.statusLabel:setAnchorsTBLR(false, true, true, false)
    self:addChild(self.statusLabel)

    self:updateEditControls()
    self:refreshList()
end

--- Shows the edit controls only for staff, and only the right set for the
--- current mode (viewing vs editing).
function ServerGuidesUI:updateEditControls()
    -- server-authoritative: the client can't reliably read its own access level
    local canEdit = ServerGuidesClient and ServerGuidesClient.canEdit == true
    local editing = self.editing == true

    self.editButton:setVisible(canEdit and not editing)
    self.editMenuButton:setVisible(canEdit and not editing)
    self.saveButton:setVisible(canEdit and editing)
    self.cancelButton:setVisible(canEdit and editing)
    self.closeButton:setVisible(not editing)
    self.editor:setVisible(editing)
    self.body:setVisible(not editing)
end

------------------------------------------------------------------------
-- Side list
------------------------------------------------------------------------

--- (Re)fills the list from the current tree (ServerGuidesClient.tree).
function ServerGuidesUI:refreshList()
    self.listBox:clear()
    local tree = ServerGuidesClient and ServerGuidesClient.tree or {}
    for _, cat in ipairs(tree) do
        -- category header (not clickable)
        self.listBox:addItem(cat.cat, { header = true, title = cat.cat })
        for _, item in ipairs(cat.items) do
            self.listBox:addItem("    " .. item.title, {
                header = false,
                title = item.title,
                file = item.file,
            })
        end
    end
end

--- Draws each row (highlighted header, indented item).
function ServerGuidesUI:doDrawItem(y, item, alt)
    local data = item.item
    if self.selected == item.index and not data.header then
        self:drawRect(0, y, self:getWidth(), self.itemheight - 1, 0.3, 0.7, 0.35, 0.15)
    end
    if data.header then
        self:drawText(item.text, 4, y + 2, 1, 0.85, 0.4, 1, UIFont.NewSmall)
    else
        self:drawText(item.text, 4, y + 2, 0.9, 0.9, 0.9, 1, UIFont.NewSmall)
    end
    return y + self.itemheight
end

function ServerGuidesUI:onClickList()
    local sel = self.listBox.items[self.listBox.selected]
    if not sel then return end
    local data = sel.item
    if data.header then
        -- clicking a header: opens nothing
        return
    end
    self:showPage(data.file, data.title)
end

------------------------------------------------------------------------
-- Content
------------------------------------------------------------------------

--- Shows a file's page. Uses the client cache; if it hasn't arrived yet,
--- requests it from the server and shows a placeholder until the content returns.
function ServerGuidesUI:showPage(file, title)
    self.currentFile = file
    local cached = ServerGuidesClient and ServerGuidesClient.pageCache[file]
    if cached then
        self.body.text = cached
    else
        self.body.text = " <CENTRE> <SIZE:medium> " .. (title or "") .. " <LINE><LINE> " ..
            getText("IGUI_ServerGuides_Loading")
        if ServerGuidesClient then
            ServerGuidesClient.requestPage(file)
        end
    end
    self.body:paginate()
    self.body:setYScroll(0)
end

--- Called by the client when a file finishes arriving; if it is the file
--- currently displayed, refreshes the panel.
function ServerGuidesUI:onPageReady(file, content)
    if self.currentFile == file then
        self.body.text = content
        self.body:paginate()
        self.body:setYScroll(0)
        -- a staff member asked to edit before the page had loaded
        if self.pendingEdit then
            self.pendingEdit = false
            self:enterEditMode()
        end
    end
end

------------------------------------------------------------------------
-- Editing (staff only)
------------------------------------------------------------------------

function ServerGuidesUI:setStatus(text, isError)
    self.statusLabel.name = text or ""
    if isError then
        self.statusLabel.r, self.statusLabel.g, self.statusLabel.b = 1, 0.4, 0.4
    else
        self.statusLabel.r, self.statusLabel.g, self.statusLabel.b = 0.7, 1, 0.7
    end
end

--- "Edit" button: enter inline edit mode for the current page.
function ServerGuidesUI:onEditPage()
    if not (ServerGuidesClient and ServerGuidesClient.canEdit) then return end
    if not self.currentFile then
        self:setStatus(getText("IGUI_ServerGuides_PickPage"), true)
        return
    end
    local cached = ServerGuidesClient and ServerGuidesClient.pageCache[self.currentFile]
    if not cached then
        -- not loaded yet: request it and edit once it arrives
        self.pendingEdit = true
        self:setStatus(getText("IGUI_ServerGuides_Loading"))
        if ServerGuidesClient then ServerGuidesClient.requestPage(self.currentFile) end
        return
    end
    self:enterEditMode()
end

function ServerGuidesUI:enterEditMode()
    local content = (ServerGuidesClient and ServerGuidesClient.pageCache[self.currentFile]) or ""
    self.editBaseHash = ServerGuides.hashString(content)
    self.editor:setText(content)
    self.editing = true
    self:setStatus("")
    self:updateEditControls()
    self.editor:focus()
end

--- "Save": upload the edited content; the server validates and writes.
function ServerGuidesUI:onSaveEdit()
    local content = self.editor:getText() or ""
    if #content > ServerGuides.MAX_FILE_BYTES then
        self:setStatus(getText("IGUI_ServerGuides_TooLarge"), true)
        return
    end
    ServerGuidesClient.savePage(self.currentFile, content, self.editBaseHash)
    self:setStatus(getText("IGUI_ServerGuides_Saving"))
end

--- "Cancel": discard the edit and return to the rendered view.
function ServerGuidesUI:onCancelEdit()
    self.editing = false
    self.pendingEdit = false
    self:setStatus("")
    self:updateEditControls()
end

--- "Edit menu": open the index (menu) editor.
function ServerGuidesUI:onEditMenu()
    if not (ServerGuidesClient and ServerGuidesClient.canEdit) then return end
    if ServerGuidesIndexEditor then ServerGuidesIndexEditor.open(self) end
end

--- Maps a server-side failure reason to a localised message.
local function reasonText(reason)
    if reason == "not authorized" then return getText("IGUI_ServerGuides_NotAuthorized") end
    if reason == "too large" then return getText("IGUI_ServerGuides_TooLarge") end
    if reason == "stale" then return getText("IGUI_ServerGuides_Stale") end
    return getText("IGUI_ServerGuides_SaveError", tostring(reason or "?"))
end

--- Result of a save/menu edit, forwarded by the client.
function ServerGuidesUI:onEditResult(args)
    if args.ok then
        if args.op == "savePage" then
            self.editing = false
            self:updateEditControls()
        end
        self:setStatus(getText("IGUI_ServerGuides_Saved"))
        if self.indexEditor then self.indexEditor:onEditResult(args) end
    else
        self:setStatus(reasonText(args.reason), true)
        if self.indexEditor then self.indexEditor:onEditResult(args) end
    end
end

--- Selects the first clickable page (skips headers). If prefRules, tries the
--- first page of a rules category.
function ServerGuidesUI:selectFirst(prefRules)
    local items = self.listBox.items
    local target = nil
    if prefRules then
        local tree = ServerGuidesClient and ServerGuidesClient.tree or {}
        -- find the first file of a rules category
        local rulesFile = nil
        for _, cat in ipairs(tree) do
            if cat.isRules and cat.items[1] then rulesFile = cat.items[1].file break end
        end
        if rulesFile then
            for idx, it in ipairs(items) do
                if it.item.file == rulesFile then target = idx break end
            end
        end
    end
    if not target then
        for idx, it in ipairs(items) do
            if not it.item.header and it.item.file then target = idx break end
        end
    end
    if target then
        self.listBox.selected = target
        self:onClickList()
    end
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------

function ServerGuidesUI:onClose()
    self:setVisible(false)
    -- detach from whichever layer we were shown in
    if self.parentMenu then
        self.parentMenu:removeChild(self)
        self.parentMenu = nil
    end
    if self.addedToUIMgr then
        self:removeFromUIManager()
        self.addedToUIMgr = false
    end
    ServerGuidesUI.instance = nil
end

function ServerGuidesUI:new()
    local w = LIST_WIDTH + BODY_WIDTH
    local h = 520
    local x = getCore():getScreenWidth() / 2 - w / 2
    local y = getCore():getScreenHeight() / 2 - h / 2
    local o = ISCollapsableWindow.new(self, x, y, w, h)
    o.title = getText("IGUI_ServerGuides_WindowTitle")
    o.resizable = true
    o:setWantKeyEvents(true)
    return o
end

------------------------------------------------------------------------
-- Static API (called by the keybind, ESC menu and auto-open)
------------------------------------------------------------------------

--- Shows the window in the right layer. If the pause menu (MainScreen) is open,
--- parent the window TO it so it draws above the menu -- exactly like Server Shop
--- -- instead of resuming the game. Resuming routes through code that, on some
--- servers, hits an unrelated menu-render bug (a bad UI_servers_refresh_timer
--- translation), so we avoid it. Otherwise (in-game auto-open) use the UIManager.
function ServerGuidesUI.attach(inst)
    local menu = MainScreen.instance
    local overMenu = menu and menu:isVisible() and menu.inGame == true
    if overMenu then
        if inst.addedToUIMgr then
            inst:removeFromUIManager()
            inst.addedToUIMgr = false
        end
        if inst.parentMenu ~= menu then
            if inst.parentMenu then inst.parentMenu:removeChild(inst) end
            menu:addChild(inst)
            inst.parentMenu = menu
        end
    else
        if inst.parentMenu then
            inst.parentMenu:removeChild(inst)
            inst.parentMenu = nil
        end
        if not inst.addedToUIMgr then
            inst:addToUIManager()
            inst.addedToUIMgr = true
        end
    end
end

--- Ensures the instance is created and visible. Always re-requests the index so
--- the tree AND the per-player canEdit flag are current -- the player's access
--- level may have changed since the last open (e.g. admin granted/revoked), and
--- canEdit is only refreshed by a sendIndex reply, never by broadcasts.
-- @param prefRules if true, opens straight on the first rules page
function ServerGuidesUI.open(prefRules)
    if isServer() then return end
    if not ServerGuidesUI.instance then
        ServerGuidesUI.instance = ServerGuidesUI:new()
        ServerGuidesUI.instance:initialise()
    end
    local inst = ServerGuidesUI.instance
    ServerGuidesUI.attach(inst)
    inst:setVisible(true)
    inst:bringToTop()
    inst:refreshList()

    -- always refresh from the server (cheap; index is tiny)
    inst.pendingRulesPref = prefRules
    if ServerGuidesClient then ServerGuidesClient.requestIndex() end

    if ServerGuidesClient and ServerGuidesClient.tree then
        -- show the cached tree immediately; the fresh reply updates it shortly
        inst:selectFirst(prefRules)
    end
end

function ServerGuidesUI.openRules()
    ServerGuidesUI.open(true)
end

--- Keeps the player on the page they were reading after a live refresh (e.g. an
--- edit), instead of jumping back to the first page. Falls back to selectFirst.
function ServerGuidesUI:reselectOrFirst(prefRules)
    if self.currentFile then
        for idx, it in ipairs(self.listBox.items) do
            if it.item.file == self.currentFile then
                self.listBox.selected = idx
                self:onClickList()
                return
            end
        end
    end
    self:selectFirst(prefRules)
end

--- Called by the client when the index arrives (to fill the list if the window
--- is already open and waiting).
function ServerGuidesUI.onIndexReady()
    local inst = ServerGuidesUI.instance
    if inst and inst:isVisible() then
        inst:refreshList()
        inst:reselectOrFirst(inst.pendingRulesPref)
        inst.pendingRulesPref = nil
        inst:updateEditControls()
        if inst.indexEditor then inst.indexEditor:refreshFromTree() end
    end
end
