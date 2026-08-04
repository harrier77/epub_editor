## epub_app.nim  –  Lettore EPUB standalone (WebView2)
##
## Applicazione desktop senza server che mostra i file .epub contenuti nella
## cartella html_code/ (stessa libreria epub.js del progetto Flask).
##
## Come funziona:
##   - La cartella html_code/ viene servita dalla WebView2 tramite un virtual
##     host ("https://appassets/") invece che da un server HTTP.
##   - Il bridge Nim <-> JavaScript fornisce l'elenco dei libri (listBooks),
##     leggendo il titolo da ciascun .epub con zippy (unzip in puro Nim).
##   - epub.js apre il file .epub via https://appassets/<nome>.epub e lo
##     unzipa da solo (JSZip), esattamente come nella versione Flask.

import
  miowv,
  winim,
  std/[json, os, strutils, xmlparser, xmltree, algorithm, tables],
  zippy/ziparchives

# ------------------------------------------------------------------
# Costante: nome del virtual host e cartella con il frontend
# ------------------------------------------------------------------
const
  VHOST* = "appassets"          # https://appassets/...
  HOST_ACCESS_ALLOW = 1         # COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND::ALLOW

# ------------------------------------------------------------------
# Estrazione del titolo dall'OPF (stesso metodo di app.py con zipfile)
# ------------------------------------------------------------------
proc localTag(tag: string): string =
  ## Restituisce la parte locale di un tag XML, ignorando il prefisso
  ## di namespace (es. "dc:title" -> "title").
  split(tag, ':')[^1]

proc epubTitle(path: string): string =
  ## Legge il titolo da un .epub usando zippy (unzip) e xmlparser.
  result = ""
  if not fileExists(path): return
  var reader: ZipArchiveReader
  try:
    reader = openZipArchive(path)
  except CatchableError as e:
    echo "[epub] Impossibile aprire ", path, ": ", e.msg
    return

  try:
    # 1) Legge META-INF/container.xml per trovare il percorso dell'OPF
    var opfPath = ""
    try:
      let container = extractFile(reader, "META-INF/container.xml")
      let cdoc = parseXml(container)
      for root in cdoc:
        for rf in root:
          if rf.kind == xnElement and localTag(rf.tag) == "rootfile":
            let fp = rf.attr("full-path")
            if fp.len > 0: opfPath = fp
    except CatchableError:
      discard  # container.xml mancante o malformato -> niente titolo

    # 2) Legge il package.opf e cerca <dc:title>
    if opfPath.len > 0:
      try:
        let opf = extractFile(reader, opfPath)
        let odoc = parseXml(opf)   # radice = <package>
        for meta in odoc:
          if meta.kind != xnElement or localTag(meta.tag) != "metadata": continue
          for el in meta:
            if el.kind == xnElement and localTag(el.tag) == "title":
              let t = el.innerText.strip()
              if t.len > 0:
                result = t
                break
      except CatchableError:
        discard
  finally:
    try:
      reader.close()
    except CatchableError:
      discard

# ------------------------------------------------------------------
# Elenco dei libri nella cartella html_code/
# ------------------------------------------------------------------
proc listEpubBooks*(dir: string): seq[JsonNode] =
  result = @[]
  if not dirExists(dir):
    echo "[epub] Cartella non trovata: ", dir
    return
  for name in walkDir(dir, relative = true):
    let lower = name.path.toLowerAscii()
    if not (name.kind == pcFile and lower.endsWith(".epub")): continue
    let full = dir / name.path
    let title = epubTitle(full)
    let display = if title.len > 0: title else: splitFile(name.path).name
    result.add(%*{
      "name":  name.path,
      "title": display,
      "url":   "/" & name.path,
      "size":  getFileSize(full)
    })
  # ordinamento per nome file (come in app.py)
  result.sort(proc(a, b: JsonNode): int =
    cmpIgnoreCase(a{"name"}.getStr, b{"name"}.getStr)
  )

# ------------------------------------------------------------------
# Salvataggio di un file modificato dentro l'epub
# ------------------------------------------------------------------
var
  gBooksDir: string   # cartella con i file .epub

