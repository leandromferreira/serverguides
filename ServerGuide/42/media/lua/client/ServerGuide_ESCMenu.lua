--[[
    ServerGuide_ESCMenu.lua
    Adds a "Server Guide" entry to the in-game pause menu (MainScreen with
    self.inGame == true), styled as a native bottom-panel menu item -- the same
    approach Server Shop uses (an ISLabel in self.bottomPanel with the fade /
    prerenderBottomPanelLabel treatment), rather than a floating button. (SPEC 8)

    MainScreen:render() runs every frame in-game: it repositions the menu items
    and clamps bottomPanel's height to quitToDesktop:getBottom(), which would hide
    anything added below it. So we wrap render() to (re)position our item under the
    last menu entry and extend the panel height to include it.
]]

if isServer() then return end

--- Bottom Y of the lowest menu label currently in the panel, ignoring our own.
-- We stack BELOW whatever is there, so we coexist with any other mod that adds
-- an item the same way (Server Shop, etc.) regardless of its field name --
-- instead of hardcoding one mod's variable.
local function lowestMenuBottom(self)
    local maxBottom = self.quitToDesktop and self.quitToDesktop:getBottom() or 0
    for _, child in pairs(self.bottomPanel:getChildren()) do
        if child.Type == "ISLabel" and child ~= self.serverGuidesOption then
            local b = child:getBottom()
            if b and b > maxBottom then maxBottom = b end
        end
    end
    return maxBottom
end

local function positionServerGuideItem(self)
    self.serverGuidesOption:setY(lowestMenuBottom(self) + 16)
    self.bottomPanel:setHeight(self.serverGuidesOption:getBottom())
end

local original_instantiate = MainScreen.instantiate
function MainScreen:instantiate()
    original_instantiate(self)

    if not self.inGame then return end
    if self.serverGuidesOption then return end

    local labelHgt = getTextManager():getFontHeight(UIFont.Large) + 8 * 2
    self.serverGuidesOption = ISLabel:new(self.quitToDesktop.x, self.quitToDesktop:getBottom() + 16,
        labelHgt, getText("IGUI_ServerGuide_MenuButton"), 1, 1, 1, 1, UIFont.Large, true)
    self.serverGuidesOption.internal = "SERVER_GUIDES"
    self.serverGuidesOption:initialise()
    self.bottomPanel:addChild(self.serverGuidesOption)
    self.serverGuidesOption:setWidth(self.quitToDesktop.width)

    -- native menu-item look: hover fade + the shared label prerender
    self.serverGuidesOption.fade = UITransition.new()
    self.serverGuidesOption.fade:setFadeIn(false)
    self.serverGuidesOption.prerender = MainScreen.prerenderBottomPanelLabel
    self.serverGuidesOption.onMouseMove = function(label)
        label.fade:setFadeIn(true)
    end
    self.serverGuidesOption.onMouseMoveOutside = function(label)
        label.fade:setFadeIn(false)
    end
    self.serverGuidesOption.onMouseDown = function()
        getSoundManager():playUISound("UIActivateMainMenuItem")
        -- open the guides OVER the pause menu (no resume), like Server Shop
        ServerGuideUI.open(false)
    end

    positionServerGuideItem(self)

    -- render() resets the layout/height every frame; chain it (preserving any
    -- other mod's override, e.g. Server Shop) and re-place our item afterwards.
    local prevRender = self.render or MainScreen.render
    self.render = function(s)
        prevRender(s)
        if s.inGame and s.serverGuidesOption then
            positionServerGuideItem(s)
        end
    end
end
