@echo off
chcp 65001 >nul
setlocal
:: 强制切换到bat所在目录
cd /d "%~dp0"
:: 执行入口脚本
python _launcher.py
endlocal
