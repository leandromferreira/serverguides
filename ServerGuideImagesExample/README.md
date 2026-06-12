# ServerGuide Images Example

**Steam Workshop:** [ServerGuide Images Example](https://steamcommunity.com/sharedfiles/filedetails/?id=3743487241) · requires [Server Guide](https://steamcommunity.com/sharedfiles/filedetails/?id=3743488819)

A **template** mod for server owners who want to use **images** in their
[ServerGuide](../ServerGuide) pages. It contains no Lua — just packed images.

## Why a separate mod?

The `<IMAGE:name>` tag is resolved on the viewer's machine (the client) by the
game's resource system (`getTexture` → `activeFileMap`). Images dropped **loose**
in the server folder (`~/Zomboid/Lua/ServerGuide/`) do **not** render:

- In MP, only **text** travels over the network; the image bytes never reach the client.
- Even in SP, `~/Zomboid/Lua/` is not part of the game's texture map.

A **mod's** `media/` folder is the only one that (a) is scanned into the texture
map and (b) is synced to the client. That's why images ship in a mod.

## How to use

1. Duplicate this folder and rename it (`name` and `id` in `42/mod.info`) to your own.
2. Put your PNGs in `42/media/ui/guias/` (or `common/media/ui/guias/`).
3. In the ServerGuide `.txt` pages, reference them by the path **starting from `media/`**.

## Image size

There is no hard pixel limit (it's bounded by the GPU's max texture size, normally
well above 4096px), but for performance:

- Use **power-of-two** dimensions (256, 512, 1024…). The game pads any other size
  up to the next power of two in video memory (`getNextPowerOfTwoHW`) — a 513px
  image costs as much as 1024px.
- The image is scaled to the **`width,height` you pass in `<IMAGECENTRE:…,w,h>`**;
  don't ship a file much larger than you actually display.
- Keep dimensions at/under ~2048px to be safe on older GPUs, and keep the file
  small: every client downloads this mod.

## Tag path rules (important)

- **The mod name is NOT part of the path.** The registered key is relative to the
  mod base (`common/`/`42/`). A PNG at `<mod>/42/media/ui/guias/map.png` is
  registered as `media/ui/guias/map.png`.
  - ✅ `<IMAGE:media/ui/guias/map.png>`
  - ❌ `<IMAGE:ServerGuideImagesExample/media/ui/guias/map.png>` (no such key → empty)
- **Flat namespace.** Texture names are shared across all mods; files with the same
  path collide (the game logs `mod "X" overrides ...`). Use a unique subfolder, e.g.
  `media/ui/myserver/map.png`.
- **Absolute paths don't work.** `<IMAGE:/home/.../Zomboid/Lua/...>` resolves on the
  client, which doesn't have the file (in MP). Always use the `media/`-relative name.

## Multiplayer requirement

For the images to reach players in MP, this mod (your copy) must be **published on
the Steam Workshop** and listed under `WorkshopItems` in the server config. **Local**
mods (in the server's `~/Zomboid/mods`) are **not** sent to the client. In
singleplayer / local host, a local mod is enough.

## mod.info (`42/mod.info`)

```
name=ServerGuide Images Example
id=ServerGuideImagesExample
poster=poster.png
pzversion=42.0
require=ServerGuide
description=Template for server owners to publish images used in ServerGuide pages.
```

## Layout

```
ServerGuideImagesExample/
  42/
    mod.info                     # require=ServerGuide
    media/ui/guias/
      (your PNGs here)
  README.md
```
