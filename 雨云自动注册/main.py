import os
import sys
import csv
import logging
import time
import random
import re
import requests

from selenium import webdriver
from selenium.webdriver import ActionChains
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.wait import WebDriverWait
from selenium.common.exceptions import TimeoutException, NoSuchElementException

# ============ 配置 ============
CSV_FILE = "accounts_passwords.csv"
REG_URL = "https://app.rainyun.com/auth/reg"
BATCH_SIZE = 1  # 每次批量注册的账号数量（可修改）

# ============ 初始化日志 ============
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


def read_unused_accounts(n):
    """从CSV中读取前n个未使用的账号，返回 [(id, account, password, row_index), ...]"""
    results = []
    with open(CSV_FILE, "r", encoding="utf-8-sig") as f:
        reader = csv.reader(f)
        header = next(reader)  # 跳过表头
        for i, row in enumerate(reader):
            if len(row) >= 4 and row[3].strip() == "0":
                account_id = row[0].strip()
                account = row[1].strip()
                password = row[2].strip()
                results.append((account_id, account, password, i))
                logger.info(f"找到未使用账号: id={account_id}, account={account}")
                if len(results) >= n:
                    break

    if not results:
        logger.warning("没有找到未使用的账号")
    else:
        logger.info(f"共找到 {len(results)} 个未使用账号")

    return results


