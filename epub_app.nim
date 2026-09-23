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
  std/[json, os, osproc, strutils, times, xmlparser, xmltree, algorithm, tables, sequtils],
  zippy/ziparchives,
  sync

# ------------------------------------------------------------------
# Costante: nome del virtual host e cartella con il frontend
# ------------------------------------------------------------------
const
  VHOST* = "appassets"          # https://appassets/... (frontend html_code/)
  BOOKS_HOST* = "books"         # https://books/... (cartella con i file .epub)
  HOST_ACCESS_ALLOW = 1         # COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND::ALLOW
  # Epub NON impacchettato (output del translator): cartella mappata su
  # https://ext/ e mostrata come primo libro in Libreria (come --book-dir
  # di app.py). Default se ~/.epubreader/config.ini manca o e' illeggibile.
  FOLDER_HOST* = "ext"
  FOLDER_BOOK_DIR* = r"C:\Users\pr30565\Desktop\python\translator\target"
  # Chiave usata dal frontend per identificare il libro-cartella nei payload
  # di saveChapter (corrisponde a FOLDER_BOOK_KEY di app.py).
  FOLDER_BOOK_KEY* = "ext"

# ------------------------------------------------------------------
# Configurazione utente ~/.epubreader/config.ini (come _load_config in app.py)
# ------------------------------------------------------------------
proc configFilePath(): string =
  result = getHomeDir() / ".epubreader" / "config.ini"

proc expandUser(p: string): string =
  ## Come os.path.expanduser: usa std/os.expandTilde ("~" e "~/..." -> home).
  result = expandTilde(p)

proc loadUserConfig(): tuple[bookDir: string, epubFiles: seq[string]] =
  ## Legge [paths] book_dir + epub_files (lista separata da virgole).
  ## Crea il file con i default se assente. Fallback ai default se illeggibile.
  result = (bookDir: FOLDER_BOOK_DIR, epubFiles: @[])
  let cfg = configFilePath()
  try:
    createDir(parentDir(cfg))
  except CatchableError:
    discard
  if not fileExists(cfg):
    try:
      writeFile(cfg, "[paths]\nbook_dir = " & FOLDER_BOOK_DIR & "\nepub_files = \n")
    except CatchableError:
      discard
    return
  try:
    var inPaths = false
    var epubFilesDir = ""
    for rawLine in readFile(cfg).splitLines():
      let line = rawLine.strip()
      if line.startsWith("["):
        inPaths = line.toLowerAscii() == "[paths]"
      elif inPaths and "=" in line:
        let parts = line.split("=", maxsplit = 1)
        let k = parts[0].strip().toLowerAscii()
        let v = parts[1].strip()
        if k == "book_dir":
          result.bookDir = expandUser(v)
        elif k == "epub_files_dir":
          epubFilesDir = expandUser(v)
        elif k == "epub_files":
          result.epubFiles = v.split(",").mapIt(expandUser(it.strip())).filterIt(it.len > 0)
          if epubFilesDir.len > 0:
            result.epubFiles = result.epubFiles.mapIt(joinPath(epubFilesDir, it))
  except CatchableError:
    result = (bookDir: FOLDER_BOOK_DIR, epubFiles: @[])

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
# Stato globale + elenco dei libri (cartella epubs/ + epub da cartella)
# ------------------------------------------------------------------
var
  gFrontendDir: string # cartella html_code/ servita su https://appassets/ (frontend)
  gBooksDir: string    # cartella con i file .epub (mappata su https://books/)
  gFolderDir: string   # cartella esterna con l'epub non impacchettato (https://ext/)
  gExtEpubs: seq[string] = @[] # epub esterni da config.ini (epub_files), come EPUB_FILES in app.py

proc stagedExtName(idx: int): string =
  ## Nome dello staging in epubs/ per l'epub esterno N (visto dal frontend
  ## come bookKey "__extN__.epub", servito su https://books/).
  result = "__ext" & $idx & "__.epub"

proc extIndexFromKey(book: string): int =
  ## "extepub:N" o "__extN__.epub" -> N, altrimenti -1.
  result = -1
  if book.startsWith("extepub:"):
    try:
      result = parseInt(book["extepub:".len .. ^1])
    except ValueError:
      discard
  elif book.startsWith("__ext") and book.endsWith("__.epub"):
    try:
      result = parseInt(book["__ext".len .. ^(7)])
    except ValueError:
      discard

