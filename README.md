# Server Guides (Project Zomboid B42)

Mod que permite ao **dono do servidor** publicar **guias e regras** que os
jogadores leem dentro do jogo, numa janela com menu lateral e texto formatado.
O conteúdo fica numa pasta no servidor e é **transmitido ao vivo**: edite (pela
**própria UI in-game**, sendo staff, ou direto nos arquivos), o jogador reabre a
janela e vê a versão nova.

> Para o **jogador comum** é um visualizador **somente-consulta**: abre, lê e fecha.
> Não há "Li e concordo" nem qualquer bloqueio. **Staff** (admin/moderator/overseer/gm,
> e o host em SP/coop) ganha botões de **edição in-game** — veja
> [Edição in-game (staff)](#edição-in-game-staff). Ver `SPEC.md` para o design completo.

## Instalação do conteúdo (admin)

1. Ative o mod **ServerGuides** no servidor (e nos clientes, em MP — via Workshop).
2. **Na primeira execução**, se a pasta ainda não existir, o mod cria
   automaticamente
   ```
   ~/Zomboid/Lua/ServerGuides/
   ```
   (No Windows: `C:\Users\<você>\Zomboid\Lua\ServerGuides\`) e a preenche com os
   arquivos-modelo de [`ServerGuides/common/texts/`](ServerGuides/common/texts).
   O auto-seed só roda na máquina que hospeda (servidor dedicado, host de coop ou
   SP) e **nunca sobrescreve** conteúdo existente — só age se `index.txt` faltar.
3. Edite os `.txt` à vontade. Salve sempre em **UTF-8**.

A leitura é feita **só pelo servidor**; o cliente nunca lê o disco — recebe apenas
texto pela rede. Em singleplayer/host local, a mesma máquina faz os dois papéis.

## Estrutura no servidor

```
~/Zomboid/Lua/ServerGuides/
  index.txt            # manifesto da árvore de menus (obrigatório)
  rules_general.txt    # conteúdo (tags do ISRichTextPanel)
  rules_pvp.txt
  guide_start.txt
  guide_bases.txt
```

> Os arquivos-modelo já vêm em inglês; troque o conteúdo pelo idioma do seu servidor.

### `index.txt`

```ini
# [Section] = categoria de topo ; "Title = file.txt" = página clicável
[Rules]
General = rules_general.txt
PvP     = rules_pvp.txt

[Guides]
Quick start = guide_start.txt
Base map    = guide_bases.txt
```

- A ordem é preservada; o título é livre (independe do nome do arquivo).
- Arquivo ausente é omitido (com aviso no log), sem quebrar a UI.
- A seção **[Rules]** (ou **[Regras]**, ou qualquer `[*Nome]`) é tratada como
  **regras**: mudar o conteúdo dela faz a janela **abrir sozinha 1x** na próxima
  entrada do jogador (controle por versão/hash no ModData do personagem).

### Formato do conteúdo (tags nativas do `ISRichTextPanel`)

| Tag | Efeito |
|---|---|
| `<LINE>` | quebra de linha |
| `<SIZE:small\|medium\|large>` | tamanho da fonte |
| `<RGB:r,g,b>` | cor do texto (0..1) |
| `<PUSHRGB:r,g,b>` / `<POPRGB>` | empilha/desempilha cor |
| `<RED>` `<GREEN>` `<ORANGE>` | cores rápidas |
| `<CENTRE>` `<LEFT>` `<RIGHT>` | alinhamento |
| `<INDENT:n>` / `<SETX:n>` | recuo / posição X |
| `<SPACE>` | espaço |
| `<IMAGE:nome>` / `<IMAGECENTRE:nome,w,h>` | imagem (ver abaixo) |

## Como o jogador abre

- **Item "Guias do Servidor"** no menu ESC in-game (junto de Continuar/Sair).
- **Auto-open** das regras 1x sempre que o admin alterar o conteúdo das regras.

## Edição in-game (staff)

Quem tem acesso de **staff** (`admin`, `moderator`, `overseer`, `gm` — e o host em
SP/coop) vê dois botões extras na janela:

- **Editar** — entra em modo de edição na página aberta: um campo de texto com o
  markup cru (as tags do `ISRichTextPanel`). Ao **Salvar**, o conteúdo sobe pela rede
  (fatiado em chunks) e o **servidor grava** o `.txt`; a mudança aparece ao vivo para
  todos (a janela rebusca a página).
- **Editar menu** — abre um editor do `index.txt`: criar / renomear / remover
  categorias e páginas, marcar uma categoria como **Regras**, e reordenar. Ao salvar,
  o servidor reescreve o `index.txt` e cria o `.txt` inicial de cada página nova.

Detalhes e limites:

- **Quem pode editar é configurável** em *Opções de Sandbox → Server Guides*, no
  campo **"Níveis de acesso que podem editar"**: uma lista separada por `;`
  (padrão `admin;moderator;overseer;gm`). Deixe vazio para não permitir ninguém. O
  **host** (SP/coop) sempre pode editar — é o dono dos arquivos.
- **Servidor é autoritativo**: o botão é só cosmético; toda gravação é revalidada no
  servidor (nível de acesso vs. opção de sandbox, caminho seguro, limite de 256 KB).
  Um cliente sem permissão não consegue gravar mesmo forjando comandos.
- **Remover** uma página/categoria só a tira do menu — o arquivo `.txt`
  **permanece** no disco (nada é apagado por engano; dá para re-adicionar depois).
- Editar o menu **reescreve** o `index.txt` com um cabeçalho gerado; **comentários e
  formatação manual não são preservados**.
- O nome do arquivo de uma página nova é derivado do título (e tornado único); o
  título continua independente do nome do arquivo.
- Edição **otimista**: se outro staff alterar a mesma página/menu enquanto você edita,
  o salvamento é recusado ("o conteúdo mudou no servidor") — reabra e refaça.

## Imagens

O texto é servido ao vivo, mas a **imagem não**: ela precisa estar empacotada na
pasta `media/` de um mod carregado (registrada no mapa de texturas e sincronizada
ao cliente) e é referenciada por **nome**, com o prefixo `media/`.

Este mod já traz uma imagem de demonstração em
[`ServerGuides/common/media/ui/guias/poster.png`](ServerGuides/common/media/ui/guias),
usada no guia `guide_images.txt` via `<IMAGECENTRE:media/ui/guias/poster.png,256,256>`.

Para usar **suas** imagens sem editar este mod, empacote-as num mod separado e
referencie por nome — veja o mod de exemplo
[`ServerGuidesImagesExample`](../ServerGuidesImagesExample). Em multiplayer o mod
com as imagens precisa estar no **Workshop** (mods locais não sincronizam ao cliente).

## Limites

- Tamanho máximo por arquivo: **256 KB** (recusado acima disso).
- Conteúdo grande é fatiado em chunks pela rede e remontado no cliente
  automaticamente.

## Idiomas

Inglês e Português (Brasil) — strings da UI e das opções de sandbox.

## Arquivos do mod

Layout multi-versão do B42: cada pasta-base (`42/` da versão e `common/`
compartilhada) tem seu `media/`. O jogo lista o mod por causa do `42/mod.info` e
carrega o `media/` de **ambas** (`common/` + `42/`), com a versão sobrepondo a
comum (`ZomboidFileSystem`).

```
ServerGuides/                      # pasta do mod (vai em ~/Zomboid/mods/)
  42/
    mod.info
    media/
      sandbox-options.txt          # opção "níveis que podem editar" (page Server Guides)
      lua/
       shared/
        ServerGuides_Shared.lua    # constantes, isStaff/sandbox, validação de caminho, hash, parser/serializer do index
        Translate/EN/*, Translate/PTBR/*   # strings da UI (IG_UI.json) e das opções de sandbox (Sandbox.json)
       server/
        ServerGuides_Server.lua    # OnClientCommand: index/página, rulesVersion, validação, chunking, edição (savePage/editIndex)
        ServerGuides_Seed.lua      # 1ª execução: cria Lua/ServerGuides/ e grava os modelos de texts/
       client/
        ServerGuides_UI.lua        # janela + modo de edição inline (ISCollapsableWindow + listbox + rich text)
        ServerGuides_IndexEditor.lua # editor do menu/index (CRUD de categorias e páginas)
        ServerGuides_Client.lua    # OnServerCommand, cache/remontagem, auto-open, senders de edição
        ServerGuides_ESCMenu.lua   # item no menu ESC in-game (estilo nativo)
  common/
    media/ui/guias/poster.png      # imagem de demonstração (carregada como media/ui/guias/poster.png)
    texts/                         # conteúdo-modelo p/ copiar em ~/Zomboid/Lua/ServerGuides/
README.md / SPEC.md                # docs (na raiz do repositório, fora do mod)
STEAM_DESC.bbcode                  # descrição da Oficina (BBCode), fora do mod
```
