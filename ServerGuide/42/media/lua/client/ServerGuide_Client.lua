--[[
    ServerGuide_Client.lua
    Client side: data state (tree + rules version + page cache), the
    OnServerCommand handler, chunk reassembly, the rules auto-open (SPEC 8.1)
    and the keyboard shortcut.
]]

if isServer() then return end

ServerGuideClient = ServerGuideClient or {}

-- Current tree (array of categories) or nil until received.
ServerGuideClient.tree = nil
-- Rules version reported by the server.
ServerGuideClient.rulesVersion = nil
-- Menu (index.txt) version reported by the server -- echoed back on menu edits
-- for optimistic concurrency.
ServerGuideClient.indexVersion = nil
-- Whether THIS player may edit, as decided authoritatively by the server.
ServerGuideClient.canEdit = false
-- Cache of already reassembled pages: file -> content (full string).
ServerGuideClient.pageCache = {}
-- Chunk reassembly buffers: file -> { total=, parts={} }.
ServerGuideClient.pageBuffers = {}

------------------------------------------------------------------------
-- Requests to the server
------------------------------------------------------------------------

function ServerGuideClient.requestIndex()
    sendClientCommand(ServerGuide.MODULE, "requestIndex", {})
end

function ServerGuideClient.requestPage(file)
    -- avoid re-requesting a file we already have cached
    if ServerGuideClient.pageCache[file] then return end
    sendClientCommand(ServerGuide.MODULE, "requestPage", { file = file })
end

