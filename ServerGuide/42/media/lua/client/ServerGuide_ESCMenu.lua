--[[
    ServerGuide_ESCMenu.lua
    Adds a "Server Guide" entry to the in-game pause menu (MainScreen with
    self.inGame == true), styled as a native bottom-panel menu item -- the same
    approach Server Shop uses (an ISLabel in self.bottomPanel with the fade /
    prerenderBottomPanelLabel treatment), rather than a floating button. (SPEC 8)

    Coexisting with other menu-item mods (e.g. Server Shop):
    Server Shop places its item one row below quitToDesktop AND does
    `self.render = newRender` in its own instantiate -- it REPLACES self.render
    instead of chaining, and its item lands in the same slot as ours. Depending
    on mod load order that either drops OUR render wrapper (so we never
    reposition -> overlap) or leaves both items at the same Y.

    Fix: we make sure OUR render wrapper is always the OUTERMOST self.render
    (re-asserting it from OnTickEvenPaused if another mod replaced it), and it
    positions our item BELOW the lowest existing item and extends the panel
    height LAST. This works regardless of load order and regardless of what the
    other mod's render does, because ours runs after it every frame.
]]

if isServer() then return end

--- Places our item below the lowest OTHER visible item in the bottom panel
--- (native RETURN/OPTIONS/EXIT/QUIT plus any other mod's item, e.g. Server
--- Shop's), and grows the panel to include us.
local function positionServerGuideItem(self)
    local mine = self.serverGuidesOption
    if not mine or not self.bottomPanel then return end

    local maxBottom = self.quitToDesktop and self.quitToDesktop:getBottom() or 0
    for _, child in pairs(self.bottomPanel:getChildren()) do
        if child ~= mine and child.getBottom and child:isVisible() then
            local b = child:getBottom()
            if b and b > maxBottom then maxBottom = b end
        end
    end

    mine:setY(maxBottom + 16)
    if mine:getBottom() > self.bottomPanel:getHeight() then
        self.bottomPanel:setHeight(mine:getBottom())
    end
end

--- Ensures OUR wrapper is the current (outermost) self.render, so our
--- repositioning runs LAST each frame. If another mod later replaces self.render
--- (Server Shop does `self.render = newRender`), we detect the mismatch and
--- re-wrap around it -- so we survive any load order without an endless wrap war
--- (we only re-wrap when self.render is no longer our hook).
local function ensureRenderHook(self)
    if self.serverGuideRenderHook == self.render then return end
    local prev = self.render
    local hook
    hook = function(s)
        if prev then prev(s) end
        if s.inGame and s.serverGuidesOption then
            positionServerGuideItem(s)
        end
    end
    self.serverGuideRenderHook = hook
    self.render = hook
end

local original_instantiate = MainScreen.instantiate
function MainScreen:instantiate()
    original_instantiate(self)

    if not self.inGame then return end
    if self.serverGuidesOption then return end

    local labelHgt = getTextManager():getFontHeight(UIFont.Large) + 8 * 2
    self.serverGuidesOption = ISLabel:new(self.quitToDesktop.x, self.quitToDesktop:getBottom() + 16,
        labelHgt, getText("IGUI_ServerGuide_MenuButton"), 1, 1, 1, 1, UIFont.Large, true)
    self.serverGuidesOption.internal = "SERVER_GUIDE"
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

    ensureRenderHook(self)
    positionServerGuideItem(self)
end

-- Re-assert our render hook and reposition every tick (fires even while the game
-- is paused, i.e. while the pause menu is up). This is what makes us robust to
-- another mod replacing self.render in a later instantiate than ours.
Events.OnTickEvenPaused.Add(function()
    local self = MainScreen.instance
    if not self or not self.inGame or not self.serverGuidesOption then return end
    if not self:isVisible() then return end
    ensureRenderHook(self)
    positionServerGuideItem(self)
end)