def mark_account_used(row_index):
    """将指定行标记为已使用（y/n 改为 1）"""
    with open(CSV_FILE, "r", encoding="utf-8-sig") as f:
        reader = csv.reader(f)
        all_rows = list(reader)

    # row_index 是数据行索引，对应 all_rows[row_index + 1]（+1 因为表头）
    target = row_index + 1
    if len(all_rows[target]) >= 4:
        all_rows[target][3] = "1"
        logger.info(f"已标记 id={all_rows[target][0]} 为已使用")
    else:
        all_rows[target].append("1")

    with open(CSV_FILE, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.writer(f)
        writer.writerows(all_rows)


def init_browser(account_id):
    """初始化 Selenium 浏览器（有界面模式）"""
    ops = Options()
    ops.add_argument("--no-sandbox")
    ops.add_argument("--disable-dev-shm-usage")
    ops.add_argument("--disable-extensions")
    ops.add_argument("--disable-plugins")
    ops.add_argument("--window-size=1920,1080")

    service = Service()
    driver = webdriver.Chrome(service=service, options=ops)

    # 注入 stealth 反检测脚本
    if os.path.exists("stealth.min.js"):
        with open("stealth.min.js", "r") as f:
            js = f.read()
        driver.execute_cdp_cmd("Page.addScriptToEvaluateOnNewDocument", {"source": js})
        logger.info("已注入 stealth 反检测脚本")

    return driver


# ============ 验证码相关函数 ============

def download_image(url, filename, user_agent=None):
    """下载图片到 temp 目录"""
    os.makedirs("temp", exist_ok=True)
    headers = {}
    if user_agent:
        headers['User-Agent'] = user_agent
    try:
        response = requests.get(url, headers=headers, timeout=10)
        if response.status_code == 200:
            path = os.path.join("temp", filename)
            with open(path, "wb") as f:
                f.write(response.content)
            return True
        else:
            logger.error(f"下载图片失败！状态码: {response.status_code}")
            return False
    except Exception as e:
        logger.error(f"下载图片异常: {e}")
        return False


def get_url_from_style(style):
    """从 CSS style 中提取 url()"""
    match = re.search(r'url\(["\']?(.*?)["\']?\)', style)
    return match.group(1) if match else None


def download_captcha_img(driver, wait):
    """下载验证码背景图和目标图标"""
    # 清理旧文件
    if os.path.exists("temp"):
        for fname in os.listdir("temp"):
            fpath = os.path.join("temp", fname)
            if os.path.isfile(fpath) or os.path.islink(fpath):
                os.remove(fpath)

    try:
        current_ua = driver.execute_script("return navigator.userAgent;")
    except Exception:
        current_ua = None

    # 等待验证码图片完全加载（background-image URL 不为空且不是占位符）
    time.sleep(1.5)

    # 1. 背景图（slideBg 的 background-image）
    slideBg = wait.until(EC.visibility_of_element_located((By.ID, "slideBg")))
    img1_style = slideBg.get_attribute("style")
    img1_url = get_url_from_style(img1_style)
    logger.info(f"开始下载验证码背景图: {img1_url[:80]}...")
    download_image(img1_url, "captcha.jpg", user_agent=current_ua)

    # 2. 目标图标（instruction 里的 img src）
    sprite = wait.until(EC.visibility_of_element_located((By.CSS_SELECTOR, ".tc-instruction-icon img")))
    img2_url = sprite.get_attribute("src")
    logger.info(f"开始下载目标图标: {img2_url[:80]}...")
    download_image(img2_url, "sprite.jpg", user_agent=current_ua)


def process_captcha(driver, wait, max_retries=5):
    """处理腾讯点选验证码，最多重试 max_retries 次"""
    for attempt in range(max_retries):
        logger.info(f"--- 验证码处理 第{attempt + 1}/{max_retries}次 ---")

        # 每次重试前，确保切回验证码 iframe
        if attempt == 0:
            # 第1次：已经在 iframe 里（由主程序切进来的）
            pass
        else:
            # 第2~n次：重新切回 iframe
            try:
                driver.switch_to.default_content()
                captcha_iframe = driver.find_element(By.CSS_SELECTOR, "iframe[id^='tcaptcha_iframe']")
                driver.switch_to.frame(captcha_iframe)
                logger.info("已重新切回验证码 iframe")
            except Exception as e:
                logger.error(f"切回 iframe 失败: {e}")
                continue

        try:
            # 等待验证码内容加载
            wait.until(EC.presence_of_element_located((By.ID, "slideBg")))

            # 下载两张图
            download_captcha_img(driver, wait)

            # ICR 识别
            import ICR
            positions = ICR.find_part_positions("temp/captcha.jpg", "temp/sprite.jpg", 'template')

            if not positions:
                logger.warning("未识别到图案位置，刷新重试...")
                refresh_btn = driver.find_elements(By.CSS_SELECTOR, "#ticon_refresh")
                if refresh_btn:
                    refresh_btn[0].click()
                    time.sleep(2)
                continue

            logger.info(f"识别到 {len(positions)} 个点击位置")

            # 坐标换算 + 逐个点击
            slideBg = driver.find_element(By.ID, "slideBg")

            # 用 size 属性获取浏览器实际渲染尺寸，比解析 style 更可靠
            bg_size = slideBg.size  # {'width': xxx, 'height': xxx}
            bg_width = float(bg_size['width'])
            bg_height = float(bg_size['height'])
            logger.info(f"slideBg 渲染尺寸: {bg_width} x {bg_height}")

            import cv2
            captcha_img = cv2.imread("temp/captcha.jpg")
            raw_w, raw_h = captcha_img.shape[1], captcha_img.shape[0]
            logger.info(f"验证码图片像素: {raw_w} x {raw_h}")

            for i, (x, y) in enumerate(positions):
                # ICR 返回的是图片像素坐标，映射到元素内偏移（相对元素中心）
                final_x = int(x / raw_w * bg_width - bg_width / 2)
                final_y = int(y / raw_h * bg_height - bg_height / 2)
                logger.info(f"  点击第{i+1}个: 原始({x:.1f},{y:.1f}) -> 偏移({final_x},{final_y})")
                ActionChains(driver).move_to_element_with_offset(slideBg, final_x, final_y).click().perform()
                time.sleep(random.uniform(0.3, 0.8))

            # 点击确定按钮（不用 scrollIntoView，iframe 浮层不能滚动，否则会导致弹窗位移）
            confirm_btn = wait.until(EC.element_to_be_clickable((By.XPATH, "//*[@id='tcStatus']/div[2]/div[2]/div/div")))
            logger.info("点击确定按钮提交验证码")
            driver.execute_script("arguments[0].click();", confirm_btn)

            # 等待结果：检测 tcOperation 的 class
            time.sleep(3)
            try:
                result_elem = driver.find_element(By.XPATH, "//*[@id='tcOperation']")
                result_class = result_elem.get_attribute("class")
                logger.info(f"tcOperation class: {result_class}")

                if "show-success" in result_class:
                    logger.info("✅ 验证码通过！")
                    driver.switch_to.default_content()
                    return True
                else:
                    logger.warning(f"⚠️ 验证码未通过，class={result_class}")
            except Exception:
                # tcOperation 元素还没出现，再等一下
                time.sleep(2)
                try:
                    result_elem = driver.find_element(By.XPATH, "//*[@id='tcOperation']")
                    result_class = result_elem.get_attribute("class")
                    if "show-success" in result_class:
                        logger.info("✅ 验证码通过！")
                        driver.switch_to.default_content()
                        return True
                except Exception:
                    logger.warning("⚠️ 未检测到 tcOperation 元素，可能未通过")

            # 未通过，点击刷新按钮换图，继续下一次循环
            logger.info("点击刷新按钮，准备重试...")
            refresh_btn = driver.find_elements(By.CSS_SELECTOR, "#ticon_refresh")
            if refresh_btn:
                refresh_btn[0].click()
                time.sleep(random.uniform(5, 8))
            else:
                try:
                    reload_btn = driver.find_element(By.XPATH, "//*[@id='reload']")
                    reload_btn.click()
                    time.sleep(random.uniform(5, 8))
                except Exception:
                    logger.warning("未找到刷新按钮，等待自动刷新...")
                    time.sleep(5)

        except Exception as e:
            logger.error(f"验证码处理异常: {e}")
            import traceback
            traceback.print_exc()

    logger.error(f"❌ 验证码处理失败，已重试 {max_retries} 次")
    return False


def register_one(account_id, account, password, row_index):
    """
    注册单个账号的完整流程。
    返回 True（成功）或 False（失败）。
    由主程序调用，每个账号独立开浏览器、关浏览器。
    """
    driver = None
    try:
        # 打开浏览器
        logger.info(f"[{account}] 正在打开浏览器")
        driver = init_browser(account_id)
        driver.get(REG_URL)
        logger.info(f"[{account}] 浏览器已打开注册页面")

        # 等待页面加载
        time.sleep(random.uniform(2, 4))

        # 填写注册表单
        wait = WebDriverWait(driver, 15)
        driver.implicitly_wait(5)
        logger.info(f"[{account}] 开始填写注册表单...")

        # 用户名
        username_input = wait.until(EC.visibility_of_element_located((By.NAME, "register-username")))
        username_input.clear()
        username_input.send_keys(account)
        logger.info(f"[{account}] 已填入用户名: {account}")
        time.sleep(random.uniform(0, 2))

        # 密码
        password_input = wait.until(EC.visibility_of_element_located((By.NAME, "register-password")))
        password_input.clear()
        password_input.send_keys(password)
        logger.info(f"[{account}] 已填入密码")
        time.sleep(random.uniform(0, 2))

        # 重复密码
        repassword_input = wait.until(EC.visibility_of_element_located((By.NAME, "register-repassword")))
        repassword_input.clear()
        repassword_input.send_keys(password)
        logger.info(f"[{account}] 已填入重复密码")

        # 勾选服务条款（点 label，避免被遮挡）
        checkbox = driver.find_element(By.ID, "register-privacy-policy")
        privacy_label = driver.find_element(By.CSS_SELECTOR, "label[for='register-privacy-policy']")
        if not checkbox.is_selected():
            privacy_label.click()
            logger.info(f"[{account}] 已勾选服务条款")
        else:
            logger.info(f"[{account}] 服务条款已勾选")

        time.sleep(random.uniform(0, 2))

        # 点击立即注册
        submit_btn = wait.until(EC.element_to_be_clickable((By.CSS_SELECTOR, "button[type='submit']")))
        submit_btn.click()
        logger.info(f"[{account}] 已点击立即注册")

        # 等待验证码出现
        time.sleep(random.uniform(3, 5))

        # 处理验证码
        logger.info(f"[{account}] 等待验证码弹出...")
        try:
            captcha_iframe = wait.until(
                EC.visibility_of_element_located((By.CSS_SELECTOR, "iframe[id^='tcaptcha_iframe']"))
            )
            driver.switch_to.frame(captcha_iframe)
            logger.info(f"[{account}] 已进入验证码 iframe")
            captcha_ok = process_captcha(driver, wait)
            driver.switch_to.default_content()

            if not captcha_ok:
                logger.error(f"[{account}] ❌ 验证码处理失败")
                return False

            logger.info(f"[{account}] ✅ 验证码通过")
            time.sleep(random.uniform(2, 4))
        except TimeoutException:
            logger.error(f"[{account}] 未检测到验证码弹窗")
            return False

        # 标记账号为已使用
        mark_account_used(row_index)
        logger.info(f"[{account}] ✅ 注册流程完成")
        return True

    except Exception as e:
        logger.error(f"[{account}] 注册异常: {e}")
        import traceback
        traceback.print_exc()
        return False

    finally:
        # 无论成功失败，都关闭浏览器
        if driver:
            time.sleep(random.uniform(1, 3))
            logger.info(f"[{account}] 关闭浏览器...")
            driver.quit()


# ============ 主程序入口 ============
if __name__ == "__main__":
    logger.info("========== 雨云自动注册 ==========")
    logger.info(f"批量注册数量: {BATCH_SIZE}")

    # 读取 BATCH_SIZE 个未使用的账号
    accounts = read_unused_accounts(BATCH_SIZE)

    if not accounts:
        logger.error("没有可用的账号，程序退出")
        sys.exit(1)

    logger.info(f"开始批量注册，共 {len(accounts)} 个账号")

    success_count = 0
    fail_count = 0

    for idx, (account_id, account, password, row_index) in enumerate(accounts, 1):
        logger.info(f"========== 进度: {idx}/{len(accounts)} ==========")
        ok = register_one(account_id, account, password, row_index)

        if ok:
            success_count += 1
            logger.info(f"[{account}] ✅ 注册成功")
        else:
            fail_count += 1
            logger.error(f"[{account}] ❌ 注册失败")

        # 账号间随机延迟（最后一个不需要）
        if idx < len(accounts):
            delay = random.uniform(10, 25)
            logger.info(f"等待 {delay:.1f} 秒后继续下一个...")
            time.sleep(delay)

    logger.info("========== 批量注册完成 ==========")
    logger.info(f"成功: {success_count}, 失败: {fail_count}, 总计: {len(accounts)}")
