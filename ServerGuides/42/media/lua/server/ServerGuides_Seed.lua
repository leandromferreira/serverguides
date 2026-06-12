--[[
    ServerGuides_Seed.lua
    Auto-seed: the first time (if ~/Zomboid/Lua/ServerGuides/index.txt does NOT
    exist yet), creates the folder and writes the template files bundled in the
    mod (the mod's "texts/" folder). Idempotent: never overwrites existing content.

    Only runs where the folder is actually read (dedicated server, coop host or
    SP); on a pure MP client it does nothing (the client never reads disk -- SPEC 2).

    APIs (verified in LuaManager.java):
      getFileWriter(file, createIfNull, append)  -> writes to ~/Zomboid/Lua/, creates parent dirs
      getModFileReader(modId, "texts/<f>", false) -> reads from inside the mod (42/ or common/)
      listFilesInModDirectory(modId, "texts")     -> names of the template files
]]

ServerGuidesSeed = ServerGuidesSeed or {}

-- Subfolder inside the mod that holds the template files.
local MOD_TEXTS_DIR = "texts"

--- Reads the whole content of a mod template file as a string (lines joined by \n).
local function readModFile(name)
    local reader = getModFileReader(ServerGuides.MODULE, MOD_TEXTS_DIR .. "/" .. name, false)
    if not reader then return nil end
    local parts = {}
    local line = reader:readLine()
    while line ~= nil do
        table.insert(parts, line)
        line = reader:readLine()
    end
    reader:close()
    return table.concat(parts, "\n")
end

--- Seeds if needed. Returns true if it seeded, false if it skipped.
function ServerGuidesSeed.run()
    -- a pure MP client writes nothing
    if isClient() and not isServer() then return false end

    -- content already there? don't touch anything
    if ServerGuides.luaFileExists(ServerGuides.resolve(ServerGuides.INDEX_FILE)) then
        return false
    end

    local names = listFilesInModDirectory(ServerGuides.MODULE, MOD_TEXTS_DIR)
    if not names or names:size() == 0 then
        print("[ServerGuides] seed: no template files in the mod's " .. MOD_TEXTS_DIR .. "/")
        return false
    end

    -- dedupe (listFilesInModDirectory merges common/ and 42/)
    local seen = {}
    local count = 0
    for i = 0, names:size() - 1 do
        local name = names:get(i)
        -- only validate the name's safety (one level, no subfolders)
        local ok = ServerGuides.isSafeRelativePath(name)
        if ok and not seen[name] then
            seen[name] = true
            local content = readModFile(name)
            if content then
                local writer = getFileWriter(ServerGuides.resolve(name), true, false)
                if writer then
                    writer:write(content)
                    writer:close()
                    count = count + 1
                else
                    print("[ServerGuides] seed: failed to write " .. name)
                end
            end
        end
    end

    print(string.format("[ServerGuides] folder Lua/%s/ created with %d template file(s).",
        ServerGuides.FOLDER, count))
    return true
end

-- Dedicated server / coop host.
Events.OnServerStarted.Add(function()
    ServerGuidesSeed.run()
end)

-- Singleplayer / local host (OnServerStarted does not fire in SP).
Events.OnGameStart.Add(function()
    ServerGuidesSeed.run()
end)
