import std/[httpclient, json, os, times, tables, strutils, uri, parseopt, sequtils, sets]

const
  Remote = ""          # root app folder ("" non "/")
  Api = "https://api.dropboxapi.com"
  Content = "https://content.dropboxapi.com"

# Autenticazione condivisa come in dbx_auth.py:
# segreti fuori dall'app, in ~/.mydrpbx/ :
#   refresh_token.txt -> refresh token (sensibile)
#   config.json       -> app_key e scopes
proc secretDir(): string = getHomeDir() / ".mydrpbx"
proc tokenFile(): string = secretDir() / "refresh_token.txt"
proc configFile(): string = secretDir() / "config.json"

proc getAppKey*(): string =
  # 1) env (override)  2) config.json (come dbx_auth.py)
  result = getEnv("DROPBOX_APP_KEY").strip()
  if result.len > 0: return result
  let cf = configFile()
  if not fileExists(cf):
    raise newException(IOError, "Manca " & cf & ": crea config.json con {\"app_key\": ... } o imposta DROPBOX_APP_KEY")
  try:
    result = parseJson(readFile(cf))["app_key"].getStr().strip()
  except CatchableError:
    raise newException(IOError, "config.json non valido in " & cf & ": serve {\"app_key\": ... }")
  if result.len == 0:
    raise newException(IOError, "app_key vuoto in " & cf)

proc resolveLocalDir*(): string =
  ## Come _resolve_local() in sync.py: 'working-folder' da ~/.mydrpbx/config.json
  ## (stesso file letto da dbx_auth.py), altrimenti 'drpbx' accanto a sync.exe
  ## (come 'drpbx' accanto a sync.py in Python).
  try:
    let wf = parseJson(readFile(configFile())).getOrDefault("working-folder").getStr("").strip()
    if wf.len > 0:
      return absolutePath(expandTilde(wf))
  except CatchableError:
    discard
  result = getAppDir() / "drpbx"

proc getRefreshToken*(): string =
  let tf = tokenFile()
  if fileExists(tf):
    result = readFile(tf).strip()
    if result.len > 0: return result
  raise newException(IOError, "Autenticazione Dropbox necessaria: esegui C:/Users/pr30565/Desktop/python/dropbox/dbx_auth.py da terminale per generare " & tf)

proc getAccessToken(): string =
  # Flow PKCE/pubblico come dbx_auth.py (DropboxOAuth2FlowNoRedirect con use_pkce=True):
  # nessun app secret richiesto, basta client_id + refresh token.
  # Se DROPBOX_APP_SECRET e' impostato lo includiamo (compat. con app confidential).
  let refresh = getRefreshToken()
  let key = getAppKey()
  let secret = getEnv("DROPBOX_APP_SECRET").strip()
  var client = newHttpClient()
  var body = "grant_type=refresh_token&refresh_token=" & encodeUrl(refresh) &
             "&client_id=" & encodeUrl(key)
  if secret.len > 0:
    body &= "&client_secret=" & encodeUrl(secret)
  client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
  let resp = client.postContent(Api & "/oauth2/token", body)
  result = parseJson(resp)["access_token"].getStr()
  client.close()

proc listAll(token: string, path: string): seq[JsonNode] =
  var client = newHttpClient()
  client.headers = newHttpHeaders({
    "Authorization": "Bearer " & token,
    "Content-Type": "application/json"
  })
  var body = %*{"path": path, "recursive": true}
  var res = parseJson(client.postContent(Api & "/2/files/list_folder", $body))
  result = res["entries"].getElems()
  while res["has_more"].getBool():
    body = %*{"cursor": res["cursor"]}
    res = parseJson(client.postContent(Api & "/2/files/list_folder/continue", $body))
    result.add res["entries"].getElems()
  client.close()

proc localPath(root, rel: string): string =
  let parts = rel.split('/')
  if rel.len == 0 or parts.anyIt(it in ["", ".."] or '\\' in it or ':' in it):
    raise newException(ValueError, "Percorso non valido")
  result = normalizedPath(root / rel)
  let rootN = normalizedPath(root)
  if result != rootN and not result.startsWith(rootN & DirSep):
    raise newException(ValueError, "Percorso fuori dalla cartella")

proc buildIndexes(token, localDir, remoteDir: string):
    (Table[string, string], Table[string, JsonNode]) =
  var remote: Table[string, JsonNode]
  let prefix = if remoteDir.len > 0: remoteDir & "/" else: ""
  try:
    for e in listAll(token, remoteDir):
      if e[".tag"].getStr() == "file":
        let pd = e["path_display"].getStr()
        let rel = if prefix.len > 0: pd[prefix.len .. ^1] else: pd.strip(chars={'/'})
        discard localPath(localDir, rel)
        remote[rel] = e
  except: discard   # path not found → empty

  var local: Table[string, string]
  var seen: HashSet[string]
  seen.incl(localDir.expandFilename)
  proc walk(base, relPrefix: string) =
    for entry in walkDir(base):
      let rp = entry.path.expandFilename
      if rp in seen: continue
      seen.incl(rp)
      let rel = if relPrefix.len == 0: entry.path.extractFilename
                else: relPrefix & "/" & entry.path.extractFilename
      if entry.path.endsWith(".tmp"): continue
      # Come entry.is_dir() in sync.py (follow_symlinks=True di default):
      # walkDir classifica i symlink come pcLinkToDir/pcLinkToFile, bisogna
      # seguirli (es. drpbx/target -> translator/target), i cicli sono
      # bloccati dal seen-set sui realpath qui sopra.
      if entry.kind in {pcDir, pcLinkToDir}:
        walk(entry.path, rel)
      else:
        local[rel] = entry.path
  walk(localDir, "")
  (local, remote)

