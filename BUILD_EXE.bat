@echo off
setlocal
title Supermart POS - build the EXE
cd /d "%~dp0"

echo.
echo  ============================================================
echo    SUPERMART POS  -  BUILD THE WINDOWS APP (.exe)
echo  ============================================================
echo.
echo  This takes a few minutes the first time. Leave the window open.
echo.

rem ---------- 1. read the two values from server_config.txt ----------
if not exist "server_config.txt" (
  echo  [X] server_config.txt is missing.
  echo      Open it, paste your Supabase URL and anon key, save, run me again.
  echo.
  pause
  exit /b 1
)

set "SB_URL="
set "SB_KEY="
for /f "usebackq tokens=1,* delims==" %%A in ("server_config.txt") do (
  if /i "%%A"=="SB_URL" set "SB_URL=%%B"
  if /i "%%A"=="SB_KEY" set "SB_KEY=%%B"
)

if "%SB_URL%"=="" (
  echo  [X] Could not read SB_URL from server_config.txt
  echo      Make sure the line looks exactly like:   SB_URL=https://xxxx.supabase.co
  echo.
  pause
  exit /b 1
)
if "%SB_KEY%"=="" (
  echo  [X] Could not read SB_KEY from server_config.txt
  echo      Make sure the line looks exactly like:   SB_KEY=eyJhbGciOi...
  echo.
  pause
  exit /b 1
)
echo  [1/5] Server settings read OK.
echo        %SB_URL%

rem ---------- 2. is Flutter installed? ----------
where flutter >nul 2>&1
if errorlevel 1 (
  echo.
  echo  [X] Flutter is not installed on this PC. Do this once:
  echo.
  echo      1. Download the Flutter SDK:  https://docs.flutter.dev/get-started/install/windows
  echo         Unzip it to  C:\flutter  and tick "Add to PATH" during setup,
  echo         or add  C:\flutter\bin  to your PATH yourself.
  echo      2. Open your Visual Studio Installer and make sure the workload
  echo         "Desktop development with C++" is ticked.
  echo      3. Close this window, open a new one, and run me again.
  echo.
  pause
  exit /b 1
)
for /f "tokens=*" %%v in ('flutter --version 2^>nul') do (
  echo  [2/5] %%v
  goto :flutterok
)
:flutterok

rem ---------- 3. clean stale generated files before building ----------
echo  [3/5] Cleaning stale build artifacts from earlier project paths...
call flutter clean
if exist "build\windows" rmdir /s /q "build\windows"
if exist "build\windows\x64" rmdir /s /q "build\windows\x64"

rem ---------- 4. build ----------
echo  [4/5] Downloading libraries and building... (this is the slow part)
call flutter pub get
if errorlevel 1 goto :buildfailed

rem --no-tree-shake-icons keeps every icon in the app; the trimmed icon font drops some
call flutter build windows --release --no-tree-shake-icons --dart-define=SB_URL=%SB_URL% --dart-define=SB_KEY=%SB_KEY%
if errorlevel 1 goto :buildfailed

rem ---------- 5. copy the finished app into DEPLOY ----------
echo  [5/5] Copying the finished app into the DEPLOY folder...
if exist "DEPLOY\SupermartPOS" rmdir /s /q "DEPLOY\SupermartPOS"
mkdir "DEPLOY\SupermartPOS" 2>nul
xcopy /e /i /y /q "build\windows\x64\runner\Release\*" "DEPLOY\SupermartPOS\" >nul
if errorlevel 1 (
  echo  [!] The app was built, but copying to DEPLOY failed.
  echo      You can still find it in: build\windows\x64\runner\Release
  echo.
  pause
  exit /b 1
)

echo.
echo  ============================================================
echo    DONE.
echo.
echo    Your app is here:   %cd%\DEPLOY\SupermartPOS
echo.
echo    Copy that whole folder (a USB stick is fine) to each shop PC,
echo    then make a desktop shortcut to  supermart_pos.exe  on each one.
echo    No setup is needed on those PCs - just sign in and sell.
echo  ============================================================
echo.
start "" "%cd%\DEPLOY"
pause
exit /b 0

:buildfailed
echo.
echo  ============================================================
echo    The build failed. The messages above say why. Usual causes:
echo      - Visual Studio is missing the "Desktop development with C++" workload
echo      - No internet connection to download the libraries the first time
echo      - A firewall blocking pub.dev
echo  ============================================================
echo.
pause
exit /b 1
