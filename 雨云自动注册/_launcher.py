import os
import sys

# 强制切换到脚本所在目录，保证能找到 CSV 和其他资源文件
os.chdir(os.path.dirname(os.path.abspath(__file__)))

# 运行主程序
with open("main.py", "r", encoding="utf-8") as f:
    code = compile(f.read(), "main.py", "exec")
    exec(code, globals(), locals())

