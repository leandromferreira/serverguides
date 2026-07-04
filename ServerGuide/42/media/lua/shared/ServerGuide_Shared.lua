--[[
    ServerGuide_Shared.lua
    Constants, path validation, hash and the index.txt parser.

    Loaded in every context (shared). Disk reading/parsing only runs on the
    server (see ServerGuide_Server.lua); this file holds only pure functions
    plus the parser that the server reuses.
]]

ServerGuide = ServerGuide or {}

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

-- Network command module (sendClientCommand/sendServerCommand).
ServerGuide.MODULE = "ServerGuide"

-- Root folder, relative to ~/Zomboid/Lua/  (getLuaCacheDir()).
ServerGuide.FOLDER = "ServerGuide"

-- Manifest file name inside the folder.
ServerGuide.INDEX_FILE = "index.txt"

-- Per-file size limit for content (bytes). Above this the file is refused.
ServerGuide.MAX_FILE_BYTES = 256 * 1024

-- Size of each page chunk sent over the network (characters). Content is sliced
-- so it does not exceed PZ's packet limit, and reassembled on the client.
ServerGuide.CHUNK_SIZE = 8 * 1024

-- Upper bound on the number of chunks a single upload may declare. Guards the
-- server against a client claiming an absurd chunk count to force a huge alloc.
ServerGuide.MAX_UPLOAD_CHUNKS = math.ceil(ServerGuide.MAX_FILE_BYTES / ServerGuide.CHUNK_SIZE) + 1

------------------------------------------------------------------------
-- Access control (who may edit guides)
------------------------------------------------------------------------

-- Default list of access levels allowed to edit (used if the sandbox option is
-- empty/unavailable). getAccessLevel() returns a lowercase role name in B42.
ServerGuide.DEFAULT_EDIT_LEVELS = "admin;moderator;overseer;gm"

--- Set { level = true } of the access levels allowed to edit, parsed from the
--- sandbox string option "EditAccessLevels" (a list separated by ";" or ",",
--- case-insensitive, whitespace trimmed). Configured per server in the Sandbox
--- Options (page "Server Guide").
function ServerGuide.editLevelSet()
    local raw = (SandboxVars and SandboxVars.ServerGuide and SandboxVars.ServerGuide.EditAccessLevels)
    if not raw or ServerGuide.trim(raw) == "" then raw = ServerGuide.DEFAULT_EDIT_LEVELS end
    local set = {}
    for token in string.gmatch(raw, "[^;,]+") do
        local t = string.lower(ServerGuide.trim(token))
        if t ~= "" then set[t] = true end
    end
    return set
end

--- Is editing enabled for this access level by the sandbox option?
function ServerGuide.levelCanEdit(lvl)
    if not lvl or lvl == "" then return false end
    return ServerGuide.editLevelSet()[lvl] == true
end

--- Is this player allowed to edit?
-- Used on BOTH sides: the client to show the Edit button (cosmetic) and the
-- server to authorise writes (authoritative -- the only check that matters).
-- Order matters:
--   * the local owner of the files always edits -- pure singleplayer
--     (isClient() and isServer() both false) and the co-op host's OWN player
--     (isServer() and player == getPlayer());
--   * everyone else must hold an access level that is ENABLED in the sandbox
--     options (ServerGuide.levelCanEdit).
-- This does NOT blanket-allow on a dedicated server (getPlayer() is nil there,
-- remote players never equal it) nor on a pure MP client (isServer() is false),
-- so only sandbox-enabled staff can edit in those cases.
function ServerGuide.isStaff(player)
    if not player then return false end
    if not isClient() and not isServer() then return true end          -- pure SP
    if isServer() and getPlayer() and player == getPlayer() then        -- co-op host's own player
        return true
    end
    local lvl = player.getAccessLevel and player:getAccessLevel() or ""
    lvl = string.lower(ServerGuide.trim(lvl or ""))
    return ServerGuide.levelCanEdit(lvl)
end

------------------------------------------------------------------------
-- Path security validation
------------------------------------------------------------------------

