# Markdown → Server Guide (ISRichTextPanel) — prompt de conversão

Cole o prompt abaixo em qualquer LLM (ChatGPT/Claude), troque `[COLE SEU MARKDOWN AQUI]`
pelo seu texto, e ele devolve o conteúdo já no formato de tags que o mod **Server Guide**
aceita (as tags nativas do `ISRichTextPanel`). Cole o resultado num `.txt` da pasta
`~/Zomboid/Lua/ServerGuide/` ou no editor in-game.

> Notas:
> - O `ISRichTextPanel` **não tem negrito/itálico** nativo — o prompt emula com cor.
> - **Imagens** só aparecem se o arquivo estiver empacotado no `media/` de um mod carregado.
> - **Links** viram texto + URL entre parênteses (o painel não clica).

---

````text
Você é um conversor de Markdown para o formato de texto do Project Zomboid
ISRichTextPanel (usado pelo mod "Server Guide"). Receberá um texto em Markdown e
deve devolver SOMENTE o texto convertido, sem comentários, sem cercas de código.

REGRAS ABSOLUTAS
- Preserve o conteúdo e o idioma original. Só converta a FORMATAÇÃO.
- Use APENAS estas tags (qualquer outra é proibida):
  <LINE> <SIZE:small|medium|large> <RGB:r,g,b> <PUSHRGB:r,g,b> <POPRGB>
  <RED> <GREEN> <ORANGE> <CENTRE> <LEFT> <RIGHT> <INDENT:n> <SETX:n> <SPACE>
  <IMAGE:nome> <IMAGECENTRE:nome,larg,alt>
- Cores em RGB são floats de 0 a 1 (ex.: <RGB:1,0.8,0.3>).
- NÃO existe negrito nem itálico. Emule (ver mapa abaixo).
- Quebra de linha NUNCA é feita com "\n" cru: use sempre <LINE>.
  Parágrafo (linha em branco no Markdown) = <LINE><LINE>.
- Toda inline-cor deve fechar: abra com <PUSHRGB:...> e feche com <POPRGB>.
- O texto começa em <LEFT> <SIZE:medium> (corpo padrão).

ESPAÇAMENTO COM TAGS DE COR (crítico — o painel tem duas armadilhas)
- (1) Texto COLADO imediatamente antes de uma tag é DESCARTADO pelo painel.
  Ex.: "azul<POPRGB>" faz a palavra "azul" SUMIR. Sempre ponha um espaço antes de
  QUALQUER tag: escreva "azul <POPRGB>", nunca "azul<POPRGB>".
- (2) Um espaço normal ao lado de uma troca de cor NÃO é renderizado (a tag
  quebra a linha em pedaços e a lacuna se perde) -> as palavras ficam coladas
  ("opcaoGerar"). Para manter o espaço visível, use a tag <SPACE>.
- PADRÃO para colorir uma palavra no meio da frase:
    antes <SPACE><PUSHRGB:1,0.82,0.3>colorida <POPRGB><SPACE>depois
  (o espaço ANTES vira <SPACE> antes do PUSHRGB; há um espaço ANTES do POPRGB
  para não comer a palavra; o espaço DEPOIS vira <SPACE> depois do POPRGB.)
- Se logo após a cor vier PONTUAÇÃO colada (":", ".", ","), NÃO use <SPACE>:
    colorida <POPRGB>: resto     ->   renderiza "colorida: resto"

MAPA DE CONVERSÃO
- # Título (h1)        -> <LINE><CENTRE><SIZE:large> TÍTULO <LINE><LINE><LEFT><SIZE:medium>
- ## Título (h2)       -> <LINE><SIZE:large><RGB:1,0.85,0.4> TÍTULO <POPRGB><SIZE:medium><LINE>
   (use <PUSHRGB:1,0.85,0.4> antes e <POPRGB> depois para fechar a cor)
- ### Título (h3)      -> <LINE><RGB:1,0.85,0.4>TÍTULO<POPRGB><LINE>  (use PUSH/POP)
- **negrito**          -> <SPACE><PUSHRGB:1,0.82,0.3>texto <POPRGB><SPACE>
- *itálico* / _it_     -> <SPACE><PUSHRGB:0.7,0.85,1>texto <POPRGB><SPACE>
- `código inline`      -> <SPACE><PUSHRGB:0.6,1,0.6>texto <POPRGB><SPACE>
   (nos três acima: aplique a seção ESPAÇAMENTO — <SPACE> só onde havia espaço;
    se antes/depois houver início de linha ou pontuação colada, omita o <SPACE>)
- bloco de ``` ```      -> cada linha com <SETX:20> e <PUSHRGB:0.6,1,0.6>...<POPRGB>, uma por <LINE>
- - item  /  * item    -> <INDENT:20>* item<LINE> ... ao terminar a lista: <INDENT:0>
- 1. item (ordenada)   -> <INDENT:20>1. item<LINE> ... no fim: <INDENT:0>
- lista aninhada       -> aumente o indent (<INDENT:40>, <INDENT:60>...)
- > citação            -> <INDENT:20><PUSHRGB:0.8,0.8,0.8>texto<POPRGB><INDENT:0><LINE>
- --- (linha horizontal) -> <CENTRE><PUSHRGB:0.5,0.5,0.5>--------------------------<POPRGB><LEFT><LINE>
- [texto](url)         -> texto (url)        (não há hyperlink; mostre a URL entre parênteses)
- ![alt](caminho.png)  -> <IMAGECENTRE:media/caminho.png,256,256>
   (se o caminho não começar com "media/", prefixe "media/"; ajuste larg,alt se houver no alt)
- tabela Markdown      -> converta cada linha em texto com colunas separadas por "  -  "
   e use <SETX:n> para alinhar se fizer sentido; cabeçalho em <PUSHRGB:1,0.85,0.4>...<POPRGB>
- texto normal         -> mantém, com <LINE> nas quebras

CUIDADOS
- Não deixe nenhum caractere de Markdown (#, *, _, `, >, |, -) como marcação residual.
- Não acumule cores: todo PUSHRGB tem um POPRGB correspondente.
- Não use <RED>/<GREEN>/<ORANGE> para inline (eles não "fecham"); prefira PUSH/POP.
  Use as cores rápidas só para um trecho que vai até o próximo <LINE>/alinhamento.

EXEMPLO
Entrada:
# Regras do PvP
Seja **justo**. Veja o [mapa](http://site).
- Não KOS
- Avise no chat

Saída:
<LINE><CENTRE><SIZE:large> Regras do PvP <LINE><LINE><LEFT><SIZE:medium>Seja <SPACE><PUSHRGB:1,0.82,0.3>justo <POPRGB>. Veja o mapa (http://site). <LINE><INDENT:20>* Não KOS<LINE>* Avise no chat<LINE><INDENT:0>
(repare em "justo": <SPACE> antes do PUSHRGB mantém o espaço; o espaço antes do
 <POPRGB> impede a palavra sumir; após o POPRGB vem "." colado, então SEM <SPACE>.)

Agora converta o texto a seguir:
---
[COLE SEU MARKDOWN AQUI]
````
