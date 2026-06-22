import random
import csv
import os
import sys

# ====================== 配置区（可修改） ======================
GENERATE_NUM = 100  # 每次运行生成100条
CSV_FILE_NAME = "accounts_passwords.csv"  # 文件名改为英文

# 严格按照规范：4-5位中性短单词，分三类，无生僻词
WORD_POOL = {
    "weather": ["rain", "wind", "snow", "cloud", "sun", "fog", "hail", "storm", "dusk", "dawn", "mist", "breeze"],
    "nature": ["hill", "lake", "river", "rock", "tree", "leaf", "grass", "sand", "wave", "stone", "peak", "valley"],
    "objects": ["book", "pen", "cup", "desk", "chair", "lamp", "clock", "box", "key", "door", "wall", "floor"]
}
# 所有单词合并成列表用于随机选择
ALL_WORDS = [word for category in WORD_POOL.values() for word in category]

# 违禁账号黑名单
FORBIDDEN_ACCOUNTS = {"admin", "test", "guest", "root", "user", "system", "admin123", "test123"}

# 密码允许的符号（仅键盘主区易输入）
ALLOWED_SYMBOLS = "!@#$%*"
LOWER = "abcdefghijklmnopqrstuvwxyz"
UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
DIGITS = "0123456789"
# ==========================================================

# 获取程序所在目录（exe/脚本同级）
def get_program_dir():
    if hasattr(sys, '_MEIPASS'):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))

PROGRAM_FOLDER = get_program_dir()
FULL_CSV_PATH = os.path.join(PROGRAM_FOLDER, CSV_FILE_NAME)

# 读取历史数据：获取已用账号、已用密码、最大编号
def load_history():
    used_accounts = set()
    used_passwords = set()
    max_id = 0
    if os.path.exists(FULL_CSV_PATH):
        with open(FULL_CSV_PATH, "r", encoding="utf-8-sig") as f:
            reader = csv.reader(f)
            next(reader, None)  # 跳过表头
            for row in reader:
                if len(row) >= 3:  # 兼容旧版文件
                    try:
                        curr_id = int(row[0])
                        if curr_id > max_id:
                            max_id = curr_id
                        used_accounts.add(row[1])
                        if len(row) >= 3:
                            used_passwords.add(row[2])
                    except Exception:
                        continue
    return used_accounts, used_passwords, max_id

# 检查是否有连续3个及以上相同字符
def has_consecutive_chars(s, count=3):
    for i in range(len(s) - count + 1):
        if all(c == s[i] for c in s[i:i+count]):
            return True
    return False

# 生成符合规范的唯一账号
def generate_unique_account(used_accs):
    while True:
        # 严格结构：单词A(4-5位) + 1位数字 + 单词B(4-5位)
        word_a = random.choice(ALL_WORDS)
        word_b = random.choice(ALL_WORDS)
        digit = random.choice(DIGITS)
        account = word_a + digit + word_b
        
        # 校验1：总长度9-11位（4+1+4=9，5+1+5=11，自动满足）
        # 校验2：无连续3个相同字符
        if has_consecutive_chars(account):
            continue
        # 校验3：不在违禁名单
        if account in FORBIDDEN_ACCOUNTS:
            continue
        # 校验4：未被使用过
        if account not in used_accs:
            return account

# 生成符合规范的唯一密码
def generate_unique_password(used_pwds):
    while True:
        # 1. 前两位固定为大写字母
        part1 = random.choice(UPPER) + random.choice(UPPER)
        
        # 2. 中间6位：4个小写字母 + 2个数字（集中排布）
        part2 = ''.join(random.choices(LOWER, k=4)) + ''.join(random.choices(DIGITS, k=2))
        
        # 3. 第9位：1个允许的符号（不在首尾）
        symbol = random.choice(ALLOWED_SYMBOLS)
        
        # 4. 最后3位：小写字母
        part3 = ''.join(random.choices(LOWER, k=3))
        
        # 拼接完整12位密码
        password = part1 + part2 + symbol + part3
        
        # 校验1：无连续3个相同字符
        if has_consecutive_chars(password):
            continue
        # 校验2：未被使用过
        if password not in used_pwds:
            return password

def main():
    used_accs, used_pwds, max_id = load_history()
    new_rows = []
    
    print(f"Program directory: {PROGRAM_FOLDER}")
    print(f"Output file path: {FULL_CSV_PATH}")
    print(f"Existing records: {max_id}, this run will generate {GENERATE_NUM} records starting from {max_id+1}")
    print("Generating... Please wait...\n")

    for i in range(GENERATE_NUM):
        current_id = max_id + 1 + i
        # 第一层+第二层查重：生成时自动比对历史数据
        account = generate_unique_account(used_accs)
        password = generate_unique_password(used_pwds)
        
        # 第三层查重：入库前最终复核
        if account in used_accs or password in used_pwds:
            i -= 1
            continue
        
        used_accs.add(account)
        used_pwds.add(password)
        # 第四列：0=未使用，1=已使用，新生成默认0
        new_rows.append([current_id, account, password, 0])

    # 写入CSV文件
    file_exists = os.path.exists(FULL_CSV_PATH)
    with open(FULL_CSV_PATH, "a", newline="", encoding="utf-8-sig") as f:
        writer = csv.writer(f)
        if not file_exists:
            # 表头全部改为英文
            writer.writerow(["id", "account", "password", "y/n"])
        writer.writerows(new_rows)

    print(f"✅ Generation completed! Successfully added {GENERATE_NUM} records")
    print(f"📁 File location: {FULL_CSV_PATH}")
    print(f"📝 Status: 0=unused, 1=used")
    input("\nPress Enter to close the window")

if __name__ == "__main__":
    main()