proc saveChapterIntoEpub(bookPath, href, content: string): string =
  ## Riscrive il file .epub su disco sostituendo il contenuto della voce
  ## `href` con `content`. Restituisce "" in caso di successo, altrimenti
  ## un messaggio d'errore.
  let full = gBooksDir / bookPath
  if not fileExists(full):
    return "File non trovato: " & bookPath

  var entries = initOrderedTable[string, string]()
  var reader: ZipArchiveReader
  try:
    reader = openZipArchive(full)
  except CatchableError as e:
    return "Impossibile aprire l'epub: " & e.msg

  try:
    var found = false
    for name in reader.walkFiles():
      if cmpIgnoreCase(name, href) == 0:
        entries[name] = content
        found = true
      else:
        entries[name] = reader.extractFile(name)
    if not found:
      return "Il file " & href & " non e' presente nell'epub"
  except CatchableError as e:
    return "Errore durante la lettura dell'epub: " & e.msg
  finally:
    try:
      reader.close()
    except CatchableError:
      discard

  try:
    let newZip = createZipArchive(entries)   # ricompone l'epub in memoria
    let tmp = full & ".tmp"
    writeFile(tmp, newZip)
    moveFile(tmp, full)                       # sostituzione atomica su disco
  except CatchableError as e:
    return "Errore durante la scrittura: " & e.msg
  return ""

# ------------------------------------------------------------------
# Aggiornamento del DOM senza ricaricare l'epub
# ------------------------------------------------------------------
# Dopo un salvataggio riuscito NON serve ricaricare il file .epub: questo
# snippet JS ri-renderizza il capitolo corrente nel viewer usando il contenuto
# appena salvato (ancora nel textarea dell'editor), patchando l'archive di
# epub.js in memoria e invalidando le cache di sezione/view.
const updateChapterDomJs = """
(function () {
  if (!window.book || !window.book.archive || !window.rendition) return;
  var section = window.book.spine ? window.book.spine.get(window.currentHref) : null;
  if (!section) return;
  var archPath = (section.url || window.currentHref).replace(/^\//, '');
  var newText = document.getElementById('codeEditor').value;
  var archive = window.book.archive;
  var origRequest = archive.request.bind(archive);
  // 1) Patch dell'archive in memoria: la richiesta del capitolo salvato
  //    restituisce il nuovo contenuto invece di rileggerlo dall'epub.
  archive.request = function (url, type) {
    var p = window.decodeURIComponent(String(url).substr(1));
    if (p === archPath) {
      if (!type) {
        var m = /\.([a-z0-9]+)$/i.exec(String(url));
        type = m ? m[1].toLowerCase() : '';
      }
      try {
        return Promise.resolve(archive.handleResponse(newText, type));
      } catch (e) {
        return Promise.resolve(newText);
      }
    }
    return origRequest(url, type);
  };
  // 2) Invalida le cache della sezione e dei view, cosi' il re-render
  //    rilegge il contenuto aggiornato.
  section.contents = undefined;
  section.document = undefined;
  section.output = undefined;
  var views = window.rendition.manager.views.all();
  for (var i = 0; i < views.length; i++) {
    if (views[i].section && views[i].section.index === section.index) {
      views[i].displayed = false;
    }
  }
  // 3) Ri-renderizza il capitolo corrente nel viewer. Se il viewer e'
  //    nascosto (tab Modifica HTML) il ri-render produrrebbe un iframe 0x0
  //    e la pagina di lettura resterebbe bianca: in quel caso il ri-render
  //    viene rimandato al ritorno sulla tab Lettura (showTab legge il flag
  //    window._epubNeedsRefresh).
  var viewerEl = document.getElementById('viewer');
  if (viewerEl && viewerEl.style.display === 'none') {
    window._epubNeedsRefresh = true;
  } else {
    window.rendition.display(window.currentHref);
  }
})();
"""

