@echo off
echo Compilazione epub_app.exe (standalone, WebView2) ...

nim --app:gui -d:release --opt:size c ^
  --passL:-static-libgcc ^
  --passL:-static-libstdc++ ^
  --passL:-Wl,-Bstatic ^
  --passL:-lwinpthread ^
  --passL:-Wl,-Bdynamic ^
  epub_app.nim

if %ERRORLEVEL% EQU 0 (
  echo.
  echo OK - Compilazione riuscita: epub_app.exe
) else (
  echo.
  echo ERRORE - Compilazione fallita
  pause
)