proc validBookKey(book: string): bool =
  ## True se `book` è una chiave libro valida (stessa regola di
  ## _valid_book_key in app.py): "ext", "extepub:N"/staging "__extN__.epub"
  ## o basename .epub.
  if book.len == 0: return false
  if book.strip(chars = {'/'}) == FOLDER_BOOK_KEY: return true
  if extIndexFromKey(book) >= 0: return true
  # basename .epub (niente path, niente traversal)
  if book == extractFilename(book) and "/" notin book and
     "\\" notin book and ".." notin book and
     book.toLowerAscii().endsWith(".epub"):
    return true
  return false

proc stageExtEpubs() =
  ## Copia ogni epub esterno in epubs/__extN__.epub cosi' il virtual host
  ## https://books/ puo' servirlo (WebView2 mappa cartelle, non singoli file).
  for idx, epubPath in gExtEpubs:
    if not fileExists(epubPath): continue
    let dest = gBooksDir / stagedExtName(idx)
    try:
      if not fileExists(dest) or getFileSize(dest) != getFileSize(epubPath):
        copyFile(epubPath, dest)
    except CatchableError as e:
      echo "[epub] AVVISO: staging epub esterno fallito: ", epubPath, ": ", e.msg

proc writeThroughExt(idx: int) =
  ## Dopo un salvataggio nello staging, ricopia __extN__.epub sull'originale.
  if idx < 0 or idx >= gExtEpubs.len: return
  try:
    copyFile(gBooksDir / stagedExtName(idx), gExtEpubs[idx])
  except CatchableError as e:
    echo "[epub] AVVISO: write-through epub esterno fallito: ", e.msg

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

  # 2) Epub esterni da config.ini (epub_files), come /api/books in app.py.
  #    Serviti dallo staging __extN__.epub in epubs/ (vedi stageExtEpubs).
  for idx, epubPath in gExtEpubs:
    if not fileExists(epubPath): continue
    let label = extractFilename(epubPath)
    let t = epubTitle(epubPath)
    result.add(%*{
      "name":  "extepub:" & $idx,
      "title": (if t.len > 0: t else: splitFile(label).name),
      "url":   "https://" & BOOKS_HOST & "/" & stagedExtName(idx),
      "size":  getFileSize(epubPath),
      "type":  "extepub"
    })

  # 3) File .epub nella cartella libri (https://books/), escluso lo staging
  if not dirExists(dir):
    echo "[epub] Cartella non trovata: ", dir
    return
  for name in walkDir(dir, relative = true):
    let lower = name.path.toLowerAscii()
    if not (name.kind == pcFile and lower.endsWith(".epub")): continue
    if name.path.startsWith("__ext") and name.path.endsWith("__.epub"): continue
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
  # write-through per gli epub esterni (staging -> originale)
  let xi = extIndexFromKey(bookPath)
  if xi >= 0: writeThroughExt(xi)
  return ""

# ------------------------------------------------------------------
# Note evidenziazioni (*.note.jsonl, come /api/*note* in app.py)
# ------------------------------------------------------------------
proc noteFileForBook(book: string): string =
  ## Path del file *.note.jsonl a fianco dell'epub/cartella ("" se non valido).
  if not validBookKey(book): return ""
  let clean = book.strip(chars = {'/'})
  if clean == FOLDER_BOOK_KEY:
    if gFolderDir.len == 0: return ""
    return gFolderDir.strip(chars = {DirSep}) & ".note.jsonl"
  let xi = extIndexFromKey(book)
  if xi >= 0:
    if xi >= gExtEpubs.len: return ""
    return gExtEpubs[xi] & ".note.jsonl"
  return gBooksDir / book & ".note.jsonl"

proc readNoteLines(path: string): seq[string] =
  result = @[]
  try:
    for line in readFile(path).splitLines():
      let s = line.strip()
      if s.len == 0: continue
      try:
        discard parseJson(s)
        result.add(s)
      except CatchableError:
        discard
  except CatchableError:
    discard