# ------------------------------------------------------------------
# Bridge JS <-> Nim
# ------------------------------------------------------------------
proc handleBridge(w: Webview; arg: cstring) =
  ## Callback invocato dal JavaScript via window.chrome.webview.postMessage.
  try:
    let msg = parseJson($arg)
    let scope = msg["scope"].getStr()
    let name  = msg["name"].getStr()
    let cbId  = if msg.hasKey("callbackId"): $msg["callbackId"].getInt() else: ""

    if scope != "epub" or cbId.len == 0: return

    # Parsing degli argomenti opzionali (inviati come stringa JSON in "args")
    var args = newJNull()
    if msg.hasKey("args") and msg["args"].getStr().len > 0:
      args = parseJson(msg["args"].getStr())

    case name
    of "listBooks":
      let data = %(listEpubBooks(gBooksDir))
      let js = "window._nimCallbacks[" & cbId & "](" & $data & ")"
      w.eval(js)
    of "saveChapter":
      let bookPath = args["book"].getStr()
      let href     = args["href"].getStr()
      let content  = args["content"].getStr()
      # "silent" = salvataggio in-context dal popover del viewer: il frontend
      # ha gia' aggiornato il DOM (ri-render con CFI) e ri-patcha l'archive in
      # memoria da solo, quindi niente MessageBox e niente updateChapterDomJs.
      let silent   = args.hasKey("silent") and args["silent"].getBool()
      let err = saveChapterIntoEpub(bookPath, href, content)
      if err.len == 0 and not silent:
        # Salvataggio riuscito: niente ricarica dell'epub, aggiorna il DOM
        # (ri-render del capitolo corrente) e verifica esito con MessageBox.
        w.eval(updateChapterDomJs)
        discard MessageBox(0, "Saving succeeded", "Epub Editor", MB_OK)
      let res = %*{"ok": err.len == 0, "error": err}
      let js = "window._nimCallbacks[" & cbId & "](" & $res & ")"
      w.eval(js)
    of "setZoom":
      # Zoom browser (WebView2) applicato dal backend: la pagina intera viene
      # zoomata; il frontend contro-ruota toolbar/sidebar e rifluisce con
      # rendition.resize() (misura in CSS px coerenti con lo zoom).
      let factor = if args.hasKey("factor"): args["factor"].getFloat() else: 1.0
      let z = max(0.75, min(2.0, factor))
      let hr = mio_setZoomFactor(w, z)
      let res = %*{"ok": hr == S_OK, "factor": z}
      let js = "window._nimCallbacks[" & cbId & "](" & $res & ")"
      w.eval(js)
    else:
      echo "[epub] Comando sconosciuto: ", scope, "/", name
  except CatchableError as e:
    echo "[epub] Errore nel bridge: ", e.msg

# ------------------------------------------------------------------
# Creazione finestra WebView2 (nessuna toolbar nativa: l'HTML ne ha una sua)
# ------------------------------------------------------------------
proc mio_new_webview_blank(title = ""; width = 1200; height = 800): Webview =
  result = create(WebviewObj)
  result.title = title
  result.initHtml = ""      # niente HTML embedded: carichiamo via virtual host
  result.url = ""           # la navigazione avviene dopo il mapping
  result.width = width
  result.height = height
  result.resizable = true
  result.debug = true
  result.invokeCb = generalExternalInvokeCallback
  result.miotop = 0         # 0 = nessuna toolbar nativa (full client area)
  if result.miowebview_init() != 0:
    echo "[epub] ERRORE: miowebview_init() fallito"
    return nil

# ------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------
when isMainModule:
  let exeDir = getAppDir()
  gBooksDir = exeDir / "html_code"

  echo "[epub] Cartella libri: ", gBooksDir
  let books = listEpubBooks(gBooksDir)
  echo "[epub] Trovati ", books.len, " libri"

  # Crea la finestra
  var w = mio_new_webview_blank(
    title = "Lettore EPUB",
    width = 1000,
    height = 900
  )
  if w.isNil:
    quit("Impossibile creare la finestra WebView2", 1)

  # Registra il bridge callback
  w.externalInvokeCB = handleBridge

  # Mappa https://appassets/ -> cartella html_code (serve i file senza server)
  let hr = w.mio_registerVirtualHost(VHOST, gBooksDir, allow = true)
  if hr != S_OK:
    echo "[epub] AVVISO: registro virtual host fallito (", $hr, ")"

  # Carica il frontend dalla cartella html_code via virtual host
  w.navigate("https://" & VHOST & "/index.html")

  echo "[epub] Avviato. Premi chiudi la finestra per uscire."
  w.run()
