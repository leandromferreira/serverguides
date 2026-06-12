--[[
    ServerGuides_IndexEditor.lua
    Staff-only editor for the menu (index.txt): create / rename / remove
    categories and pages, and mark a category as "rules".

    Works on a local working COPY of the tree; nothing is sent until "Save",
    which ships the whole tree to the server (ServerGuidesClient.editIndex). The
    server sanitises it, rewrites index.txt and creates a starter .txt for any
    new page. Removing here only drops entries from the menu -- the .txt files
    stay on disk (see SPEC / README).

    New page file names are derived from the title (slugified) and made unique;
    the title stays independent of the file name, as parseIndex expects.
]]

if isServer() then return end

ServerGuidesIndexEditor = ISCollapsableWindow:derive("ServerGuidesIndexEditor")

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

function ServerGuidesIndexEditor:createChildren()
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
    self.listBox.doDrawItem = ServerGuidesIndexEditor.doDrawItem
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

    self.btnAddCat  = mkBtn(getText("IGUI_ServerGuides_AddCategory"), ServerGuidesIndexEditor.onAddCategory, x, y1); x = x + BTN_W + SP
    self.btnAddPage = mkBtn(getText("IGUI_ServerGuides_AddPage"),     ServerGuidesIndexEditor.onAddPage,     x, y1); x = x + BTN_W + SP
    self.btnRename  = mkBtn(getText("IGUI_ServerGuides_Rename"),      ServerGuidesIndexEditor.onRename,      x, y1); x = x + BTN_W + SP
    self.btnRules   = mkBtn(getText("IGUI_ServerGuides_IsRules"),     ServerGuidesIndexEditor.onToggleRules, x, y1); x = x + BTN_W + SP
    self.btnRemove  = mkBtn(getText("IGUI_ServerGuides_Remove"),      ServerGuidesIndexEditor.onRemove,      x, y1)

    -- Row 2: order + save/close
    local y2 = y1 + BTN_H + SP
    x = SP
    self.btnUp   = mkBtn(getText("IGUI_ServerGuides_MoveUp"),   ServerGuidesIndexEditor.onMoveUp,   x, y2); x = x + BTN_W + SP
    self.btnDown = mkBtn(getText("IGUI_ServerGuides_MoveDown"), ServerGuidesIndexEditor.onMoveDown, x, y2)

    self.btnClose = mkBtn(getText("UI_btn_close"), ServerGuidesIndexEditor.onCloseBtn,
        self.width - BTN_W - SP, y2)
    self.btnClose:enableCancelColor()
    self.btnSave = mkBtn(getText("IGUI_ServerGuides_Save"), ServerGuidesIndexEditor.onSave,
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
function ServerGuidesIndexEditor:rebuildList()
    local prev = self.listBox.selected
    self.listBox:clear()
    for ci, cat in ipairs(self.work) do
        local prefix = cat.isRules and "[*] " or ""
        self.listBox:addItem(prefix .. cat.cat, { kind = "cat", ci = ci })
        for ii, it in ipairs(cat.items) do
            self.listBox:addItem("      " .. it.title .. "  (" .. it.file .. ")",
                { kind = "item", ci = ci, ii = ii })
        end
    end
    if prev and prev >= 1 and prev <= #self.listBox.items then
        self.listBox.selected = prev
    end
end

function ServerGuidesIndexEditor:doDrawItem(y, item, alt)
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
function ServerGuidesIndexEditor:selData()
    local sel = self.listBox.items[self.listBox.selected]
    return sel and sel.item or nil
end

function ServerGuidesIndexEditor:setStatus(text, isError)
    self.statusLabel.name = text or ""
    if isError then
        self.statusLabel.r, self.statusLabel.g, self.statusLabel.b = 1, 0.4, 0.4
    else
        self.statusLabel.r, self.statusLabel.g, self.statusLabel.b = 0.7, 1, 0.7
    end
end

function ServerGuidesIndexEditor:markDirty()
    self.dirty = true
end

------------------------------------------------------------------------
-- Text prompt helper
------------------------------------------------------------------------

--- Opens a one-field modal. `onText` is called with (editor, text) on OK.
function ServerGuidesIndexEditor:prompt(titleText, defaultText, onText)
    self._onText = onText
    local w, h = 320, 150
    local x = getCore():getScreenWidth() / 2 - w / 2
    local y = getCore():getScreenHeight() / 2 - h / 2
    local modal = ISTextBox:new(x, y, w, h, titleText, defaultText or "", self,
        ServerGuidesIndexEditor.onPromptClick, nil)
    modal:initialise()
    modal:addToUIManager()
end

function ServerGuidesIndexEditor.onPromptClick(editor, button)
    if button.internal == "OK" and editor._onText then
        local text = ServerGuides.trim(button.parent.entry:getText() or "")
        if text ~= "" then editor._onText(editor, text) end
    end
    editor._onText = nil
end

------------------------------------------------------------------------
-- Operations (mutate the working copy only)
------------------------------------------------------------------------

function ServerGuidesIndexEditor:onAddCategory()
    self:prompt(getText("IGUI_ServerGuides_NewCategory"), "", function(ed, name)
        table.insert(ed.work, { cat = name, isRules = false, items = {} })
        ed:markDirty(); ed:rebuildList()
        ed.listBox.selected = #ed.listBox.items
    end)
end

function ServerGuidesIndexEditor:onAddPage()
    local d = self:selData()
    if not d then self:setStatus(getText("IGUI_ServerGuides_PickCategory"), true) return end
    local ci = d.ci
    self:prompt(getText("IGUI_ServerGuides_NewPageTitle"), "", function(ed, title)
        local cat = ed.work[ci]
        if not cat then return end
        local file = uniqueFileName(ed.work, title)
        table.insert(cat.items, { title = title, file = file })
        ed:markDirty(); ed:rebuildList()
    end)
end

function ServerGuidesIndexEditor:onRename()
    local d = self:selData()
    if not d then return end
    if d.kind == "cat" then
        local cat = self.work[d.ci]
        self:prompt(getText("IGUI_ServerGuides_RenameCategory"), cat.cat, function(ed, name)
            ed.work[d.ci].cat = name
            ed:markDirty(); ed:rebuildList()
        end)
    else
        local it = self.work[d.ci].items[d.ii]
        self:prompt(getText("IGUI_ServerGuides_RenamePage"), it.title, function(ed, title)
            ed.work[d.ci].items[d.ii].title = title
            ed:markDirty(); ed:rebuildList()
        end)
    end
end

function ServerGuidesIndexEditor:onToggleRules()
    local d = self:selData()
    if not d or d.kind ~= "cat" then
        self:setStatus(getText("IGUI_ServerGuides_PickCategory"), true)
        return
    end
    self.work[d.ci].isRules = not self.work[d.ci].isRules
    self:markDirty(); self:rebuildList()
end

function ServerGuidesIndexEditor:onRemove()
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
function ServerGuidesIndexEditor:move(delta)
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

function ServerGuidesIndexEditor:onMoveUp()   self:move(-1) end
function ServerGuidesIndexEditor:onMoveDown() self:move(1)  end

------------------------------------------------------------------------
-- Save / close / server feedback
------------------------------------------------------------------------

function ServerGuidesIndexEditor:onSave()
    ServerGuidesClient.editIndex(self.work)
    self:setStatus(getText("IGUI_ServerGuides_Saving"))
end

--- Reloads the working copy from the current client tree, unless the user has
--- unsaved local changes (then we keep them, to avoid clobbering their work).
function ServerGuidesIndexEditor:refreshFromTree(force)
    if self.dirty and not force then return end
    self.work = copyTree(ServerGuidesClient and ServerGuidesClient.tree or {})
    self.dirty = false
    self:rebuildList()
end

function ServerGuidesIndexEditor:onEditResult(args)
    if args.op ~= "editIndex" then return end
    if args.ok then
        self.dirty = false
        self:setStatus(getText("IGUI_ServerGuides_Saved"))
        -- the index re-broadcast will call refreshFromTree() with the new tree
    else
        local r = args.reason
        if r == "not authorized" then r = getText("IGUI_ServerGuides_NotAuthorized")
        elseif r == "stale" then r = getText("IGUI_ServerGuides_Stale")
        else r = getText("IGUI_ServerGuides_SaveError", tostring(r or "?")) end
        self:setStatus(r, true)
    end
end

function ServerGuidesIndexEditor:onCloseBtn()
    self:close()
end

function ServerGuidesIndexEditor:close()
    if self.parentUI then self.parentUI.indexEditor = nil end
    self:setVisible(false)
    self:removeFromUIManager()
    ServerGuidesIndexEditor.instance = nil
end

------------------------------------------------------------------------
-- Construction / static open
------------------------------------------------------------------------

function ServerGuidesIndexEditor:new()
    local w, h = 480, 460
    local x = getCore():getScreenWidth() / 2 - w / 2
    local y = getCore():getScreenHeight() / 2 - h / 2
    local o = ISCollapsableWindow.new(self, x, y, w, h)
    o.title = getText("IGUI_ServerGuides_EditIndex")
    o.resizable = true
    return o
end

--- Opens the editor (one instance), linked to the parent viewer for refreshes.
function ServerGuidesIndexEditor.open(parentUI)
    if not (ServerGuidesClient and ServerGuidesClient.canEdit) then return end
    if not ServerGuidesIndexEditor.instance then
        local o = ServerGuidesIndexEditor:new()
        o.parentUI = parentUI
        o:initialise()
        o:addToUIManager()
        ServerGuidesIndexEditor.instance = o
        if parentUI then parentUI.indexEditor = o end
    end
    local inst = ServerGuidesIndexEditor.instance
    inst:setVisible(true)
    inst:bringToTop()
    inst:refreshFromTree()
end
