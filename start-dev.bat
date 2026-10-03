@echo off
cd /d "%~dp0"
title Study Smart — Vite
echo.
echo === Study Smart frontend ===
echo.

if not exist "node_modules" (
  echo Running npm install first ^(may take a few minutes^)...
  call npm.cmd install --no-audit --no-fund
  if errorlevel 1 (
    echo.
    echo npm install failed. Fix the errors above ^(proxy/network^), then run this batch again.
    pause
    exit /b 1
  )
)

echo Starting dev server...
echo Keep this window open. When ready, open: http://localhost:5173
echo.
call npm.cmd run dev

echo.
pause
