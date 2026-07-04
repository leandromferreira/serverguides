--[[
    ServerGuide_IndexEditor.lua
    Staff-only editor for the menu (index.txt): create / rename / remove
    categories and pages, and mark a category as "rules".

    Works on a local working COPY of the tree; nothing is sent until "Save",
    which ships the whole tree to the server (ServerGuideClient.editIndex). The
    server sanitises it, rewrites index.txt and creates a starter .txt for any
    new page. Removing here only drops entries from the menu -- the .txt files
    stay on disk (see SPEC / README).

    New page file names are derived from the title (slugified) and made unique;
    the title stays independent of the file name, as parseIndex expects.
]]

if isServer() then return end

ServerGuideIndexEditor = ISCollapsableWindow:derive("ServerGuideIndexEditor")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.NewSmall)
local SP = 8
local BTN_H = 25
local BTN_W = 92

------------------------------------------------------------------------
-- Tree helpers
------------------------------------------------------------------------

--- Deep copy of the current client tree into an editable working copy.
local function copyTree(tree)
    local out = {}
    for _, cat in ipairs(tree or {}) do
        local c = { cat = cat.cat, isRules = not not cat.isRules, items = {} }
        for _, it in ipairs(cat.items or {}) do
            table.insert(c.items, { title = it.title, file = it.file })
        end
        table.insert(out, c)
    end
    return out
end

--- Turns a title into a safe, unique .txt file name not already used in the tree.
local function uniqueFileName(tree, title)
    local base = string.lower(title or "page")
    base = string.gsub(base, "[^%w]+", "_")
    base = string.gsub(base, "^_+", "")
    base = string.gsub(base, "_+$", "")
    if base == "" then base = "page" end

    local used = {}
    for _, cat in ipairs(tree) do
        for _, it in ipairs(cat.items) do used[string.lower(it.file)] = true end
    end

    local name = base .. ".txt"
    local n = 2
    while used[string.lower(name)] do
        name = base .. "_" .. n .. ".txt"
        n = n + 1
    end
    return name
end

------------------------------------------------------------------------
-- Construction
------------------------------------------------------------------------

function ServerGuideIndexEditor:createChildren()
    ISCollapsableWindow.createChildren(self)

    local top = self:titleBarHeight()
    local rows = 2
    local bottomH = rows * (BTN_H + SP) + SP
    local listH = self.height - top - bottomH

    self.listBox = ISScrollingListBox:new(SP, top, self.width - SP * 2, listH)
    self.listBox:initialise()
    self.listBox:instantiate()
    self.listBox:setAnchorsTBLR(true, true, true, true)
    self.listBox.itemheight = FONT_HGT_SMALL + 4
    self.listBox.drawBorder = true
    self.listBox.backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 }
    self.listBox.font = UIFont.NewSmall
    self.listBox.doDrawItem = ServerGuideIndexEditor.doDrawItem
    self:addChild(self.listBox)

    -- Row 1: structural actions
    local y1 = self.height - bottomH + SP
    local x = SP
    local function mkBtn(label, fn, xx, yy, ww)
        local b = ISButton:new(xx, yy, ww or BTN_W, BTN_H, label, self, fn)
        b:initialise(); b:instantiate()
        b:setAnchorsTBLR(false, true, true, false)
        b:setFont(UIFont.NewSmall)
        self:addChild(b)
        return b
    end

    self.btnAddCat  = mkBtn(getText("IGUI_ServerGuide_AddCategory"), ServerGuideIndexEditor.onAddCategory, x, y1); x = x + BTN_W + SP
    self.btnAddPage = mkBtn(getText("IGUI_ServerGuide_AddPage"),     ServerGuideIndexEditor.onAddPage,     x, y1); x = x + BTN_W + SP
    self.btnRename  = mkBtn(getText("IGUI_ServerGuide_Rename"),      ServerGuideIndexEditor.onRename,      x, y1); x = x + BTN_W + SP
    self.btnRules   = mkBtn(getText("IGUI_ServerGuide_IsRules"),     ServerGuideIndexEditor.onToggleRules, x, y1); x = x + BTN_W + SP
    self.btnRemove  = mkBtn(getText("IGUI_ServerGuide_Remove"),      ServerGuideIndexEditor.onRemove,      x, y1)

    -- Row 2: order + set-home + save/close
    local y2 = y1 + BTN_H + SP
    x = SP
    self.btnUp   = mkBtn(getText("IGUI_ServerGuide_MoveUp"),   ServerGuideIndexEditor.onMoveUp,   x, y2); x = x + BTN_W + SP
    self.btnDown = mkBtn(getText("IGUI_ServerGuide_MoveDown"), ServerGuideIndexEditor.onMoveDown, x, y2); x = x + BTN_W + SP
    self.btnHome = mkBtn(getText("IGUI_ServerGuide_SetHome"),  ServerGuideIndexEditor.onSetHome,  x, y2)

    self.btnClose = mkBtn(getText("UI_btn_close"), ServerGuideIndexEditor.onCloseBtn,
        self.width - BTN_W - SP, y2)
    self.btnClose:enableCancelColor()
    self.btnSave = mkBtn(getText("IGUI_ServerGuide_Save"), ServerGuideIndexEditor.onSave,
        self.btnClose:getX() - BTN_W - SP, y2)

    self.statusLabel = ISLabel:new(SP, self.height - SP - FONT_HGT_SMALL, FONT_HGT_SMALL, "",
        0.7, 1, 0.7, 1, UIFont.NewSmall, true)
    self.statusLabel:initialise(); self.statusLabel:instantiate()
    self.statusLabel:setAnchorsTBLR(false, true, true, false)
    self:addChild(self.statusLabel)

    self:refreshFromTree(true)
