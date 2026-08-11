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
##   - La cartella epubs/ con i file .epub viene mappata su un secondo
##     virtual host ("https://books/"): epub.js apre il file via
##     https://books/<nome>.epub e lo unzipa da solo (JSZip), esattamente
##     come nella versione Flask.
##
## Epub NON impacchettato (allineato a app.py / --book-dir):
##   - La cartella esterna con l'output del translator (META-INF/ + OEBPS/)
##     viene mappata su un secondo virtual host "https://ext/": i file sono
##     letti dal disco a ogni richiesta, quindi le traduzioni salvate si
##     vedono subito, senza ricompilare l'epub.
##   - In Libreria appare come primo libro (type "folder"), come /ext/ di Flask.
##   - Il salvataggio (saveChapter) scrive direttamente nel file della
##     cartella (match case-insensitive, scrittura atomica .tmp + move).
##   - Il pulsante "⟳ Ricarica" del frontend rilegge il capitolo dal disco.

import
  miowv,
  winim,
  std/[json, os, strutils, xmlparser, xmltree, algorithm, tables],
  zippy/ziparchives

# ------------------------------------------------------------------
# Costante: nome del virtual host e cartella con il frontend
# ------------------------------------------------------------------
const
  VHOST* = "appassets"          # https://appassets/... (frontend html_code/)
  BOOKS_HOST* = "books"         # https://books/... (cartella con i file .epub)
  HOST_ACCESS_ALLOW = 1         # COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND::ALLOW
  # Epub NON impacchettato (output del translator): cartella mappata su
  # https://ext/ e mostrata come primo libro in Libreria (come --book-dir
  # di app.py). Modifica qui il percorso se il translator scrive altrove.
  FOLDER_HOST* = "ext"
  FOLDER_BOOK_DIR* = r"C:\Users\pr30565\Desktop\python\translator\target"
  # Chiave usata dal frontend per identificare il libro-cartella nei payload
  # di saveChapter (corrisponde a FOLDER_BOOK_KEY di app.py).
  FOLDER_BOOK_KEY* = "ext"

# ------------------------------------------------------------------
# Estrazione del titolo dall'OPF (stesso metodo di app.py con zipfile)
# ------------------------------------------------------------------
proc localTag(tag: string): string =
  ## Restituisce la parte locale di un tag XML, ignorando il prefisso
  ## di namespace (es. "dc:title" -> "title").
  split(tag, ':')[^1]

proc titleFromOpfDoc(opf: XmlNode): string =
  ## Legge <dc:title> dalla radice <package> di un OPF (metadata).
  result = ""
  for meta in opf:
    if meta.kind != xnElement or localTag(meta.tag) != "metadata": continue
    for el in meta:
      if el.kind == xnElement and localTag(el.tag) == "title":
        let t = el.innerText.strip()
        if t.len > 0:
          result = t
          return

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
        result = titleFromOpfDoc(parseXml(opf))
      except CatchableError:
        discard
  finally:
    try:
      reader.close()
    except CatchableError:
      discard

# ------------------------------------------------------------------
# Epub NON impacchettato (cartella esterna, output del translator)
# ------------------------------------------------------------------
proc folderTitle(root: string): string =
  ## Titolo da un epub NON impacchettato: legge META-INF/container.xml per
  ## trovare l'OPF, poi ne legge i metadati (folder_title in app.py).
  result = ""
  let containerPath = root / "META-INF" / "container.xml"
  if not fileExists(containerPath): return
  try:
    let cdoc = parseXml(readFile(containerPath))
    var opfPath = ""
    for r in cdoc:
      for rf in r:
        if rf.kind == xnElement and localTag(rf.tag) == "rootfile":
          let fp = rf.attr("full-path")
          if fp.len > 0: opfPath = fp
    if opfPath.len == 0: return
    let opfFull = root / opfPath.replace('\\', '/')
    if not fileExists(opfFull): return
    result = titleFromOpfDoc(parseXml(readFile(opfFull)))
  except CatchableError:
    discard

proc folderSize(root: string): int64 =
  ## Dimensione totale (byte) di tutti i file della cartella epub
  ## (folder_size in app.py).
  result = 0
  for p in walkDirRec(root):
    if fileExists(p):
      try:
        result += getFileSize(p)
      except CatchableError:
        discard

proc resolveInDir(root, href: string): string =
  ## Ritorna il path reale di `href` sotto `root`, con match case-insensitive
  ## (come cmpIgnoreCase usato per le voci dello zip). Ritorna "" se assente
  ## o se il path risolto esce da `root` (sicurezza: niente traversal).
  ## Corrisponde a resolve_in_dir in app.py.
  let clean = href.replace('\\', '/').strip(chars = {'/'})
  if clean.len == 0 or ".." in clean.split('/'): return ""
  let rootReal = expandFilename(root)
  # 1) tentativo diretto (path identico)
  let direct = root / clean
  if fileExists(direct):
    let real = expandFilename(direct)
    if real == rootReal or real.startsWith(rootReal & DirSep): return real
    return ""
  # 2) ricerca case-insensitive nell'albero
  let norm = clean.toLowerAscii()
  for p in walkDirRec(root):
    if not fileExists(p): continue
    let rel = relativePath(p, root).replace('\\', '/')
    if rel.toLowerAscii() == norm:
      let real = expandFilename(p)
      if real == rootReal or real.startsWith(rootReal & DirSep): return real
  return ""

