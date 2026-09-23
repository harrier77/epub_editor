@echo off
echo Compilazione epub_app.exe (standalone, WebView2) ...

nim --app:gui -d:release --opt:size c ^
  --passL:-static-libgcc ^
  --passL:-static-libstdc++ ^
  --passL:-Wl,-Bstatic ^
  --passL:-lwinpthread ^
  --passL:-Wl,-Bdynamic ^
  epub_app.nim

if %ERRORLEVEL% NEQ 0 (
  echo.
  echo ERRORE - Compilazione epub_app fallita
  pause
  exit /b 1
)

echo.
echo Compilazione sync.exe (console, richiede -d:ssl per HTTPS Dropbox) ...
nim -d:release -d:ssl c sync.nim

if %ERRORLEVEL% EQU 0 (
  echo.
  echo OK - Compilazione riuscita: epub_app.exe + sync.exe
  echo NOTA: tenere sync.exe accanto a epub_app.exe per il pannello Dropbox.
) else (
  echo.
  echo ERRORE - Compilazione sync fallita
  pause
)
