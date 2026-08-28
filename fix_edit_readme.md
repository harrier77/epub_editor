# Fix: aggiunta / spezzatura di paragrafi nell'editor in-context

## Problema

Nell'editor in-context del lettore EPUB (popover "Modifica paragrafo" aperto
cliccando su un paragrafo nel viewer), il salvataggio conservava **solo la
stringa compresa tra i due tag `<p>…</p>` originali**:

- se l'utente aggiungeva un altro paragrafo in coda a quello editato, il
  paragrafo aggiunto veniva **ignorato e perso** al salvataggio;
- non era possibile **spezzare un paragrafo in due**.

### Causa

Il bug non era nel backend Nim (`epub_app.nim` salva la stringa `content`
ricevuta dal bridge così com'è), ma nel frontend `html_code/index.html`, nel
flusso dell'editor in-context:

1. `parseUserHtml()` restituiva **un solo nodo**:
   - nel parsing XML rigoroso: `xdoc.documentElement.firstElementChild`;
   - nel fallback HTML tollerante: `wrapper.firstElementChild`.

2. `buildEditedChapter()` eseguiva:

   ```js
   target.parentNode.replaceChild(node, target);
   ```

   sostituendo cioè un solo elemento con un solo nodo.

Digitate più tag nel textarea (es. `<p>a</p><p>b</p>`), solo il primo `<p>`
veniva salvato; i successivi venivano scartati in silenzio.

## Soluzione

### 1. `parseUserHtml()` → ritorna un array di nodi

La funzione ora restituisce un **array con TUTTI gli elementi di primo livello**
digitati dall'utente (elementi + testo non-bianco; gli spazi/`\n` tra i
paragrafi vengono ignorati), sia nel percorso XML rigoroso sia nel fallback
HTML tollerante.

```js
// Parsing XML rigoroso: tutti i figli di primo livello del wrapper
for (var i = 0; i < xdoc.documentElement.childNodes.length; i++) {
  var cn = xdoc.documentElement.childNodes[i];
  if (cn.nodeType === 3 && !cn.nodeValue.replace(/\s/g, "")) continue;
  nodes.push(doc.importNode(cn, true));
}
```

### 2. `buildEditedChapter()` → inserisce tutti i nodi con un fragment

L'intero array viene inserito nella posizione dell'elemento originale tramite
un `DocumentFragment`:

```js
var nodes = parseUserHtml(newHtml, cleanDoc);
if (!nodes || !nodes.length) throw new Error("HTML non valido: " + newHtml);
var frag = cleanDoc.createDocumentFragment();
for (var k = 0; k < nodes.length; k++) frag.appendChild(nodes[k]);
target.parentNode.replaceChild(frag, target);
```

### 3. Hint nell'interfaccia

Aggiunto un suggerimento visibile nel popover (div `.ieHint` + CSS) che spiega
la sintassi:

> Un elemento per riga: per spezzare il paragrafo o aggiungerne altri in coda
> scrivi più tag, es. `<p>prima parte</p><p>seconda parte</p>`

## Casi d'uso ora supportati

| Operazione | Prima | Dopo |
|---|---|---|
| **Spezzare** un paragrafo in due | solo il primo `<p>` salvato | `<p>prima parte</p><p>seconda parte</p>` → due paragrafi nel capitolo |
| **Accodare** un nuovo paragrafo dopo quello editato | paragrafo aggiunto perso | tutti i paragrafi vengono salvati in ordine |
| Edit normale di un singolo paragrafo | funzionava | invariato |

## File modificati

- `html_code/index.html` (frontend, servito da disco via virtual host):
  - `parseUserHtml()` — ritorna `array` di nodi invece del singolo nodo;
  - `buildEditedChapter()` — inserisce l'intero array con `DocumentFragment`;
  - popover: aggiunto il div `.ieHint` (CSS + HTML).

## Note

- **Backend Nim invariato**: `saveChapterIntoEpub` / `saveChapterIntoFolder`
  scrivono già il contenuto completo ricevuto dal bridge; la serializzazione
  finale (`outerHTML` su documento XML) escape correttamente `& < >`.
- **Nessuna ricompilazione** (`compila.bat` non necessaria): basta **riavviare
  `epub_app.exe`** per caricare la nuova `index.html`.
- Il riposizionamento post-salvataggio (`rendition.display(cfi)`) continua a
  funzionare: il primo elemento inserito eredita l'indice dell'originale,
  quindi il CFI risolve ancora correttamente.
