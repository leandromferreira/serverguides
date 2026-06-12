# Server Guides (Project Zomboid B42)

A mod that lets the **server owner** publish **guides and rules** that players
read inside the game, in a window with a side menu and formatted text. The
content lives in a folder on the server and is **streamed live**: edit it (from
the **in-game UI** as staff, or directly in the files) and players see the new
version the next time they open the window.

> For a **regular player** it's a **read-only** viewer: open, read, close. There
> is no "I have read and agree" gate or any blocking. **Staff**
> (admin/moderator/overseer/gm, plus the host in SP/co-op) gets **in-game editing**
> buttons — see [In-game editing (staff)](#in-game-editing-staff). See `SPEC.md`
> for the full design.

## Content setup (admin)

1. Enable the **ServerGuides** mod on the server (and on clients in MP — via the
   Workshop).
2. **On first run**, if the folder doesn't exist yet, the mod automatically
   creates
   ```
   ~/Zomboid/Lua/ServerGuides/
   ```
   (on Windows: `C:\Users\<you>\Zomboid\Lua\ServerGuides\`) and fills it with the
   template files from [`ServerGuides/common/texts/`](ServerGuides/common/texts).
   The auto-seed only runs on the hosting machine (dedicated server, co-op host or
   SP) and **never overwrites** existing content — it only acts if `index.txt` is
   missing.
3. Edit the `.txt` files freely. Always save as **UTF-8**.

Reading is done **only by the server**; the client never reads the disk — it only
receives text over the network. In singleplayer / local host, the same machine
plays both roles.

## Server-side layout

```
~/Zomboid/Lua/ServerGuides/
  index.txt            # menu tree manifest (required)
  rules_general.txt    # content (ISRichTextPanel tags)
  rules_pvp.txt
  guide_start.txt
  guide_bases.txt
```

> The template files ship in English; replace the content with your server's
> language.

### `index.txt`

```ini
# [Section] = top-level category ; "Title = file.txt" = clickable page
[Rules]
General = rules_general.txt
PvP     = rules_pvp.txt

[Guides]
Quick start = guide_start.txt
Base map    = guide_bases.txt
```

- Order is preserved; the title is free (independent of the file name).
- A missing file is omitted (with a log warning), without breaking the UI.
- The **[Rules]** section (or **[Regras]**, or any `[*Name]`) is treated as
  **rules**: changing its content makes the window **open by itself once** on the
  player's next join (tracked by version/hash in the character's ModData).

### Content format (native `ISRichTextPanel` tags)

| Tag | Effect |
|---|---|
| `<LINE>` | line break |
| `<SIZE:small\|medium\|large>` | font size |
| `<RGB:r,g,b>` | text color (0..1) |
| `<PUSHRGB:r,g,b>` / `<POPRGB>` | push/pop color |
| `<RED>` `<GREEN>` `<ORANGE>` | quick colors |
| `<CENTRE>` `<LEFT>` `<RIGHT>` | alignment |
| `<INDENT:n>` / `<SETX:n>` | indent / X position |
| `<SPACE>` | space |
| `<IMAGE:name>` / `<IMAGECENTRE:name,w,h>` | image (see below) |

## How players open it

- **"Server Guides" item** in the in-game pause menu (Esc), next to Continue/Quit.
- **Auto-open** of the rules once whenever the admin changes the rules content.

## In-game editing (staff)

Anyone with a **staff** access level (`admin`, `moderator`, `overseer`, `gm` — plus
the host in SP/co-op) sees two extra buttons in the window:

- **Edit** — enters edit mode on the open page: a text field with the raw markup
  (the `ISRichTextPanel` tags). On **Save**, the content is uploaded over the
  network (sliced into chunks) and the **server writes** the `.txt`; the change
  goes live for everyone (the window re-fetches the page).
- **Edit menu** — opens an editor for `index.txt`: create / rename / remove
  categories and pages, mark a category as **Rules**, and reorder. On save, the
  server rewrites `index.txt` and creates the starting `.txt` for each new page.

Details and limits:

- **Who can edit is configurable** in *Sandbox Options → Server Guides*, in the
  **"Access levels allowed to edit"** field: a `;`-separated list (default
  `admin;moderator;overseer;gm`). Leave empty to allow none. The **host** (SP/co-op)
  can always edit — they own the files.
- **Server is authoritative**: the button is cosmetic; every write is re-validated
  on the server (access level vs. the sandbox option, safe path, 256 KB limit). A
  client without permission can't write even by forging commands.
- **Removing** a page/category only drops it from the menu — the `.txt` file
  **stays** on disk (nothing is deleted by accident; you can re-add it later).
- Editing the menu **rewrites** `index.txt` with a generated header; **manual
  comments and formatting are not preserved**.
- A new page's file name is derived from the title (and made unique); the title
  stays independent of the file name.
- **Optimistic editing**: if another staff member changes the same page/menu while
  you're editing, the save is rejected ("content changed on the server") — reopen
  and redo.

## Images

The text is served live, but the **image is not**: it must be packed into the
`media/` folder of a loaded mod (registered in the texture map and synced to the
client) and is referenced by **name**, with the `media/` prefix.

This mod ships a demo image in
[`ServerGuides/common/media/ui/guias/poster.png`](ServerGuides/common/media/ui/guias),
used by the `guide_images.txt` guide via `<IMAGECENTRE:media/ui/guias/poster.png,256,256>`.

To use **your own** images without editing this mod, pack them into a separate mod
and reference them by name — see the example mod
[`ServerGuidesImagesExample`](../ServerGuidesImagesExample). In multiplayer the mod
with the images must be on the **Workshop** (local mods don't sync to the client).

## Limits

- Maximum size per file: **256 KB** (rejected above that).
- Large content is sliced into chunks over the network and reassembled on the
  client automatically.

## Languages

English and Português (Brasil) — UI strings and sandbox option strings.

## Mod files

B42 multi-version layout: each base folder (`42/` for the version and `common/`
for the shared part) has its own `media/`. The game lists the mod because of
`42/mod.info` and loads the `media/` of **both** (`common/` + `42/`), with the
version overriding the common one (`ZomboidFileSystem`).

```
ServerGuides/                      # mod folder (goes in ~/Zomboid/mods/)
  42/
    mod.info
    media/
      sandbox-options.txt          # "access levels allowed to edit" option (page Server Guides)
      lua/
       shared/
        ServerGuides_Shared.lua    # constants, isStaff/sandbox, path validation, hash, index parser/serializer
        Translate/EN/*, Translate/PTBR/*   # UI strings (IG_UI.json) and sandbox option strings (Sandbox.json)
       server/
        ServerGuides_Server.lua    # OnClientCommand: index/page, rulesVersion, validation, chunking, editing (savePage/editIndex)
        ServerGuides_Seed.lua      # first run: creates Lua/ServerGuides/ and writes the texts/ templates
       client/
        ServerGuides_UI.lua        # window + inline edit mode (ISCollapsableWindow + listbox + rich text)
        ServerGuides_IndexEditor.lua # menu/index editor (CRUD of categories and pages)
        ServerGuides_Client.lua    # OnServerCommand, cache/reassembly, auto-open, edit senders
        ServerGuides_ESCMenu.lua   # item in the in-game pause menu (native style)
  common/
    media/ui/guias/poster.png      # demo image (loaded as media/ui/guias/poster.png)
    texts/                         # template content to copy into ~/Zomboid/Lua/ServerGuides/
README.md / SPEC.md                # docs (at the repo root, outside the mod)
STEAM_DESC.bbcode                  # Workshop description (BBCode), outside the mod
```

## Permissions for Modders

**Ask for permission.**

This mod may **not** be included in modpacks, collections distributed as a single
download, or any form of redistribution without the express permission of the
original creator. Extensions and patches are also subject to this restriction.
Having received permission, credit must be given to the original creator both
within the mod files and wherever the mod is published online.

## Copyright

**Copyright 2026 Leandro Ferreira.** This item is not authorized for posting on
Steam, except under the Steam account named leozimmelo.

All rights reserved. This mod may not be reuploaded, mirrored, or included in
modpacks or collections distributed as a single download without the express
written permission of the original creator.