proc saveChapterIntoFolder(root, href, content: string): string =
  ## Salva `content` nel file `href` della cartella esterna (epub NON
  ## impacchettato), con scrittura atomica (.tmp + move). È l'equivalente
  ## della modalita' "cartella" di /api/save_chapter in app.py.
  ## Ritorna "" in caso di successo, altrimenti un messaggio d'errore.
  if root.len == 0 or not dirExists(root):
    return "Cartella esterna non configurata"
  # Validazione href: niente path traversal (..), niente path assoluti
  # (/, \\, drive letter) — come save_chapter in app.py.
  let normalized = href.replace('\\', '/').strip(chars = {'/'})
  if normalized.len == 0 or ".." in normalized.split('/') or
     href.startsWith("\\") or (href.len > 1 and href[1] == ':'):
    return "Percorso non valido: " & href
  let target = resolveInDir(root, href)
  if target.len == 0:
    return "Il file " & href & " non e' presente nella cartella"
  let tmp = target & ".tmp"
  try:
    writeFile(tmp, content)
    moveFile(tmp, target)
  except CatchableError as e:
    try:
      if fileExists(tmp): removeFile(tmp)
    except CatchableError:
      discard
    return "Errore durante la scrittura: " & e.msg
  return ""

# ------------------------------------------------------------------
# Elenco dei libri nella cartella epubs/ (e dell'epub da cartella)
# ------------------------------------------------------------------
proc listEpubBooks*(dir, folderDir: string): seq[JsonNode] =
  result = @[]
  # 1) Epub NON impacchettato (output del translator) come primo libro:
  #    url https://ext/ termina con '/' → epub.js lo apre in modalita'
  #    DIRECTORY (legge META-INF/container.xml), come /ext/ in Flask.
  if folderDir.len > 0 and dirExists(folderDir):
    let label = splitPath(folderDir).tail
    let t = folderTitle(folderDir)
    result.add(%*{
      "name":  label & "/",
      "title": (if t.len > 0: t else: label & "/"),
      "url":   "https://" & FOLDER_HOST & "/",
      "size":  folderSize(folderDir),
      "type":  "folder"
    })

  # 2) File .epub nella cartella libri (https://books/)
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
      "url":   "https://" & BOOKS_HOST & "/" & name.path,
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
  gFrontendDir: string # cartella html_code/ servita su https://appassets/ (frontend)
  gBooksDir: string    # cartella con i file .epub (mappata su https://books/)
  gFolderDir: string   # cartella esterna con l'epub non impacchettato (https://ext/)

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
      let data = %(listEpubBooks(gBooksDir, gFolderDir))
      let js = "window._nimCallbacks[" & cbId & "](" & $data & ")"
      w.eval(js)
    of "saveChapter":
      let bookPath = args["book"].getStr()
      let href     = args["href"].getStr()
      let content  = args["content"].getStr()
      # "silent" (opzionale, usato dal popover in-context) è accettato per
      # compatibilità col frontend condiviso ma non ha effetti lato backend:
      # come in app.py, il ri-render del viewer è sempre client-side
      # (updateChapterDom nel frontend), quindi niente MessageBox.
      discard args.hasKey("silent") and args["silent"].getBool()
      let err =
        if bookPath.strip(chars = {'/'}) == FOLDER_BOOK_KEY or
           bookPath == "https://" & FOLDER_HOST & "/":
          # Modalita' cartella (epub non impacchettato): scrittura su disco
          saveChapterIntoFolder(gFolderDir, href, content)
        else:
          saveChapterIntoEpub(bookPath, href, content)
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
  gFrontendDir = exeDir / "html_code"
  gBooksDir = exeDir / "epubs"

  # Epub NON impacchettato (output del translator): se la cartella esiste la
  # mappiamo su https://ext/ (in app.py: --book-dir).
  gFolderDir = FOLDER_BOOK_DIR
  if dirExists(gFolderDir):
    echo "[epub] Epub da cartella: ", gFolderDir, "  (su https://", FOLDER_HOST, "/)"
  else:
    echo "[epub] AVVISO: cartella esterna non trovata, ignorata: ", gFolderDir
    gFolderDir = ""

  echo "[epub] Cartella libri: ", gBooksDir
  let books = listEpubBooks(gBooksDir, gFolderDir)
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

  # Mappa https://appassets/ -> cartella html_code (serve il frontend senza server)
  let hr = w.mio_registerVirtualHost(VHOST, gFrontendDir, allow = true)
  if hr != S_OK:
    echo "[epub] AVVISO: registro virtual host fallito (", $hr, ")"

  # Mappa https://books/ -> cartella epubs/ con i file .epub: epub.js li apre
  # via https://books/<nome>.epub e li unzipa da solo con JSZip.
  if dirExists(gBooksDir):
    let hr3 = w.mio_registerVirtualHost(BOOKS_HOST, gBooksDir, allow = true)
    if hr3 != S_OK:
      echo "[epub] AVVISO: registro virtual host ", BOOKS_HOST, " fallito (", $hr3, ")"
  else:
    echo "[epub] AVVISO: cartella libri non trovata: ", gBooksDir

  # Mappa https://ext/ -> cartella dell'epub non impacchettato: i file vengono
  # riletti dal disco a ogni richiesta (le traduzioni salvate si vedono subito,
  # senza ricompilare l'epub).
  if gFolderDir.len > 0:
    let hr2 = w.mio_registerVirtualHost(FOLDER_HOST, gFolderDir, allow = true)
    if hr2 != S_OK:
      echo "[epub] AVVISO: registro virtual host ", FOLDER_HOST, " fallito (", $hr2, ")"

  # Carica il frontend dalla cartella html_code via virtual host
  w.navigate("https://" & VHOST & "/index.html")

  echo "[epub] Avviato. Premi chiudi la finestra per uscire."
  w.run()