--- Uploads new content for a page (staff only; the server re-validates).
-- Sliced into chunks the same way the server slices when serving (sendPage),
-- because a single command cannot carry a large payload over the network.
-- @param baseHash hash of the content the editor opened with (concurrency guard)
function ServerGuideClient.savePage(file, content, baseHash)
    content = content or ""
    local txn = tostring(getTimestampMs and getTimestampMs() or 0) .. "_" .. tostring(ZombRand(1000000))
    local size = ServerGuide.CHUNK_SIZE
    local total = math.max(1, math.ceil(#content / size))
    sendClientCommand(ServerGuide.MODULE, "savePageBegin",
        { file = file, total = total, txn = txn, baseHash = baseHash })
    for seq = 1, total do
        local chunk = string.sub(content, (seq - 1) * size + 1, seq * size)
        sendClientCommand(ServerGuide.MODULE, "savePageChunk", { txn = txn, seq = seq, chunk = chunk })
    end
end

--- Sends the full edited menu tree (staff only). The menu is tiny, so it fits a
--- single command. The server sanitises and rewrites index.txt.
function ServerGuideClient.editIndex(tree)
    sendClientCommand(ServerGuide.MODULE, "editIndex",
        { tree = tree, baseVersion = ServerGuideClient.indexVersion })
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------

local function onIndex(args)
    ServerGuideClient.tree = args.tree or {}
    ServerGuideClient.rulesVersion = args.rulesVersion or ""
    ServerGuideClient.indexVersion = args.indexVersion or ""
    -- only sendIndex carries canEdit (per-player); broadcasts omit it, so keep
    -- the previously known value when it isn't present
    if args.canEdit ~= nil then ServerGuideClient.canEdit = args.canEdit == true end
    -- rules content may have changed: clear the cache to reflect it live
    ServerGuideClient.pageCache = {}
    ServerGuideClient.pageBuffers = {}

    if ServerGuideUI.onIndexReady then ServerGuideUI.onIndexReady() end

    -- Auto-open on join (once per join), unless the player disabled it.
    ServerGuideClient.tryAutoOpen()
end

local function onPage(args)
    local file, seq, total, chunk = args.file, args.seq, args.total, args.chunk
    if type(file) ~= "string" or not seq or not total then return end

    local buf = ServerGuideClient.pageBuffers[file]
    if not buf then
        buf = { total = total, parts = {} }
        ServerGuideClient.pageBuffers[file] = buf
    end
    buf.parts[seq] = chunk or ""

    -- complete?
    local count = 0
    for i = 1, buf.total do
        if buf.parts[i] ~= nil then count = count + 1 end
    end
    if count == buf.total then
        local content = table.concat(buf.parts)
        ServerGuideClient.pageCache[file] = content
        ServerGuideClient.pageBuffers[file] = nil
        if ServerGuideUI.instance then
            ServerGuideUI.instance:onPageReady(file, content)
        end
    end
end

local function onError(args)
    local file = args and args.file or "?"
    local reason = args and args.reason or "?"
    print("[ServerGuide] server error for '" .. tostring(file) .. "': " .. tostring(reason))
    if ServerGuideUI.instance and ServerGuideUI.instance.currentFile == file then
        ServerGuideUI.instance.body.text = " <CENTRE> <RGB:1,0.4,0.4> " ..
            getText("IGUI_ServerGuide_LoadError")
        ServerGuideUI.instance.body:paginate()
    end
end

--- Result of an edit (save page / edit menu). On success we re-request the index
--- so the editing player refreshes immediately, regardless of broadcast delivery.
local function onEditResult(args)
    if args.ok then
        ServerGuideClient.requestIndex()
    end
    if ServerGuideUI.instance and ServerGuideUI.instance.onEditResult then
        ServerGuideUI.instance:onEditResult(args)
    end
end

ServerGuideClient.OnServerCommand = function(module, command, args)
    if module ~= ServerGuide.MODULE then return end
    if command == "index" then
        onIndex(args or {})
    elseif command == "page" then
        onPage(args or {})
    elseif command == "error" then
        onError(args or {})
    elseif command == "editResult" then
        onEditResult(args or {})
    end
end

Events.OnServerCommand.Add(ServerGuideClient.OnServerCommand)

------------------------------------------------------------------------
-- Auto-open on join (per-player opt-out)
------------------------------------------------------------------------

-- Set on join, cleared after the first index reply so the window opens ONCE per
-- join -- not again on later index refreshes (edits, manual reopen).
ServerGuideClient.pendingAutoOpen = false

--- Is the "open on join" behaviour enabled for this player? Default: ON.
-- Stored per character in the player's ModData (server-authoritative in MP).
function ServerGuideClient.isAutoOpenEnabled()
    local player = getPlayer()
    if not player then return true end
    return player:getModData().SG_autoOpen ~= false
end

--- Sets the player's "open on join" preference and persists it.
function ServerGuideClient.setAutoOpenEnabled(enabled)
    local player = getPlayer()
    if not player then return end
    player:getModData().SG_autoOpen = enabled and true or false
    player:transmitModData()   -- persists on the server (MP); harmless in SP
end

--- Opens the window automatically on join, unless the player disabled it.
-- Guarded by pendingAutoOpen so later index refreshes don't reopen it.
function ServerGuideClient.tryAutoOpen()
    if not ServerGuideClient.pendingAutoOpen then return end
    ServerGuideClient.pendingAutoOpen = false
    if not ServerGuideClient.isAutoOpenEnabled() then return end
    ServerGuideUI.openRules()
end

--- Polls for the index until the reply arrives (which runs tryAutoOpen and
--- clears pendingAutoOpen). On MP join, OnCreatePlayer can fire before the
--- client/server command channel is ready, so the first requestIndex may be
--- dropped and no reply ever comes -- we re-request periodically for a while.
local autoOpenTicks = 0
local function autoOpenPoll()
    if not ServerGuideClient.pendingAutoOpen then
        Events.OnTick.Remove(autoOpenPoll)   -- opened (or disabled): done
        return
    end
    autoOpenTicks = autoOpenTicks + 1
    if autoOpenTicks % 30 == 1 then          -- (re)request roughly every 30 ticks
        ServerGuideClient.requestIndex()
    end
    if autoOpenTicks > 300 then              -- give up after ~300 ticks
        ServerGuideClient.pendingAutoOpen = false
        Events.OnTick.Remove(autoOpenPoll)
    end
end

--- On player creation, arm the auto-open and start polling for the index; the
--- window opens when the reply arrives (unless the player disabled it).
ServerGuideClient.OnCreatePlayer = function(playerIndex, player)
    if playerIndex ~= 0 then return end   -- only the main local player
    ServerGuideClient.pendingAutoOpen = true
    autoOpenTicks = 0
    ServerGuideClient.requestIndex()
    Events.OnTick.Remove(autoOpenPoll)    -- avoid double registration
    Events.OnTick.Add(autoOpenPoll)
end

Events.OnCreatePlayer.Add(ServerGuideClient.OnCreatePlayer)
