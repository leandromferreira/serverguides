Put the PNGs used by your guides here (e.g. map.png, logo.png).

In the ServerGuide .txt files (in the server's ~/Zomboid/Lua/ServerGuide/ folder),
reference them by the path STARTING FROM media/ — the mod name is NOT included:

    <IMAGE:media/ui/guias/map.png>
    <IMAGECENTRE:media/ui/guias/map.png,512,512>

Texture names are a FLAT namespace shared across all mods. To avoid colliding with
another mod that has "media/ui/guias/map.png", rename "guias" to something unique to
your server, e.g. media/ui/myserver/map.png.

Size: there is no hard pixel limit (it depends on the GPU), but use power-of-two
dimensions (256/512/1024...) — the game pads other sizes up to the next power of two
in memory. The image is scaled to the width,height in <IMAGECENTRE>, so there is no
point shipping it much larger than you display. Keep the file small (every client
downloads this mod).

This file is just a marker so Git/Workshop keeps the folder. You can delete it after
adding your images.