proc atomicWriteLines(path: string, lines: seq[string]): string =
  ## Scrittura atomica (.tmp + move). Ritorna "" se ok, altrimenti l'errore.
  let tmp = path & ".tmp"
  try:
    createDir(parentDir(absolutePath(path)))
    writeFile(tmp, lines.mapIt(it & "\n").join(""))
    moveFile(tmp, path)
  except CatchableError as e:
    try:
      if fileExists(tmp): removeFile(tmp)
    except CatchableError:
      discard
    return "Errore durante la scrittura: " & e.msg
  return ""

# ------------------------------------------------------------------
# CSS del pacchetto (come /api/css_files + /api/css_content in app.py)
# ------------------------------------------------------------------
proc cssZipEntries(epubPath: string): seq[tuple[name: string, size: int]] =
  ## Voci .css di un .epub (bundle.css escluso). Ritorna @[] se illeggibile.
  result = @[]
  if not fileExists(epubPath): return
  var reader: ZipArchiveReader
  try:
    reader = openZipArchive(epubPath)
  except CatchableError:
    return
  try:
    for name in reader.walkFiles():
      if name.toLowerAscii().endsWith(".css") and
         extractFilename(name).toLowerAscii() != "bundle.css":
        var sz = 0
        try:
          sz = reader.extractFile(name).len
        except CatchableError:
          discard
        result.add((name: name, size: sz))
  except CatchableError:
    discard
  finally:
    try:
      reader.close()
    except CatchableError:
      discard

proc cssFilesForBook(book: string): JsonNode =
  ## {"ok":..,"files":[{href,size}]} oppure {"ok":false,"error":..}.
  if not validBookKey(book):
    return %*{"ok": false, "error": "Nome libro non valido"}
  let clean = book.strip(chars = {'/'})
  if clean == FOLDER_BOOK_KEY:
    if gFolderDir.len == 0 or not dirExists(gFolderDir):
      return %*{"ok": false, "error": "Cartella esterna non configurata"}
    var files: seq[JsonNode] = @[]
    for p in walkDirRec(gFolderDir):
      if not fileExists(p): continue
      if not p.toLowerAscii().endsWith(".css"): continue
      let rel = relativePath(p, gFolderDir).replace('\\', '/')
      if extractFilename(rel).toLowerAscii() == "bundle.css": continue
      var sz = 0
      try:
        sz = getFileSize(p).int
      except CatchableError:
        discard
      files.add(%*{"href": rel, "size": sz})
    files.sort(proc(a, b: JsonNode): int = cmp(a["href"].getStr, b["href"].getStr))
    return %*{"ok": true, "files": files}
  var epubPath: string
  let xi = extIndexFromKey(book)
  if xi >= 0:
    if xi >= gExtEpubs.len: return %*{"ok": false, "error": "Epub esterno non valido"}
    epubPath = gBooksDir / stagedExtName(xi)
    if not fileExists(epubPath): epubPath = gExtEpubs[xi]
  else:
    epubPath = gBooksDir / book
  var files: seq[JsonNode] = @[]
  for e in cssZipEntries(epubPath):
    files.add(%*{"href": e.name, "size": e.size})
  files.sort(proc(a, b: JsonNode): int = cmp(a["href"].getStr, b["href"].getStr))
  return %*{"ok": true, "files": files}

