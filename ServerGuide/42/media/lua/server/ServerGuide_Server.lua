--[[
    ServerGuide_Server.lua
    Server side (authoritative). Reads the files in ~/Zomboid/Lua/ServerGuide/,
    builds the tree from index.txt, computes the rules version and answers the
    client's requests. In SP/local host the "server" and the "client" are the
    same process and commands are delivered locally.

    Protocol (see SPEC 6):
      client -> server : requestIndex            -> answers "index"
      client -> server : requestPage {file=...}  -> answers "page" (1+ chunks) or "error"
]]

if not isServer() and not isClient() then
    -- In SP/host this file runs in the same process as the client; ok.
end

ServerGuideServer = ServerGuideServer or {}

------------------------------------------------------------------------
-- File reading
------------------------------------------------------------------------

--- Reads every line of a file under ~/Zomboid/Lua/. Returns an array of lines,
--- or nil if the file does not exist / cannot be opened.
local function readAllLines(luaRelPath)
    local reader = getFileReader(luaRelPath, false)
    if not reader then return nil end
    local lines = {}
    local line = reader:readLine()
    while line ~= nil do
        table.insert(lines, line)
        line = reader:readLine()
    end
    reader:close()
    return lines
end

--- Reads the whole content of a file as a single string (lines joined by \n).
--- Enforces the size limit. Returns content, or nil, reason.
local function readContent(luaRelPath)
    local reader = getFileReader(luaRelPath, false)
    if not reader then return nil, "not found" end
    local parts = {}
    local total = 0
    local line = reader:readLine()
    while line ~= nil do
        total = total + #line + 1
        if total > ServerGuide.MAX_FILE_BYTES then
            reader:close()
            return nil, "too large"
        end
        table.insert(parts, line)
        line = reader:readLine()
    end
    reader:close()
    return table.concat(parts, "\n")
end

-- Server-side cache of the built index payload. Building it scans every page
-- file (existence check + rules hashing), so without this the auto-open poll and
-- page requests would re-scan dozens of files per second on join. That burst of
-- rapid file opens also produced spurious "[ServerGuide] item skipped (missing
-- file)" logs when some opens transiently failed under load (the files are fine,
-- which is why the guide still shows everything). A short TTL absorbs the burst;
-- any write (edit) invalidates the cache so changes show immediately.
local indexPayloadCache = nil
local indexPayloadAt = 0
local INDEX_PAYLOAD_TTL_MS = 1500

local function invalidateIndexCache()
    indexPayloadCache = nil
end

--- Writes content to a file under ~/Zomboid/Lua/ (truncate + overwrite, parent
--- dirs auto-created). Same write pattern as the seeder. Returns true, or nil+reason.
local function writeContent(luaRelPath, content)
    local writer = getFileWriter(luaRelPath, true, false)
    if not writer then return nil, "write failed" end
    writer:write(content)
    writer:close()
    invalidateIndexCache()   -- content changed: next index build must be fresh
    return true
end

------------------------------------------------------------------------
-- Tree + rules version
------------------------------------------------------------------------

--- Loads and validates the index.txt tree. Items whose file is unsafe or
--- missing are dropped (with a log warning), without breaking the UI.
-- @return tree (array of categories with items {title,file})
local function loadTree()
    local lines = readAllLines(ServerGuide.resolve(ServerGuide.INDEX_FILE))
    if not lines then
        print("[ServerGuide] index.txt not found in Lua/" .. ServerGuide.FOLDER .. "/")
        return {}, nil
    end

    local parsed, home = ServerGuide.parseIndex(lines)
    local tree = {}
    local kept = {}   -- file -> true, for validating the home page
    for _, cat in ipairs(parsed) do
        local outCat = { cat = cat.cat, isRules = cat.isRules, items = {} }
        for _, item in ipairs(cat.items) do
            local ok, reason = ServerGuide.isSafeRelativePath(item.file)
            if not ok then
                print("[ServerGuide] item skipped (unsafe path: " .. tostring(reason) ..
                    "): " .. tostring(item.file))
            elseif not ServerGuide.luaFileExists(ServerGuide.resolve(item.file)) then
                print("[ServerGuide] item skipped (missing file): " .. tostring(item.file))
            else
                table.insert(outCat.items, { title = item.title, file = item.file })
                kept[item.file] = true
            end
        end
        table.insert(tree, outCat)
    end

    -- the home page must be a real, kept page; otherwise ignore it
    if home and not kept[home] then
        if home ~= "" then
            print("[ServerGuide] home page ignored (not a listed page): " .. tostring(home))
        end
        home = nil
    end
    return tree, home
end