end

------------------------------------------------------------------------
-- List rendering / selection
------------------------------------------------------------------------

--- Rebuilds the list rows from the working tree, preserving the selected line.
function ServerGuideIndexEditor:rebuildList()
    local prev = self.listBox.selected
    self.listBox:clear()
    for ci, cat in ipairs(self.work) do
        local prefix = cat.isRules and "[*] " or ""
        self.listBox:addItem(prefix .. cat.cat, { kind = "cat", ci = ci })
        for ii, it in ipairs(cat.items) do
            local homeMark = (self.workHome and it.file == self.workHome) and "  [home]" or ""
            self.listBox:addItem("      " .. it.title .. "  (" .. it.file .. ")" .. homeMark,
                { kind = "item", ci = ci, ii = ii })
        end
    end
    if prev and prev >= 1 and prev <= #self.listBox.items then
        self.listBox.selected = prev
    end
end

function ServerGuideIndexEditor:doDrawItem(y, item, alt)
    local data = item.item
    if self.selected == item.index then
        self:drawRect(0, y, self:getWidth(), self.itemheight - 1, 0.3, 0.7, 0.35, 0.15)
    end
    if data.kind == "cat" then
        self:drawText(item.text, 4, y + 2, 1, 0.85, 0.4, 1, UIFont.NewSmall)
    else
        self:drawText(item.text, 4, y + 2, 0.9, 0.9, 0.9, 1, UIFont.NewSmall)
    end
    return y + self.itemheight
end

--- Returns the selected row's data ({kind, ci, ii}) or nil.
function ServerGuideIndexEditor:selData()
    local sel = self.listBox.items[self.listBox.selected]
    return sel and sel.item or nil
end

function ServerGuideIndexEditor:setStatus(text, isError)
    self.statusLabel.name = text or ""
    if isError then
        self.statusLabel.r, self.statusLabel.g, self.statusLabel.b = 1, 0.4, 0.4
    else
        self.statusLabel.r, self.statusLabel.g, self.statusLabel.b = 0.7, 1, 0.7
    end
end

function ServerGuideIndexEditor:markDirty()
    self.dirty = true
end

------------------------------------------------------------------------
-- Text prompt helper
------------------------------------------------------------------------

--- Opens a one-field modal. `onText` is called with (editor, text) on OK.
function ServerGuideIndexEditor:prompt(titleText, defaultText, onText)
    self._onText = onText
    local w, h = 320, 150
    local x = getCore():getScreenWidth() / 2 - w / 2
    local y = getCore():getScreenHeight() / 2 - h / 2
    local modal = ISTextBox:new(x, y, w, h, titleText, defaultText or "", self,
        ServerGuideIndexEditor.onPromptClick, nil)
    modal:initialise()
    modal:addToUIManager()
end

function ServerGuideIndexEditor.onPromptClick(editor, button)
    if button.internal == "OK" and editor._onText then
        local text = ServerGuide.trim(button.parent.entry:getText() or "")
        if text ~= "" then editor._onText(editor, text) end
    end
    editor._onText = nil
end

------------------------------------------------------------------------
-- Operations (mutate the working copy only)
------------------------------------------------------------------------

function ServerGuideIndexEditor:onAddCategory()
    self:prompt(getText("IGUI_ServerGuide_NewCategory"), "", function(ed, name)
        table.insert(ed.work, { cat = name, isRules = false, items = {} })
        ed:markDirty(); ed:rebuildList()
        ed.listBox.selected = #ed.listBox.items
    end)
end

function ServerGuideIndexEditor:onAddPage()
    local d = self:selData()
    if not d then self:setStatus(getText("IGUI_ServerGuide_PickCategory"), true) return end
    local ci = d.ci
    self:prompt(getText("IGUI_ServerGuide_NewPageTitle"), "", function(ed, title)
        local cat = ed.work[ci]
        if not cat then return end
        local file = uniqueFileName(ed.work, title)
        table.insert(cat.items, { title = title, file = file })
        ed:markDirty(); ed:rebuildList()
    end)
end

function ServerGuideIndexEditor:onRename()
    local d = self:selData()
    if not d then return end
    if d.kind == "cat" then
        local cat = self.work[d.ci]
        self:prompt(getText("IGUI_ServerGuide_RenameCategory"), cat.cat, function(ed, name)
            ed.work[d.ci].cat = name
            ed:markDirty(); ed:rebuildList()
        end)
    else
        local it = self.work[d.ci].items[d.ii]
        self:prompt(getText("IGUI_ServerGuide_RenamePage"), it.title, function(ed, title)
            ed.work[d.ci].items[d.ii].title = title
            ed:markDirty(); ed:rebuildList()
        end)
    end