proc cssContentForBook(book, href: string): JsonNode =
  ## {"ok":true,"href":..,"content":..} oppure {"ok":false,"error":..}.
  if not validBookKey(book):
    return %*{"ok": false, "error": "Nome libro non valido"}
  let h = href.replace('\\', '/').strip(chars = {'/'})
  if h.len == 0 or ".." in h.split('/') or not h.toLowerAscii().endsWith(".css"):
    return %*{"ok": false, "error": "Href non valido: " & href}
  let clean = book.strip(chars = {'/'})
  if clean == FOLDER_BOOK_KEY:
    if gFolderDir.len == 0 or not dirExists(gFolderDir):
      return %*{"ok": false, "error": "Cartella esterna non configurata"}
    let target = resolveInDir(gFolderDir, h)
    if target.len == 0:
      return %*{"ok": false, "error": "File non trovato: " & h}
    try:
      return %*{"ok": true, "href": h, "content": readFile(target)}
    except CatchableError as e:
      return %*{"ok": false, "error": e.msg}
  var epubPath: string
  let xi = extIndexFromKey(book)
  if xi >= 0:
    if xi >= gExtEpubs.len: return %*{"ok": false, "error": "Epub esterno non valido"}
    epubPath = gBooksDir / stagedExtName(xi)
    if not fileExists(epubPath): epubPath = gExtEpubs[xi]
  else:
    epubPath = gBooksDir / book
  if not fileExists(epubPath):
    return %*{"ok": false, "error": "File non trovato: " & book}
  var reader: ZipArchiveReader
  try:
    reader = openZipArchive(epubPath)
  except CatchableError as e:
    return %*{"ok": false, "error": "Impossibile aprire l'epub: " & e.msg}
  try:
    var hit = ""
    for name in reader.walkFiles():
      if name.toLowerAscii() == h.toLowerAscii():
        hit = name
        break
    if hit.len == 0:
      return %*{"ok": false, "error": "File non trovato: " & h}
    return %*{"ok": true, "href": hit, "content": reader.extractFile(hit)}
  except CatchableError as e:
    return %*{"ok": false, "error": e.msg}
  finally:
    try:
      reader.close()
    except CatchableError:
      discard

proc cssBundleForBook(book: string): JsonNode =
  ## Bundle concatenato di tutti i .css (per il rewrite lato frontend JS).
  let filesRes = cssFilesForBook(book)
  if not filesRes["ok"].getBool():
    return filesRes
  var parts: seq[string] = @[]
  for f in filesRes["files"]:
    let c = cssContentForBook(book, f["href"].getStr)
    if c.hasKey("content"):
      parts.add(c["content"].getStr)
  return %*{"ok": true, "content": "@charset \"UTF-8\";\n" & parts.join("\n")}

# ------------------------------------------------------------------
# Posizione di lettura per libro (~/.epubreader/positions.json)
# ------------------------------------------------------------------
# Stessa posizione della versione Python (app.py e _load/_save positions):
# una mappa {book_key: {cfi, href, anchor, updated}} dove ogni libro ricorda
# la sua posizione indipendentemente dagli altri. Scrittura atomica
# (.tmp + moveFile), come saveChapter.
proc positionsFile(): string =
  let dir = getHomeDir() / ".epubreader"
  try:
    createDir(dir)
  except CatchableError:
    discard
  result = dir / "positions.json"

proc loadPositions(): JsonNode =
  ## Legge positions.json; ritorna {} se assente o corrotto (app.py: _load_positions).
  result = newJObject()
  if fileExists(positionsFile()):
    try:
      let data = parseJson(readFile(positionsFile()))
      if data.kind == JObject:
        result = data
    except CatchableError:
      discard

proc savePositionToFile(book, cfi, href, anchor: string): string =
  ## Salva la posizione di lettura di `book` in positions.json
  ## (scrittura atomica .tmp + moveFile). Ritorna "" in caso di successo,
  ## altrimenti un messaggio d'errore.
  let positions = loadPositions()
  let pos = %*{
    "cfi": cfi,
    "href": href,
    "anchor": anchor[0 ..< min(100, anchor.len)],
    "updated": now().format("yyyy-MM-dd'T'HH:mm:ss")
  }
  positions[book] = pos
  let file = positionsFile()
  let tmp = file & ".tmp"
  try:
    writeFile(tmp, $positions)
    moveFile(tmp, file)
  except CatchableError as e:
    try:
      if fileExists(tmp): removeFile(tmp)
    except CatchableError:
      discard
    return "Errore durante la scrittura: " & e.msg
  return ""

# ------------------------------------------------------------------
# Sincronizzazione Dropbox (come /api/dropbox/* in app.py).
# epub_app NON linka il sync nel proprio thread (Nim vieta memoria GC
# condivisa tra thread): lancia sync.exe come sottoprocesso in background
# con --log/--result-file, e il frontend fa poll via dropboxStatus.
# Stessa finestrella di feedback (log + stato) della webui Flask.
# ------------------------------------------------------------------
var dbxHandle: HANDLE = 0  # processo sync.exe (0 = nessuno)
var dbxRunning = false
var dbxMode = ""
var dbxDry = false
var dbxLogFile = ""
var dbxResultFile = ""
var dbxResult: JsonNode = newJNull()
# Override da ~/.epubreader/config.ini [dropbox] (come app.py):
# sync_dir vuoto -> sync.exe risolve da ~/.mydrpbx/config.json working-folder.
var gSyncDirOverride = ""
var gRemoteDir = "/"

