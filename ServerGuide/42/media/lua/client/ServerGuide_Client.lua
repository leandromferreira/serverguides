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

    -- One-time rules auto-open per version (SPEC 8.1), if not consumed here yet.
    ServerGuideClient.tryAutoOpenRules()
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
-- Rules auto-open (SPEC 8.1)
------------------------------------------------------------------------

--- Opens the rules once when the version seen in the player's ModData differs
--- from the current one. Server-authoritative: the mark lives in the character's
--- ModData (transmitModData).
function ServerGuideClient.tryAutoOpenRules()
    local player = getPlayer()
    if not player then return end
    local version = ServerGuideClient.rulesVersion
    if not version or version == "" then return end   -- no rules category

    local md = player:getModData()
    if md.SG_seenRulesVersion ~= version then
        ServerGuideUI.openRules()
        md.SG_seenRulesVersion = version
        player:transmitModData()   -- persists on the server (MP); harmless in SP
    end
end

--- On player creation, request the index; the auto-open fires when it arrives.
ServerGuideClient.OnCreatePlayer = function(playerIndex, player)
    if playerIndex ~= 0 then return end   -- only the main local player
    ServerGuideClient.requestIndex()
end

Events.OnCreatePlayer.Add(ServerGuideClient.OnCreatePlayer)
