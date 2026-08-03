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
  std/[json, os, strutils, xmlparser, xmltree, algorithm],
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
# Bridge JS <-> Nim
# ------------------------------------------------------------------
var
  gBooksDir: string   # cartella con i file .epub

proc handleBridge(w: Webview; arg: cstring) =
  ## Callback invocato dal JavaScript via window.chrome.webview.postMessage.
  try:
    let msg = parseJson($arg)
    let scope = msg["scope"].getStr()
    let name  = msg["name"].getStr()
    let cbId  = if msg.hasKey("callbackId"): $msg["callbackId"].getInt() else: ""

    if scope != "epub" or cbId.len == 0: return

    case name
    of "listBooks":
      let data = %(listEpubBooks(gBooksDir))
      let js = "window._nimCallbacks[" & cbId & "](" & $data & ")"
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