proc loadDropboxConfig() =
  ## Legge [dropbox] sync_dir/remote_dir come _load_config() in app.py.
  let cfg = configFilePath()
  if not fileExists(cfg): return
  try:
    var inDbx = false
    for rawLine in readFile(cfg).splitLines():
      let line = rawLine.strip()
      if line.startsWith("["):
        inDbx = line.toLowerAscii() == "[dropbox]"
      elif inDbx and "=" in line:
        let parts = line.split("=", maxsplit = 1)
        let k = parts[0].strip().toLowerAscii()
        let v = parts[1].strip()
        if k == "sync_dir" and v.len > 0:
          gSyncDirOverride = expandUser(v)
        elif k == "remote_dir" and v.len > 0:
          gRemoteDir = v
  except CatchableError:
    discard

proc dbxLocalDir(): string =
  ## Cartella locale effettiva: override config o stessa di sync.py.
  if gSyncDirOverride.len > 0: absolutePath(gSyncDirOverride)
  else: sync.resolveLocalDir()

proc dbxFiles(): tuple[log, res: string] =
  (getTempDir() / "dbx_sync.log", getTempDir() / "dbx_sync.json")

proc dbxReadLog(): seq[string] =
  result = @[]
  if dbxLogFile.len > 0 and fileExists(dbxLogFile):
    try:
      for line in readFile(dbxLogFile).splitLines():
        if line.strip().len > 0: result.add(line)
    except CatchableError:
      discard

proc dbxLaunch(exe: string, args: seq[string]): HANDLE =
  ## Avvia sync.exe con console MINIMIZZATA senza rubare il focus
  ## (SW_SHOWMINNOACTIVE): resta nella taskbar, la si apre solo se serve
  ## (es. blocco da ispezionare). Niente finestra vuota in primo piano.
  var si: STARTUPINFOW
  var pi: PROCESS_INFORMATION
  zeroMem(addr si, sizeof(si))
  si.cb = DWORD(sizeof(si))
  si.dwFlags = STARTF_USESHOWWINDOW
  si.wShowWindow = SW_SHOWMINNOACTIVE
  let cmd = newWideCString(quoteShellCommand(@[exe] & args))
  if CreateProcessW(nil, cmd, nil, nil, FALSE, 0, nil, nil, addr si, addr pi) == 0:
    raise newException(OSError, "Avvio sync.exe fallito (codice " & $GetLastError() & ")")
  CloseHandle(pi.hThread)
  result = pi.hProcess

proc dbxPoll() =
  ## Se il sottoprocesso e' terminato, raccoglie l'esito (una sola volta).
  if not dbxRunning or dbxHandle == 0: return
  var code: DWORD = 0
  if GetExitCodeProcess(dbxHandle, addr code) == 0 or code != DWORD(STILL_ACTIVE):
    CloseHandle(dbxHandle)
    dbxHandle = 0
    dbxRunning = false
  else:
    return  # ancora in esecuzione
  if dbxResultFile.len > 0 and fileExists(dbxResultFile):
    try:
      let r = parseJson(readFile(dbxResultFile))
      if r.hasKey("ok") and not r.hasKey("downloaded"):
        dbxResult = r  # errore scritto da sync ({ok:false, error})
      else:
        dbxResult = %*{"ok": true, "result": r}
    except CatchableError as e:
      dbxResult = %*{"ok": code == 0, "error": "log nel pannello (exit " & $code & "): " & e.msg}
  elif code != 0:
    dbxResult = %*{"ok": false, "error": "sync.exe terminato con codice " & $code}
  else:
    dbxResult = %*{"ok": true}

proc dbxSnapshot(): JsonNode =
  dbxPoll()
  result = %*{"ok": true, "running": dbxRunning, "mode": dbxMode,
    "dry": dbxDry, "log": dbxReadLog(), "result": dbxResult,
    "sync_dir": dbxLocalDir()}

