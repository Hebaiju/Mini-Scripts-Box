# 雨云自动注册 (Rainyun-Zhuce)

自动批量注册雨云账号，基于 Selenium 模拟浏览器操作，集成腾讯点选验证码自动识别。

## 环境要求

| 依赖 | 说明 |
|------|------|
| Python 3.12+ | 推荐使用虚拟环境 |
| Google Chrome | Selenium 需要系统已安装 Chrome |

## 安装

```bash
pip install -r requirements.txt
```

依赖清单：

| 包名 | 用途 |
|------|------|
| selenium | 浏览器自动化 |
| webdriver-manager | 自动管理 ChromeDriver 版本 |
| ddddocr | OCR 备用识别（暂未启用） |
| opencv-python-headless | ICR 验证码图像匹配 |
| requests | HTTP 请求 |

## 账号准备

在项目目录创建 `accounts_passwords.csv`（⚠️ **此文件包含密码明文，已加入 .gitignore，不会提交到仓库**）：

```csv
id,account,password,y/n
1,testuser1,password123,0
2,testuser2,password456,0
```

- `y/n`：`0` = 未使用，`1` = 已注册

## 配置

编辑 `main.py` 顶部配置区：

```python
CSV_FILE = "accounts_passwords.csv"   # 账号文件路径
REG_URL = "https://app.rainyun.com/auth/reg"  # 注册地址
BATCH_SIZE = 10                       # 每次批量注册数量
```

## 运行

双击 `run.bat`，或命令行：

```bash
python _launcher.py
```

程序会按顺序注册账号，每个账号独立打开/关闭浏览器，账号间有随机延迟（默认 10~25 秒）。

## 文件说明

| 文件 | 说明 |
|------|------|
| `run.bat` | 双击启动入口 |
| `_launcher.py` | Python 入口 |
| `main.py` | 核心逻辑：读 CSV → 填表 → 过验证码 → 标记 |
| `ICR.py` | OpenCV 模板匹配，识别腾讯点选验证码 |
| `stealth.min.js` | 反检测脚本，注入浏览器隐藏自动化特征 |
| `id.py` | 账号 ID 生成辅助 |

## 安全提醒

- **`accounts_passwords.csv` 包含账号密码，切勿提交到 Git 或分享**
- 批量注册请遵守雨云服务条款
- 触发"验证频繁"后建议增大 `BATCH_SIZE` 减少批量数量，或延长账号间延迟