proc serverEpoch(md: JsonNode): float =
  let s = md["server_modified"].getStr()
  parseTime(s, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc()).toUnixFloat()

proc download(token: string; remote: Table[string, JsonNode];
              local: Table[string, string]; dry: bool; root: string;
              emit: proc(msg: string)): int =
  for rel, md in remote:
    let lp = localPath(root, rel)
    let cur = if rel in local: getLastModificationTime(lp).toUnixFloat() else: 0.0
    if rel notin local or cur < serverEpoch(md):
      emit((if dry: "  [dry] DOWN " else: "  DOWN  ") & rel)
      inc result
      if not dry:
        createDir(lp.parentDir)
        var client = newHttpClient()
        client.headers = newHttpHeaders({
          "Authorization": "Bearer " & token,
          "Dropbox-API-Arg": $(%*{"path": "/" & rel})
        })
        let data = client.postContent(Content & "/2/files/download", "")
        writeFile(lp, data)
        setLastModificationTime(lp, fromUnix(int64(serverEpoch(md))))
        client.close()

proc upload(token: string; local: Table[string, string];
            remote: Table[string, JsonNode]; dry: bool; root: string;
            emit: proc(msg: string)): int =
  for rel, lp in local:
    let rm = remote.getOrDefault(rel)
    let need = rm.isNil or getLastModificationTime(lp).toUnixFloat() > serverEpoch(rm)
    if need:
      emit((if dry: "  [dry] UP   " else: "  UP    ") & rel)
      inc result
      if not dry:
        var client = newHttpClient()
        client.headers = newHttpHeaders({
          "Authorization": "Bearer " & token,
          "Content-Type": "application/octet-stream",
          "Dropbox-API-Arg": $(%*{
            "path": "/" & rel,
            "mode": "overwrite",
            "autorename": true
          })
        })
        let data = readFile(lp)
        let resp = parseJson(client.postContent(Content & "/2/files/upload", data))
        setLastModificationTime(lp, fromUnix(int64(serverEpoch(resp))))
        client.close()

proc runSync*(mode: string; dry = false; localDir = ""; remoteDir = "";
             progress: proc(msg: string) = nil): JsonNode =
  proc emit(msg: string) =
    if progress != nil: progress(msg) else: echo msg
  let token = getAccessToken()
  var loc = if localDir.len > 0: absolutePath(localDir)
            else: resolveLocalDir()  # come _resolve_local() in sync.py
  createDir(loc)
  var rem = if remoteDir.len > 0: remoteDir else: Remote
  # Come path.rstrip("/") in sync.py list_all: "/" -> "" (root app folder).
  if rem.len > 0:
    rem = rem.strip(leading = false, trailing = true, chars = {'/'})
  let desc = case mode
    of "push": "locale -> remoto"
    of "pull": "remoto -> locale"
    else: "bidirezionale"
  emit("Sync " & desc & " tra '" & loc & DirSep & "' e '" & rem & "'" &
       (if dry: " (DRY-RUN)" else: ""))
  let (local, remote) = buildIndexes(token, loc, rem)
  var down, up = 0
  if mode in ["pull", "both"]:
    down = download(token, remote, local, dry, loc, emit)
  if mode in ["push", "both"]:
    up = upload(token, local, remote, dry, loc, emit)
  emit("Fatto: " & $down & " scaricati, " & $up & " caricati.")
  %*{"mode": mode, "dry": dry, "downloaded": down, "uploaded": up,
     "local_dir": loc, "remote_dir": rem}

proc main*() =
  ## Entry-point CLI (equivalente di `if __name__ == "__main__"`):
  ## eseguito solo con `when isMainModule`, mai all'import.
  ## Opzioni extra per il lancio come sottoprocesso da epub_app:
  ##   --local-dir=X --remote-dir=X --log=X.log --result-file=X.json
  var mode = "both"
  var dry = false
  var localDir, remoteDir, logFile, resultFile = ""
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if key in ["push", "pull", "both"]: mode = key
    of cmdLongOption, cmdShortOption:
      case key
      of "dry-run", "dry": dry = true
      of "local-dir": localDir = val
      of "remote-dir": remoteDir = val
      of "log": logFile = val
      of "result-file": resultFile = val
      else: discard
    else: discard
  try:
    var progress: proc(msg: string) = nil
    if logFile.len > 0:
      # tee: echo a video + append su file (letto in poll da epub_app)
      let lf = logFile
      progress = proc(msg: string) =
        echo msg
        try:
          var fh: File
          if open(fh, lf, fmAppend):
            fh.writeLine(msg)
            fh.close()
        except CatchableError:
          discard
    let res = runSync(mode, dry, localDir, remoteDir, progress)
    if resultFile.len > 0:
      try:
        writeFile(resultFile, $res)
      except CatchableError as e:
        stderr.writeLine("sync: impossibile scrivere " & resultFile & ": " & e.msg)
        quit(1)
  except CatchableError as e:
    stderr.writeLine("sync: " & e.msg)
    if logFile.len > 0:
      try:
        var fh: File
        if open(fh, logFile, fmAppend):
          fh.writeLine("ERRORE: " & e.msg)
          fh.close()
      except CatchableError:
        discard
    if resultFile.len > 0:
      try:
        writeFile(resultFile, $(%*{"ok": false, "error": e.msg}))
      except CatchableError:
        discard
    quit(1)

when isMainModule:
  main()