--- Rules version = hash of the content of every file in the categories marked
--- as rules (see ServerGuide.classifyCategory). Change a file -> change the
--- hash -> the client auto-opens the rules once (SPEC 8.1).
local function computeRulesVersion(tree)
    local seed = 5381
    local any = false
    for _, cat in ipairs(tree) do
        if cat.isRules then
            for _, item in ipairs(cat.items) do
                local content = readContent(ServerGuide.resolve(item.file))
                if content then
                    any = true
                    -- include the path so the hash changes if the order/file changes
                    -- chain numerically (no hex round-trip -- tonumber(hex,16) is unreliable here)
                    seed = ServerGuide.hashNumber(item.file .. "\0" .. content, seed)
                end
            end
        end
    end
    if not any then return "" end
    return string.format("%08x", seed)
end

--- Loads the index.txt tree WITHOUT dropping items whose file is missing/unsafe.
--- Used for editing, so staff can see and fix broken entries instead of having
--- them silently vanish (loadTree, used for viewing, drops them).
local function loadRawTree()
    local lines = readAllLines(ServerGuide.resolve(ServerGuide.INDEX_FILE))
    if not lines then return {} end
    return ServerGuide.parseIndex(lines)
end

--- Canonical version hash of the menu (index.txt), computed from the raw tree's
--- serialised form so the client and server agree on it for optimistic
--- concurrency on menu edits.
local function computeIndexVersion()
    return ServerGuide.hashString(ServerGuide.serializeIndex(loadRawTree()))
end

------------------------------------------------------------------------
-- Command handlers
------------------------------------------------------------------------

--- Builds the payload sent for the "index" command (tree for viewing + the two
--- version hashes used for the rules auto-open and menu-edit concurrency).
local function buildIndexPayload()
    local tree, home = loadTree()
    return {
        rulesVersion = computeRulesVersion(tree),
        indexVersion = computeIndexVersion(),
        tree = tree,
        home = home,
    }
end

--- Cached accessor for the index payload. Rebuilds at most once per TTL (or after
--- an edit invalidates the cache), so a burst of requestIndex/requestPage reuses
--- one file scan instead of re-scanning every page file per command.
local function getIndexPayload()
    local now = getTimestampMs and getTimestampMs() or nil
    if now and indexPayloadCache and (now - indexPayloadAt) < INDEX_PAYLOAD_TTL_MS then
        return indexPayloadCache
    end
    indexPayloadCache = buildIndexPayload()
    indexPayloadAt = now or 0
    return indexPayloadCache
end