end

function ServerGuideIndexEditor:onToggleRules()
    local d = self:selData()
    if not d or d.kind ~= "cat" then
        self:setStatus(getText("IGUI_ServerGuide_PickCategory"), true)
        return
    end
    self.work[d.ci].isRules = not self.work[d.ci].isRules
    self:markDirty(); self:rebuildList()
end

function ServerGuideIndexEditor:onRemove()
    local d = self:selData()
    if not d then return end
    if d.kind == "cat" then
        table.remove(self.work, d.ci)
    else
        table.remove(self.work[d.ci].items, d.ii)
    end
    self:markDirty(); self:rebuildList()
end

--- Moves the selected category, or page within its category, by `delta`.
function ServerGuideIndexEditor:move(delta)
    local d = self:selData()
    if not d then return end
    if d.kind == "cat" then
        local j = d.ci + delta
        if j >= 1 and j <= #self.work then
            self.work[d.ci], self.work[j] = self.work[j], self.work[d.ci]
            self:markDirty(); self:rebuildList()
        end
    else
        local items = self.work[d.ci].items
        local j = d.ii + delta
        if j >= 1 and j <= #items then
            items[d.ii], items[j] = items[j], items[d.ii]
            self:markDirty(); self:rebuildList()
        end
    end
end

function ServerGuideIndexEditor:onMoveUp()   self:move(-1) end
function ServerGuideIndexEditor:onMoveDown() self:move(1)  end

--- Marks the selected page as the default (home) page shown when the guide
--- opens. Clicking it again on the same page clears the home.
function ServerGuideIndexEditor:onSetHome()
    local d = self:selData()
    if not d or d.kind ~= "item" then
        self:setStatus(getText("IGUI_ServerGuide_SelectPage"), true)
        return
    end
    local file = self.work[d.ci].items[d.ii].file
    if self.workHome == file then
        self.workHome = nil   -- toggle off
    else
        self.workHome = file
    end
    self:markDirty(); self:rebuildList()
end

------------------------------------------------------------------------
-- Save / close / server feedback
------------------------------------------------------------------------

function ServerGuideIndexEditor:onSave()
    ServerGuideClient.editIndex(self.work, self.workHome)
    self:setStatus(getText("IGUI_ServerGuide_Saving"))
end

--- Reloads the working copy from the current client tree, unless the user has
--- unsaved local changes (then we keep them, to avoid clobbering their work).
function ServerGuideIndexEditor:refreshFromTree(force)
    if self.dirty and not force then return end
    self.work = copyTree(ServerGuideClient and ServerGuideClient.tree or {})
    self.workHome = ServerGuideClient and ServerGuideClient.home or nil
    self.dirty = false
    self:rebuildList()
end

function ServerGuideIndexEditor:onEditResult(args)
    if args.op ~= "editIndex" then return end
    if args.ok then
        self.dirty = false
        self:setStatus(getText("IGUI_ServerGuide_Saved"))
        -- the index re-broadcast will call refreshFromTree() with the new tree
    else
        local r = args.reason
        if r == "not authorized" then r = getText("IGUI_ServerGuide_NotAuthorized")
        elseif r == "stale" then r = getText("IGUI_ServerGuide_Stale")
        else r = getText("IGUI_ServerGuide_SaveError", tostring(r or "?")) end
        self:setStatus(r, true)
    end
end

function ServerGuideIndexEditor:onCloseBtn()
    self:close()
end

function ServerGuideIndexEditor:close()
    if self.parentUI then self.parentUI.indexEditor = nil end
    self:setVisible(false)
    self:removeFromUIManager()
    ServerGuideIndexEditor.instance = nil
end

------------------------------------------------------------------------
-- Construction / static open
------------------------------------------------------------------------

function ServerGuideIndexEditor:new()
    local w, h = 560, 460
    local x = getCore():getScreenWidth() / 2 - w / 2
    local y = getCore():getScreenHeight() / 2 - h / 2
    local o = ISCollapsableWindow.new(self, x, y, w, h)
    o.title = getText("IGUI_ServerGuide_EditIndex")
    o.resizable = true
    return o
end

--- Opens the editor (one instance), linked to the parent viewer for refreshes.
function ServerGuideIndexEditor.open(parentUI)
    if not (ServerGuideClient and ServerGuideClient.canEdit) then return end
    if not ServerGuideIndexEditor.instance then
        local o = ServerGuideIndexEditor:new()
        o.parentUI = parentUI
        o:initialise()
        o:addToUIManager()
        ServerGuideIndexEditor.instance = o
        if parentUI then parentUI.indexEditor = o end
    end
    local inst = ServerGuideIndexEditor.instance
    inst:setVisible(true)
    inst:bringToTop()
    inst:refreshFromTree()
end
