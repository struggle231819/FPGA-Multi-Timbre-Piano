@echo off
chcp 65001 >nul
title FPGA-Multi-Timbre-Piano 一键开源发布助手 (struggle231819)

echo ============================================================================
echo   🎹 FPGA 多音色智能电子琴 (FPGA-Multi-Timbre-Piano) 一键开源发布脚本
echo   目标账号: struggle231819
echo   目标仓库: https://github.com/struggle231819/FPGA-Multi-Timbre-Piano
echo ============================================================================
echo.

where gh >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    echo [检测到 GitHub CLI] 正在尝试直接创建远程仓库并推送...
    git init
    git branch -M main
    git add .
    git commit -m "Initial open-source release: FPGA Multi-Timbre Smart Piano (Tang Primer 25K)" 2>nul
    gh repo create struggle231819/FPGA-Multi-Timbre-Piano --public --description "🎹 基于 Sipeed Tang Primer 25K (GW5A-25) 的 64 复音 12 音色全硬件 FPGA 多音色智能电子琴 | 64-Voice Polyphonic FM & Physical-Modeling Smart Piano Synthesizer in Verilog" --source=. --remote=origin --push
    if %ERRORLEVEL% EQU 0 (
        echo.
        echo ✅ 已成功自动创建并推送到: https://github.com/struggle231819/FPGA-Multi-Timbre-Piano
        start "" "https://github.com/ges280388-hub/FPGA-Multi-Timbre-Piano"
        pause
        exit /b 0
    )
)

echo [步骤 1/2] 正在为你打开已填好仓库名称与简介的 GitHub 新建仓库页面...
start "" "https://github.com/new?name=FPGA-Multi-Timbre-Piano&visibility=public"
echo.
echo 👉 请在弹出的浏览器页面中直接滑到底部，点击绿色的【Create repository】按钮！
echo    （注意：不要勾选 Add a README file，保持空仓库即可）
echo.
pause

echo.
echo [步骤 2/2] 正在打包本地源码、README.md、MIT 协议与烧录固件并推送到 GitHub...
git init
git branch -M main
git add .
git commit -m "Initial open-source release: FPGA Multi-Timbre Smart Piano (Tang Primer 25K)"
git remote remove origin 2>nul
git remote add origin https://github.com/struggle231819/FPGA-Multi-Timbre-Piano.git
git push -u origin main

echo.
echo ============================================================================
echo ✅ 全部完成！正在打开你的开源仓库主页：
echo    https://github.com/struggle231819/FPGA-Multi-Timbre-Piano
echo ============================================================================
start "" "https://github.com/struggle231819/FPGA-Multi-Timbre-Piano"
pause