--- Answers "index" to the requesting player. Includes a per-player `canEdit`
--- flag (authoritative) so the client shows the edit buttons only to those the
--- SERVER actually allows -- the client can't reliably read its own access level
--- in MP. broadcastIndex omits canEdit (it's not per-player), so each client
--- keeps the value from its own request.
function ServerGuideServer.sendIndex(player)
    local base = getIndexPayload()
    -- build a per-player wrapper so we never write canEdit into the shared cache
    sendServerCommand(player, ServerGuide.MODULE, "index", {
        rulesVersion = base.rulesVersion,
        indexVersion = base.indexVersion,
        tree = base.tree,
        home = base.home,
        canEdit = ServerGuide.isStaff(player),
    })
end

--- Pushes a fresh "index" to everyone after an edit. In MP the no-player form
--- broadcasts to all connected clients; in pure SP there is no network, so we
--- deliver to the local client directly. The editing client also re-requests
--- the index on editResult (see client), so its own refresh never depends on
--- broadcast self-delivery.
function ServerGuideServer.broadcastIndex()
    local payload = getIndexPayload()
    if isServer() then
        sendServerCommand(ServerGuide.MODULE, "index", payload)
    elseif ServerGuideClient and ServerGuideClient.OnServerCommand then
        ServerGuideClient.OnServerCommand(ServerGuide.MODULE, "index", payload)
    end
end

--- Answers "page" (in chunks) or "error" to the requesting player.
function ServerGuideServer.sendPage(player, file)
    local ok, reason = ServerGuide.isSafeRelativePath(file)
    if not ok then
        print("[ServerGuide] requestPage refused (" .. tostring(reason) .. "): " .. tostring(file))
        sendServerCommand(player, ServerGuide.MODULE, "error", { file = file, reason = "invalid path" })
        return
    end

    -- Make sure the file is declared in the index (do not serve arbitrary files).
    -- Uses the cached tree so a page request doesn't re-scan every page file.
    local tree = getIndexPayload().tree
    local declared = false
    for _, cat in ipairs(tree) do
        for _, item in ipairs(cat.items) do
            if item.file == file then declared = true break end
        end
        if declared then break end
    end
    if not declared then
        sendServerCommand(player, ServerGuide.MODULE, "error", { file = file, reason = "not in index" })
        return
    end

    local content, why = readContent(ServerGuide.resolve(file))
    if not content then
        sendServerCommand(player, ServerGuide.MODULE, "error", { file = file, reason = why or "read error" })
        return
    end

    -- Slice into chunks so it does not exceed the network packet limit.
    local size = ServerGuide.CHUNK_SIZE
    local total = math.max(1, math.ceil(#content / size))
    for seq = 1, total do
        local chunk = string.sub(content, (seq - 1) * size + 1, seq * size)
        sendServerCommand(player, ServerGuide.MODULE, "page", {
            file = file,
            seq = seq,
            total = total,
            chunk = chunk,
        })
    end
end

------------------------------------------------------------------------
-- Editing (staff only) -- authoritative writes
------------------------------------------------------------------------

-- In-flight page uploads, keyed by client transaction id.
-- txn -> { file=, total=, parts={}, count=, bytes=, owner=, baseHash=, ts= }
ServerGuideServer.uploads = {}

local function sendEditResult(player, fields)
    sendServerCommand(player, ServerGuide.MODULE, "editResult", fields)
end

--- Drops upload buffers older than ~30s (admin disconnected mid-upload, etc.).
local function pruneUploads()
    local now = getTimestampMs and getTimestampMs() or 0
    if now == 0 then return end
    for txn, buf in pairs(ServerGuideServer.uploads) do
        if now - (buf.ts or now) > 30000 then
            ServerGuideServer.uploads[txn] = nil
        end
    end
end

--- Starter content for a freshly created page file.
local function pageTemplate(title)
    return " <CENTRE> <SIZE:large> " .. (title or "") .. " <LINE><LINE> <LEFT> <SIZE:medium> "
end

--- Final step of a page save: validate and write the assembled content.
local function commitPage(player, buf)
    if not ServerGuide.isStaff(player) then
        sendEditResult(player, { ok = false, op = "savePage", file = buf.file, reason = "not authorized" })
        return
    end
    local ok, why = ServerGuide.isSafeRelativePath(buf.file)
    if not ok then
        sendEditResult(player, { ok = false, op = "savePage", file = buf.file, reason = why })
        return
    end

    local content = table.concat(buf.parts)
    if #content > ServerGuide.MAX_FILE_BYTES then
        sendEditResult(player, { ok = false, op = "savePage", file = buf.file, reason = "too large" })
        return
    end

    -- Optimistic concurrency: reject if the file changed since the editor opened.
    if buf.baseHash and buf.baseHash ~= "" then
        local current = readContent(ServerGuide.resolve(buf.file)) or ""
        if ServerGuide.hashString(current) ~= buf.baseHash then
            sendEditResult(player, { ok = false, op = "savePage", file = buf.file, reason = "stale" })
            return
        end
    end

    local wok, wreason = writeContent(ServerGuide.resolve(buf.file), content)
    if not wok then
        sendEditResult(player, { ok = false, op = "savePage", file = buf.file, reason = wreason })
        return
    end

    print("[ServerGuide] page saved by " .. tostring(player:getUsername()) .. ": " .. buf.file)
    sendEditResult(player, { ok = true, op = "savePage", file = buf.file })
    ServerGuideServer.broadcastIndex()
end

function ServerGuideServer.onSavePageBegin(player, args)
    if not ServerGuide.isStaff(player) then
        print("[ServerGuide] DENIED savePage from " .. tostring(player and player:getUsername()))
        sendEditResult(player, { ok = false, op = "savePage", reason = "not authorized" })
        return
    end
    local file = args and args.file
    local total = args and tonumber(args.total)
    local txn = args and args.txn
    if type(file) ~= "string" or type(txn) ~= "string" or not total then return end

    local ok, why = ServerGuide.isSafeRelativePath(file)
    if not ok then
        sendEditResult(player, { ok = false, op = "savePage", file = file, reason = why })
        return
    end
    if total < 1 or total > ServerGuide.MAX_UPLOAD_CHUNKS then
        sendEditResult(player, { ok = false, op = "savePage", file = file, reason = "bad chunk count" })
        return
    end

    pruneUploads()
    ServerGuideServer.uploads[txn] = {
        file = file, total = total, parts = {}, count = 0, bytes = 0,
        owner = player:getUsername(), baseHash = args.baseHash,
        ts = getTimestampMs and getTimestampMs() or 0,
    }
end

function ServerGuideServer.onSavePageChunk(player, args)
    local txn = args and args.txn
    local seq = args and tonumber(args.seq)
    local chunk = args and args.chunk
    local buf = txn and ServerGuideServer.uploads[txn]
    if not buf then
        sendEditResult(player, { ok = false, op = "savePage", reason = "no transaction" })
        return
    end
    if buf.owner ~= player:getUsername() then return end   -- not your upload
    if not seq or buf.parts[seq] ~= nil then return end     -- bad/duplicate sequence

    chunk = chunk or ""
    buf.parts[seq] = chunk
    buf.count = buf.count + 1
    buf.bytes = buf.bytes + #chunk
    if buf.bytes > ServerGuide.MAX_FILE_BYTES then
        ServerGuideServer.uploads[txn] = nil
        sendEditResult(player, { ok = false, op = "savePage", file = buf.file, reason = "too large" })
        return
    end

    if buf.count >= buf.total then
        ServerGuideServer.uploads[txn] = nil
        commitPage(player, buf)
    end
end

--- Rebuilds index.txt from a full tree sent by the client (whole-tree replace).
--- The menu is tiny so it fits one command; only page CONTENT needs chunking.
function ServerGuideServer.onEditIndex(player, args)
    if not ServerGuide.isStaff(player) then
        print("[ServerGuide] DENIED editIndex from " .. tostring(player and player:getUsername()))
        sendEditResult(player, { ok = false, op = "editIndex", reason = "not authorized" })
        return
    end
    local inTree = args and args.tree
    if type(inTree) ~= "table" then
        sendEditResult(player, { ok = false, op = "editIndex", reason = "bad tree" })
        return
    end

    -- Optimistic concurrency: reject if the menu changed since it was loaded.
    if args.baseVersion and args.baseVersion ~= "" and args.baseVersion ~= computeIndexVersion() then
        sendEditResult(player, { ok = false, op = "editIndex", reason = "stale" })
        return
    end

    -- Sanitise the incoming tree: keep only well-formed, safe entries.
    local clean = {}
    for _, cat in ipairs(inTree) do
        local name = ServerGuide.trim(tostring(cat.cat or ""))
        if name ~= "" then
            local outCat = { cat = name, isRules = not not cat.isRules, items = {} }
            for _, item in ipairs(cat.items or {}) do
                local title = ServerGuide.trim(tostring(item.title or ""))
                local fileRel = ServerGuide.trim(tostring(item.file or ""))
                local safe = ServerGuide.isSafeRelativePath(fileRel)
                if title ~= "" and fileRel ~= "" and safe then
                    table.insert(outCat.items, { title = title, file = fileRel })
                end
            end
            table.insert(clean, outCat)
        end
    end

    -- Resolve the "home" (default page) to write. The editor sends it as a
    -- string ("" = clear); an absent field means an older client, so we preserve
    -- whatever is already on disk. A sent home is only kept if it's a real page
    -- in the sanitised tree.
    local newHome
    if type(args.home) == "string" then
        local h = ServerGuide.trim(args.home)
        newHome = nil
        if h ~= "" then
            for _, cat in ipairs(clean) do
                for _, item in ipairs(cat.items) do
                    if item.file == h then newHome = h break end
                end
                if newHome then break end
            end
        end
    else
        local _, curHome = ServerGuide.parseIndex(readAllLines(ServerGuide.resolve(ServerGuide.INDEX_FILE)) or {})
        newHome = curHome
    end

    local wok, wreason = writeContent(ServerGuide.resolve(ServerGuide.INDEX_FILE),
        ServerGuide.serializeIndex(clean, newHome))
    if not wok then
        sendEditResult(player, { ok = false, op = "editIndex", reason = wreason })
        return
    end

    -- Create a starter file for any referenced page that does not exist yet.
    for _, cat in ipairs(clean) do
        for _, item in ipairs(cat.items) do
            if not ServerGuide.luaFileExists(ServerGuide.resolve(item.file)) then
                writeContent(ServerGuide.resolve(item.file), pageTemplate(item.title))
            end
        end
    end

    print("[ServerGuide] menu edited by " .. tostring(player:getUsername()))
    sendEditResult(player, { ok = true, op = "editIndex" })
    ServerGuideServer.broadcastIndex()
end

ServerGuideServer.OnClientCommand = function(module, command, player, args)
    if module ~= ServerGuide.MODULE then return end

    if command == "requestIndex" then
        ServerGuideServer.sendIndex(player)
    elseif command == "requestPage" then
        local file = args and args.file
        if type(file) == "string" then
            ServerGuideServer.sendPage(player, file)
        end
    elseif command == "savePageBegin" then
        ServerGuideServer.onSavePageBegin(player, args or {})
    elseif command == "savePageChunk" then
        ServerGuideServer.onSavePageChunk(player, args or {})
    elseif command == "editIndex" then
        ServerGuideServer.onEditIndex(player, args or {})
    end
end

Events.OnClientCommand.Add(ServerGuideServer.OnClientCommand)
