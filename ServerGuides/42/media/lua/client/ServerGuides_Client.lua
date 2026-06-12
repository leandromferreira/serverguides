--[[
    ServerGuides_Client.lua
    Client side: data state (tree + rules version + page cache), the
    OnServerCommand handler, chunk reassembly, the rules auto-open (SPEC 8.1)
    and the keyboard shortcut.
]]

if isServer() then return end

ServerGuidesClient = ServerGuidesClient or {}

-- Current tree (array of categories) or nil until received.
ServerGuidesClient.tree = nil
-- Rules version reported by the server.
ServerGuidesClient.rulesVersion = nil
-- Menu (index.txt) version reported by the server -- echoed back on menu edits
-- for optimistic concurrency.
ServerGuidesClient.indexVersion = nil
-- Whether THIS player may edit, as decided authoritatively by the server.
ServerGuidesClient.canEdit = false
-- Cache of already reassembled pages: file -> content (full string).
ServerGuidesClient.pageCache = {}
-- Chunk reassembly buffers: file -> { total=, parts={} }.
ServerGuidesClient.pageBuffers = {}

------------------------------------------------------------------------
-- Requests to the server
------------------------------------------------------------------------

function ServerGuidesClient.requestIndex()
    sendClientCommand(ServerGuides.MODULE, "requestIndex", {})
end

function ServerGuidesClient.requestPage(file)
    -- avoid re-requesting a file we already have cached
    if ServerGuidesClient.pageCache[file] then return end
    sendClientCommand(ServerGuides.MODULE, "requestPage", { file = file })
end

--- Uploads new content for a page (staff only; the server re-validates).
-- Sliced into chunks the same way the server slices when serving (sendPage),
-- because a single command cannot carry a large payload over the network.
-- @param baseHash hash of the content the editor opened with (concurrency guard)
function ServerGuidesClient.savePage(file, content, baseHash)
    content = content or ""
    local txn = tostring(getTimestampMs and getTimestampMs() or 0) .. "_" .. tostring(ZombRand(1000000))
    local size = ServerGuides.CHUNK_SIZE
    local total = math.max(1, math.ceil(#content / size))
    sendClientCommand(ServerGuides.MODULE, "savePageBegin",
        { file = file, total = total, txn = txn, baseHash = baseHash })
    for seq = 1, total do
        local chunk = string.sub(content, (seq - 1) * size + 1, seq * size)
        sendClientCommand(ServerGuides.MODULE, "savePageChunk", { txn = txn, seq = seq, chunk = chunk })
    end
end

--- Sends the full edited menu tree (staff only). The menu is tiny, so it fits a
--- single command. The server sanitises and rewrites index.txt.
function ServerGuidesClient.editIndex(tree)
    sendClientCommand(ServerGuides.MODULE, "editIndex",
        { tree = tree, baseVersion = ServerGuidesClient.indexVersion })
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------

local function onIndex(args)
    ServerGuidesClient.tree = args.tree or {}
    ServerGuidesClient.rulesVersion = args.rulesVersion or ""
    ServerGuidesClient.indexVersion = args.indexVersion or ""
    -- only sendIndex carries canEdit (per-player); broadcasts omit it, so keep
    -- the previously known value when it isn't present
    if args.canEdit ~= nil then ServerGuidesClient.canEdit = args.canEdit == true end
    -- rules content may have changed: clear the cache to reflect it live
    ServerGuidesClient.pageCache = {}
    ServerGuidesClient.pageBuffers = {}

    if ServerGuidesUI.onIndexReady then ServerGuidesUI.onIndexReady() end

    -- One-time rules auto-open per version (SPEC 8.1), if not consumed here yet.
    ServerGuidesClient.tryAutoOpenRules()
end

local function onPage(args)
    local file, seq, total, chunk = args.file, args.seq, args.total, args.chunk
    if type(file) ~= "string" or not seq or not total then return end

    local buf = ServerGuidesClient.pageBuffers[file]
    if not buf then
        buf = { total = total, parts = {} }
        ServerGuidesClient.pageBuffers[file] = buf
    end
    buf.parts[seq] = chunk or ""

    -- complete?
    local count = 0
    for i = 1, buf.total do
        if buf.parts[i] ~= nil then count = count + 1 end
    end
    if count == buf.total then
        local content = table.concat(buf.parts)
        ServerGuidesClient.pageCache[file] = content
        ServerGuidesClient.pageBuffers[file] = nil
        if ServerGuidesUI.instance then
            ServerGuidesUI.instance:onPageReady(file, content)
        end
    end
end

local function onError(args)
    local file = args and args.file or "?"
    local reason = args and args.reason or "?"
    print("[ServerGuides] server error for '" .. tostring(file) .. "': " .. tostring(reason))
    if ServerGuidesUI.instance and ServerGuidesUI.instance.currentFile == file then
        ServerGuidesUI.instance.body.text = " <CENTRE> <RGB:1,0.4,0.4> " ..
            getText("IGUI_ServerGuides_LoadError")
        ServerGuidesUI.instance.body:paginate()
    end
end

--- Result of an edit (save page / edit menu). On success we re-request the index
--- so the editing player refreshes immediately, regardless of broadcast delivery.
local function onEditResult(args)
    if args.ok then
        ServerGuidesClient.requestIndex()
    end
    if ServerGuidesUI.instance and ServerGuidesUI.instance.onEditResult then
        ServerGuidesUI.instance:onEditResult(args)
    end
end

ServerGuidesClient.OnServerCommand = function(module, command, args)
    if module ~= ServerGuides.MODULE then return end
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

Events.OnServerCommand.Add(ServerGuidesClient.OnServerCommand)

------------------------------------------------------------------------
-- Rules auto-open (SPEC 8.1)
------------------------------------------------------------------------

--- Opens the rules once when the version seen in the player's ModData differs
--- from the current one. Server-authoritative: the mark lives in the character's
--- ModData (transmitModData).
function ServerGuidesClient.tryAutoOpenRules()
    local player = getPlayer()
    if not player then return end
    local version = ServerGuidesClient.rulesVersion
    if not version or version == "" then return end   -- no rules category

    local md = player:getModData()
    if md.SG_seenRulesVersion ~= version then
        ServerGuidesUI.openRules()
        md.SG_seenRulesVersion = version
        player:transmitModData()   -- persists on the server (MP); harmless in SP
    end
end

--- On player creation, request the index; the auto-open fires when it arrives.
ServerGuidesClient.OnCreatePlayer = function(playerIndex, player)
    if playerIndex ~= 0 then return end   -- only the main local player
    ServerGuidesClient.requestIndex()
end

Events.OnCreatePlayer.Add(ServerGuidesClient.OnCreatePlayer)