--- Validates a file path referenced in the index.
-- Rejects: empty, containing "..", a leading (back)slash, or an absolute path
-- (e.g. "C:\" or "/etc"). Valid paths are always relative to ServerGuide/.
-- @return true if safe; otherwise false, reason
function ServerGuide.isSafeRelativePath(path)
    if type(path) ~= "string" or path == "" then
        return false, "empty path"
    end
    if string.find(path, "%.%.") then
        return false, "contains '..'"
    end
    -- leading (back)slash = attempt at an absolute/root path
    local first = string.sub(path, 1, 1)
    if first == "/" or first == "\\" then
        return false, "leading slash"
    end
    -- Windows drive letter (e.g. "C:")
    if string.find(path, "^%a:") then
        return false, "absolute drive path"
    end
    return true
end

--- Full path (relative to ~/Zomboid/Lua/) of a ServerGuide file.
function ServerGuide.resolve(relPath)
    return ServerGuide.FOLDER .. "/" .. relPath
end

--- Does a file exist under ~/Zomboid/Lua/ ? (server-side use)
-- NOTE: do NOT use the global fileExists() for this -- it resolves through the
-- resource map (getString), not the Lua cache dir, so it returns false for files
-- written under ~/Zomboid/Lua/. getFileReader resolves the correct base.
function ServerGuide.luaFileExists(luaRelPath)
    local reader = getFileReader(luaRelPath, false)
    if reader then
        reader:close()
        return true
    end
    return false
end

------------------------------------------------------------------------
-- Hash (djb2) -- used for the "rules version"
------------------------------------------------------------------------

--- Stable hash of a string (djb2 with 32-bit arithmetic) as a NUMBER (0..2^32-1).
-- Use this when chaining hashes, so we never round-trip through a hex string
-- (tonumber(hex, 16) is unreliable on PZ's Lua VM and returns nil).
function ServerGuide.hashNumber(str, seed)
    local h = seed or 5381
    for i = 1, #str do
        -- h = h * 33 + byte ; kept within unsigned 32 bits
        h = (h * 33 + string.byte(str, i)) % 4294967296
    end
    return h
end

--- Same hash, formatted as an 8-char hex string (for version ids / comparisons).
function ServerGuide.hashString(str, seed)
    return string.format("%08x", ServerGuide.hashNumber(str, seed))
end

------------------------------------------------------------------------
-- String util
------------------------------------------------------------------------

function ServerGuide.trim(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

--- Does the category count as "rules" (for the auto-open, SPEC 8)?
-- Rule: a section name prefixed with "*" (e.g. [*Rules]) marks it explicitly;
-- or the name matches "regras"/"rules" (case-insensitive).
-- Returns isRules, cleanName.
function ServerGuide.classifyCategory(rawName)
    local name = ServerGuide.trim(rawName)
    local isRules = false
    if string.sub(name, 1, 1) == "*" then
        isRules = true
        name = ServerGuide.trim(string.sub(name, 2))
    end
    local lower = string.lower(name)
    if lower == "regras" or lower == "rules" then
        isRules = true
    end
    return isRules, name
end

------------------------------------------------------------------------
-- index.txt parser
------------------------------------------------------------------------

--- Parses the manifest lines into a tree.
-- @param lines  array of lines (without \n)
-- @return tree  array of { cat=<string>, isRules=<bool>, items={ {title=,file=}, ... } }
-- @return home  the default/landing page (a file path) declared by a top-level
--               "home = file.txt" line (aliases: default, inicial), or nil
-- Blank lines and lines starting with "#" are ignored.
-- "[Section]" opens a category; "Title = file.txt" adds a page.
-- A "home = file.txt" line BEFORE any section sets the default page; other
-- top-level "key = value" pairs are ignored.
function ServerGuide.parseIndex(lines)
    local tree = {}
    local current = nil
    local home = nil

    for _, raw in ipairs(lines) do
        local line = ServerGuide.trim(raw)
        if line == "" or string.sub(line, 1, 1) == "#" then
            -- skip blank lines and comments
        elseif string.sub(line, 1, 1) == "[" and string.sub(line, -1) == "]" then
            local rawName = string.sub(line, 2, -2)
            local isRules, name = ServerGuide.classifyCategory(rawName)
            current = { cat = name, isRules = isRules, items = {} }
            table.insert(tree, current)
        else
            local key, value = string.match(line, "^(.-)=(.*)$")
            if key then
                key = ServerGuide.trim(key)
                value = ServerGuide.trim(value)
                local lkey = string.lower(key)
                if current == nil then
                    -- top-level: only the "home" directive is meaningful
                    if value ~= "" and (lkey == "home" or lkey == "default" or lkey == "inicial") then
                        home = value
                    end
                elseif key ~= "" and value ~= "" then
                    table.insert(current.items, { title = key, file = value })
                end
            end
        end
    end

    return tree, home
end

--- Serialises a tree back into index.txt text (the inverse of parseIndex).
-- Produces a clean, well-formed manifest with a generated header. Manual
-- comments are NOT preserved (by design): editing the menu in-game regenerates
-- this file.
-- The "*" rules marker is only emitted when the category is rules AND its name
-- is not already an implicit rules name ("rules"/"regras"), so we never write a
-- redundant or double marker. Mirrors classifyCategory's semantics.
-- @param tree array of { cat=, isRules=, items={ {title=,file=}, ... } }
-- @param home optional default/landing page (file path); re-emitted as a
--             top-level "home =" line so in-game menu edits don't drop it
-- @return content string (lines joined by \n, no trailing newline)
function ServerGuide.serializeIndex(tree, home)
    local out = {}
    table.insert(out, "# index.txt - gerado pelo editor do ServerGuide.")
    table.insert(out, "# Edicoes feitas no jogo sobrescrevem este arquivo;")
    table.insert(out, "# comentarios e formatacao manual nao sao preservados.")
    table.insert(out, "# [Secao] = categoria ; \"Titulo = arquivo.txt\" = pagina.")
    table.insert(out, "# home = arquivo.txt  -> pagina aberta por padrao.")
    table.insert(out, "")
    if home and home ~= "" then
        table.insert(out, "home = " .. home)
        table.insert(out, "")
    end

    for _, cat in ipairs(tree) do
        local name = cat.cat or ""
        if cat.isRules then
            -- only add "*" if the name is not already implicitly rules
            local implicit = select(1, ServerGuide.classifyCategory(name))
            if not implicit then name = "*" .. name end
        end
        table.insert(out, "[" .. name .. "]")
        for _, item in ipairs(cat.items or {}) do
            table.insert(out, (item.title or "") .. " = " .. (item.file or ""))
        end
        table.insert(out, "")
    end

    return table.concat(out, "\n")
end