# ------------------------------------------------------------------
# Bridge JS <-> Nim
# ------------------------------------------------------------------
proc invokeCallback(w: Webview; cbId: string; payload: JsonNode) =
  ## Inoltra il risultato di una chiamata bridge al callback JS.
  let js = "window._nimCallbacks[" & cbId & "](" & $payload & ")"
  w.eval(js)

proc handleBridge(w: Webview; arg: cstring) =
  ## Callback invocato dal JavaScript via window.chrome.webview.postMessage.
  try:
    let msg = parseJson($arg)
    let scope = msg["scope"].getStr()
    let name  = msg["name"].getStr()
    # callbackId robusto: numero (frontend storico) o stringa
    var cbId = ""
    if msg.hasKey("callbackId"):
      let c = msg["callbackId"]
      case c.kind
      of JInt: cbId = $c.getInt()
      of JString: cbId = c.getStr()
      else: discard

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
      var bookPath = args["book"].getStr()
      let href     = args["href"].getStr()
      let content  = args["content"].getStr()
      # "silent" (opzionale, usato dal popover in-context) è accettato per
      # compatibilità col frontend condiviso ma non ha effetti lato backend:
      # come in app.py, il ri-render del viewer è sempre client-side
      # (updateChapterDom nel frontend), quindi niente MessageBox.
      discard args.hasKey("silent") and args["silent"].getBool()
      # normalizza chiavi epub esterni ("extepub:N" -> staging __extN__.epub)
      let nxi = extIndexFromKey(bookPath)
      if nxi >= 0 and bookPath.startsWith("extepub:"):
        bookPath = stagedExtName(nxi)
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
    of "saveCss":
      # Salvataggio dall'editor CSS (stesso canale di saveChapter: il frontend
      # Python salva i css con /api/save_chapter, qui riusiamo la stessa via).
      var bookPath = args["book"].getStr()
      let href     = args["href"].getStr()
      let content  = args["content"].getStr()
      let nxi2 = extIndexFromKey(bookPath)
      if nxi2 >= 0 and bookPath.startsWith("extepub:"):
        bookPath = stagedExtName(nxi2)
      let err2 =
        if bookPath.strip(chars = {'/'}) == FOLDER_BOOK_KEY:
          saveChapterIntoFolder(gFolderDir, href, content)
        else:
          saveChapterIntoEpub(bookPath, href, content)
      invokeCallback(w, cbId, %*{"ok": err2.len == 0, "error": err2})
    of "getConfig":
      invokeCallback(w, cbId, %*{"ok": true, "book_dir": gFolderDir})
    of "cssFiles":
      invokeCallback(w, cbId, cssFilesForBook(args["book"].getStr()))
    of "cssContent":
      invokeCallback(w, cbId, cssContentForBook(args["book"].getStr(), args["href"].getStr()))
    of "cssBundle":
      invokeCallback(w, cbId, cssBundleForBook(args["book"].getStr()))
    of "dropboxStart":
      # Come POST /api/dropbox/sync in app.py: lancia sync.exe, rifiuta se busy.
      dbxPoll()
      var mode = if args.hasKey("mode"): args["mode"].getStr() else: "both"
      if mode notin ["push", "pull", "both"]:
        invokeCallback(w, cbId, %*{"ok": false, "error": "Modalita' non valida: " & mode})
      elif dbxRunning:
        invokeCallback(w, cbId, %*{"ok": false, "error": "Una sincronizzazione e' gia' in corso"})
      else:
        let dry = if args.hasKey("dry"): args["dry"].getBool() else: false
        var exe = getAppDir() / "sync.exe"
        if not fileExists(exe):
          exe = getCurrentDir() / "sync.exe"
        if not fileExists(exe):
          invokeCallback(w, cbId, %*{"ok": false, "error": "sync.exe non trovato vicino a epub_app.exe"})
        else:
          let (lf, rf) = dbxFiles()
          try:
            if fileExists(lf): removeFile(lf)
            if fileExists(rf): removeFile(rf)
          except CatchableError:
            discard
          var pargs = @[mode]
          if dry: pargs.add("--dry-run")
          # Stessi path di app.py: override [dropbox] sync_dir/remote_dir,
          # altrimenti sync.exe risolve da ~/.mydrpbx/config.json (working-folder).
          if gSyncDirOverride.len > 0:
            pargs.add("--local-dir:" & gSyncDirOverride)
          if gRemoteDir.len > 0:
            pargs.add("--remote-dir:" & gRemoteDir)
          pargs.add("--log:" & lf)
          pargs.add("--result-file:" & rf)
          try:
            dbxHandle = dbxLaunch(exe, pargs)
            dbxRunning = true; dbxMode = mode; dbxDry = dry
            dbxLogFile = lf; dbxResultFile = rf
            dbxResult = newJNull()
            invokeCallback(w, cbId, %*{"ok": true, "started": true})
          except CatchableError as e:
            dbxHandle = 0; dbxRunning = false
            invokeCallback(w, cbId, %*{"ok": false, "error": e.msg})
    of "dropboxStatus":
      # Come GET /api/dropbox/status in app.py (poll dal frontend).
      invokeCallback(w, cbId, dbxSnapshot())
    of "spellcheck", "spellAccept":
      # Spellcheck disabilitato in desktop (decisione): stub graceful, il
      # frontend mostra "non disponibile" invece di rompersi.
      invokeCallback(w, cbId, %*{"ok": false, "disabled": true,
        "error": "Controllo ortografico non disponibile nella versione desktop"})
    of "saveNote":
      let book = args["book"].getStr()
      let cfi = args["cfi"].getStr()[0 ..< min(2000, args["cfi"].getStr().len)]
      let href = args["href"].getStr()[0 ..< min(500, args["href"].getStr().len)]
      let text = args["text"].getStr()[0 ..< min(2000, args["text"].getStr().len)]
      if cfi.len == 0:
        invokeCallback(w, cbId, %*{"ok": false, "error": "CFI mancante"})
      else:
        let path = noteFileForBook(book)
        if path.len == 0:
          invokeCallback(w, cbId, %*{"ok": false, "error": "Nome libro non valido: " & book})
        else:
          let entry = %*{"ts": now().format("yyyy-MM-dd'T'HH:mm:ss"),
            "book": book, "href": href, "cfi": cfi, "text": text}
          try:
            createDir(parentDir(absolutePath(path)))
            var fh: File
            if open(fh, path, fmAppend):
              fh.writeLine($entry)
              fh.close()
            invokeCallback(w, cbId, %*{"ok": true})
          except CatchableError as e:
            invokeCallback(w, cbId, %*{"ok": false, "error": "Errore durante la scrittura: " & e.msg})
    of "getNotes":
      let book = args["book"].getStr()
      let path = noteFileForBook(book)
      if path.len == 0:
        invokeCallback(w, cbId, %*{"ok": false, "error": "Nome libro non valido"})
      else:
        var notes: seq[JsonNode] = @[]
        for s in readNoteLines(path):
          try:
            notes.add(parseJson(s))
          except CatchableError:
            discard
        invokeCallback(w, cbId, %*{"ok": true, "notes": notes})
    of "deleteNote":
      let book = args["book"].getStr()
      var cfis: seq[string] = @[]
      if args.hasKey("cfis") and args["cfis"].kind == JArray:
        for c in args["cfis"]: cfis.add(c.getStr())
      elif args.hasKey("cfi"):
        cfis.add(args["cfi"].getStr())
      if cfis.len == 0:
        invokeCallback(w, cbId, %*{"ok": false, "error": "Nessun CFI indicato"})
      else:
        let path = noteFileForBook(book)
        if path.len == 0:
          invokeCallback(w, cbId, %*{"ok": false, "error": "Nome libro non valido: " & book})
        elif not fileExists(path):
          invokeCallback(w, cbId, %*{"ok": true, "removed": 0})
        else:
          let before = readNoteLines(path)
          var kept: seq[string] = @[]
          for s in before:
            try:
              if parseJson(s)["cfi"].getStr() notin cfis: kept.add(s)
            except CatchableError:
              discard
          let werr = atomicWriteLines(path, kept)
          invokeCallback(w, cbId, %*{"ok": werr.len == 0, "error": werr,
            "removed": before.len - kept.len})
    of "upsertNote":
      let book = args["book"].getStr()
      let cfi = args["cfi"].getStr()[0 ..< min(2000, args["cfi"].getStr().len)]
      let href = args["href"].getStr()[0 ..< min(500, args["href"].getStr().len)]
      let text = args["text"].getStr()[0 ..< min(2000, args["text"].getStr().len)]
      let nbody = if args.hasKey("body"): args["body"].getStr()[0 ..< min(10000, args["body"].getStr().len)] else: ""
      if cfi.len == 0:
        invokeCallback(w, cbId, %*{"ok": false, "error": "CFI mancante"})
      else:
        let path = noteFileForBook(book)
        if path.len == 0:
          invokeCallback(w, cbId, %*{"ok": false, "error": "Nome libro non valido: " & book})
        else:
          var lines = if fileExists(path): readNoteLines(path) else: @[]
          var found = false
          for i, s in lines:
            try:
              var obj = parseJson(s)
              if obj["cfi"].getStr() == cfi and obj.getOrDefault("kind").getStr() == "note":
                obj["body"] = %nbody
                obj["updated"] = %now().format("yyyy-MM-dd'T'HH:mm:ss")
                if text.len > 0 and obj.getOrDefault("text").getStr().len == 0:
                  obj["text"] = %text
                if href.len > 0 and obj.getOrDefault("href").getStr().len == 0:
                  obj["href"] = %href
                lines[i] = $obj
                found = true
            except CatchableError:
              discard
          if not found:
            lines.add($(%*{"ts": now().format("yyyy-MM-dd'T'HH:mm:ss"),
              "book": book, "href": href, "cfi": cfi, "text": text,
              "kind": "note", "body": nbody}))
          let werr = atomicWriteLines(path, lines)
          invokeCallback(w, cbId, %*{"ok": werr.len == 0, "error": werr, "updated": found})
    of "getPosition":
      # Ritorna la posizione salvata per un libro: {ok, position} con position
      # = {cfi, href, anchor, updated} oppure null se assente (app.py: get_position).
      let book = args["book"].getStr()
      if not validBookKey(book):
        invokeCallback(w, cbId, %*{"ok": false, "error": "Nome libro non valido"})
      else:
        let positions = loadPositions()
        let pos =
          if positions.hasKey(book) and positions[book].kind == JObject:
            positions[book]
          else:
            newJNull()
        invokeCallback(w, cbId, %*{"ok": true, "position": pos})
    of "savePosition":
      # Salva la posizione di lettura di un libro (scrittura atomica su
      # positions.json). (app.py: save_position)
      let book = args["book"].getStr()
      if not validBookKey(book):
        invokeCallback(w, cbId, %*{"ok": false, "error": "Nome libro non valido: " & book})
      else:
        let err = savePositionToFile(book, args["cfi"].getStr(),
                                     args["href"].getStr(), args["anchor"].getStr())
        invokeCallback(w, cbId, %*{"ok": err.len == 0, "error": err})
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

  # Configurazione utente ~/.epubreader/config.ini (come app.py): book_dir +
  # epub_files. Il default resta la cartella del translator.
  let cfg = loadUserConfig()
  loadDropboxConfig()  # [dropbox] sync_dir/remote_dir, come app.py
  echo "[dbx] locale: ", dbxLocalDir(), "  remoto: ", gRemoteDir
  gFolderDir = cfg.bookDir
  gExtEpubs = cfg.epubFiles.filterIt(fileExists(it))
  if cfg.epubFiles.len != gExtEpubs.len:
    echo "[epub] AVVISO: alcuni epub esterni in config.ini non esistono, ignorati"

  # Epub NON impacchettato (output del translator): se la cartella esiste la
  # mappiamo su https://ext/ (in app.py: --book-dir).
  if gFolderDir.len > 0 and dirExists(gFolderDir):
    echo "[epub] Epub da cartella: ", gFolderDir, "  (su https://", FOLDER_HOST, "/)"
  else:
    if gFolderDir.len > 0:
      echo "[epub] AVVISO: cartella esterna non trovata, ignorata: ", gFolderDir
    gFolderDir = ""

  # Staging degli epub esterni in epubs/__extN__.epub (servibili via https://books/)
  if not dirExists(gBooksDir):
    try:
      createDir(gBooksDir)
    except CatchableError:
      discard
  stageExtEpubs()
  if gExtEpubs.len > 0:
    echo "[epub] Epub esterni (", gExtEpubs.len, "):"
    for p in gExtEpubs:
      echo "[epub]   - ", p

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
