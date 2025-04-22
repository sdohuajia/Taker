#!/bin/bash

# 脚本保存路径
SCRIPT_PATH="$HOME/taker24.sh"
TAKER_DIR="/root/Taker2"

# 检查是否以 root 用户运行脚本
if [ "$(id -u)" != "0" ]; then
    echo "此脚本需要以 root 用户权限运行。"
    echo "请尝试使用 'sudo -i' 命令切换到 root 用户，然后再次运行此脚本。"
    exit 1
fi

# 安装和配置 Taker 函数
function setup_Taker() {
    # 检查 Taker 目录是否存在，如果存在则删除
    if [ -d "Taker" ]; then
        echo "检测到 Taker 目录已存在，正在删除..."
        rm -rf Taker
        echo "Taker 目录已删除。"
    fi

    echo "正在从 GitHub 克隆 Taker 仓库..."
    git clone https://github.com/sdohuajia/Taker.git
    if [ ! -d "Taker" ]; then
        echo "克隆失败，请检查网络连接或仓库地址。"
        exit 1
    fi

    cd "Taker" || { echo "无法进入 Taker 目录"; exit 1; }

    # 检查 Node.js 是否安装并获取版本
    NODE_VERSION=$(node -v 2>/dev/null | cut -d'v' -f2 | cut -d'.' -f1 || echo "0")
    if [ "$NODE_VERSION" -lt 18 ]; then
        echo "当前 Node.js 版本 $(node -v 2>/dev/null || echo '未安装') 不满足要求，正在安装 Node.js 18..."
        
        # 清理旧的 Node.js 相关包和文件
        echo "清理旧的 Node.js 安装..."
        apt remove -y nodejs libnode-dev nodejs-doc npm > /dev/null 2>&1
        apt autoremove -y > /dev/null 2>&1
        rm -rf /usr/include/node /usr/lib/node_modules /usr/local/lib/node_modules /usr/local/bin/node /usr/local/bin/npm
        rm -f /usr/bin/node /usr/bin/npm /usr/share/doc/nodejs /usr/share/man/man1/node*
        
        # 修复可能的 dpkg 中断状态
        echo "修复 dpkg 状态..."
        apt update
        apt install -f -y
        
        # 安装 curl（如果未安装）
        apt install -y curl
        
        # 添加 NodeSource 仓库并安装 Node.js 18
        echo "安装 Node.js 18..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
        apt install -y nodejs
        
        # 验证安装
        NEW_NODE_VERSION=$(node -v 2>/dev/null | cut -d'v' -f2 | cut -d'.' -f1 || echo "0")
        if [ "$NEW_NODE_VERSION" -ge 18 ]; then
            echo "Node.js 18 已成功安装，版本：$(node -v)"
        else
            echo "错误：Node.js 安装失败，请手动安装（参考：https://deb.nodesource.com/setup_18.x）"
            exit 1
        fi
    else
        echo "Node.js 版本 $(node -v) 已满足要求，继续执行..."
    fi

    # 检查并安装 screen
    if ! command -v screen > /dev/null 2>&1; then
        echo "未检测到 screen，正在安装..."
        apt install -y screen
        if [ $? -eq 0 ]; then
            echo "screen 已成功安装"
        else
            echo "错误：screen 安装失败，请手动安装（sudo apt install screen）"
            exit 1
        fi
    else
        echo "screen 已安装，继续执行..."
    fi

    # 安装项目依赖
    echo "安装项目依赖..."
    npm install
    if [ \$? -ne 0 ]; then
        echo "错误：npm install 失败，请检查网络或包配置。"
        exit 1
    fi

    # 创建或清空 wallets.json 文件
    echo "[]" > wallets.json

    # 提示用户输入 Address（多行输入，Ctrl+D 结束）
    echo "请输入 Address（每行一个地址，输入完成后按 Ctrl+D 结束）："
    Address=""
    while IFS= read -r line; do
        Address="$Address$line\n"
    done
    Address=${Address%\\n}  # 移除末尾换行符

    # 提示用户输入 Private_Key（多行输入，Ctrl+D 结束）
    echo "请输入 Private_Key（每行一个私钥，输入完成后按 Ctrl+D 结束）："
    Private_Key=""
    while IFS= read -r line; do
        Private_Key="$Private_Key$line\n"
    done
    Private_Key=${Private_Key%\\n}  # 移除末尾换行符

    # 检查输入是否为空
    if [ -z "$Address" ] || [ -z "$Private_Key" ]; then
        echo "错误：Address 或 Private_Key 输入为空"
        exit 1
    fi

    # 将输入分割为数组
    IFS=$'\n' read -d '' -r -a address_array <<< "$Address" || true
    IFS=$'\n' read -d '' -r -a key_array <<< "$Private_Key" || true

    # 获取账户数量
    account_count=${#address_array[@]}

    # 验证账户数量
    if [ "$account_count" -eq 0 ]; then
        echo "错误：Address 输入为空或无有效账户"
        exit 1
    fi
    if [ "$account_count" -gt 1000 ]; then
        echo "错误：账户数量 ($account_count) 超过最大限制 1000"
        exit 1
    fi
    if [ ${#key_array[@]} -ne "$account_count" ]; then
        echo "错误：Address 和 Private_Key 的数量 (${#address_array[@]}, ${#key_array[@]}) 不匹配"
        exit 1
    fi

    # 使用临时数组收集账户信息
    wallets_json="[]"
    for ((i=0; i<account_count; i++)); do
        address="${address_array[i]}"
        private_key="${key_array[i]}"

        # 检查输入是否为空
        if [ -z "$address" ] || [ -z "$private_key" ]; then
            echo "错误：第 $((i+1)) 个账户的 Address 或 Private_Key 为空"
            exit 1
        fi

        # 将账户信息添加到临时 JSON
        wallets_json=$(jq --arg addr "$address" --arg pkey "$private_key" \
            '. += [{"address": $addr, "privateKey": $pkey}]' <<< "$wallets_json")
    done

    # 一次性写入 wallets.json
    echo "$wallets_json" > wallets.json
    if [ $? -ne 0 ]; then
        echo "写入 wallets.json 失败，请检查权限或磁盘空间。"
        exit 1
    fi

    echo "账户信息已保存到 wallets.json"
    echo "当前 wallets.json 内容如下:"
    cat wallets.json

    # 提示用户输入 PROXY
    echo "请输入 PROXY（每行一个代理，输入完成后按 Ctrl+D 结束；直接按 Ctrl+D 跳过）："
    PROXY=""
    while IFS= read -r line; do
        PROXY="$PROXY$line\n"
    done
    PROXY=${PROXY%\\n}  # 移除末尾换行符

    # 检查 PROXY 输入并生成 proxy.txt
    proxy_file="/root/Taker/proxy.txt"
    if [ -z "$PROXY" ]; then
        echo "警告：未输入 PROXY，将不使用代理。"
        > "$proxy_file"  # 创建空文件或清空现有文件
    else
        echo -e "$PROXY" > "$proxy_file"
        if [ $? -eq 0 ]; then
            echo "proxy.txt 已从输入的 PROXY 成功生成！"
        else
            echo "错误：生成 proxy.txt 失败，请检查 /root/Taker 目录的写入权限（尝试 chmod u+w /root/Taker 或以 sudo 运行）"
            exit 1
        fi
    fi

    echo "正在使用 screen 启动 npm start..."
    screen -S taker24 -dm  # 创建新的 screen 会话，名称为 taker24
    sleep 1  # 等待1秒钟确保会话已启动

    # 进入目录并启动脚本
    screen -S taker24 -X stuff "cd /root/Taker && npm start\n"
    echo "使用 'screen -r taker24' 命令来查看日志。"

    # 提示用户按任意键返回主菜单
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# 安装和配置 SowingTaker 函数
function setup_sowingTaker() {
    # 检查 Taker2 目录是否存在，如果存在则删除
    if [ -d "Taker2" ]; then
        echo "检测到 Taker2 目录已存在，正在删除..."
        rm -rf Taker2
        echo "Taker2 目录已删除。"
    fi

    echo "正在从 GitHub 克隆 Taker 仓库..."
    git clone https://github.com/sdohuajia/Taker2.git
    if [ ! -d "Taker2" ]; then
        echo "克隆失败，请检查网络连接或仓库地址。"
        exit 1
    fi

    cd "Taker2" || { echo "无法进入 Taker2 目录"; exit 1; }

    # 检查 Node.js 是否安装并获取版本
    NODE_VERSION=$(node -v 2>/dev/null | cut -d'v' -f2 | cut -d'.' -f1 || echo "0")
    if [ "$NODE_VERSION" -lt 18 ]; then
        echo "当前 Node.js 版本 $(node -v 2>/dev/null || echo '未安装') 不满足要求，正在安装 Node.js 18..."
        
        # 清理旧的 Node.js 相关包和文件
        echo "清理旧的 Node.js 安装..."
        apt remove -y nodejs libnode-dev nodejs-doc npm > /dev/null 2>&1
        apt autoremove -y > /dev/null 2>&1
        rm -rf /usr/include/node /usr/lib/node_modules /usr/local/lib/node_modules /usr/local/bin/node /usr/local/bin/npm
        rm -f /usr/bin/node /usr/bin/npm /usr/share/doc/nodejs /usr/share/man/man1/node*
        
        # 修复可能的 dpkg 中断状态
        echo "修复 dpkg 状态..."
        apt update
        apt install -f -y
        
        # 安装 curl（如果未安装）
        apt install -y curl
        
        # 添加 NodeSource 仓库并安装 Node.js 18
        echo "安装 Node.js 18..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
        apt install -y nodejs
        
        # 验证安装
        NEW_NODE_VERSION=$(node -v 2>/dev/null | cut -d'v' -f2 | cut -d'.' -f1 || echo "0")
        if [ "$NEW_NODE_VERSION" -ge 18 ]; then
            echo "Node.js 18 已成功安装，版本：$(node -v)"
        else
            echo "错误：Node.js 安装失败，请手动安装（参考：https://deb.nodesource.com/setup_18.x）"
            exit 1
        fi
    else
        echo "Node.js 版本 $(node -v) 已满足要求，继续执行..."
    fi

    # 检查并安装 screen
    if ! command -v screen > /dev/null 2>&1; then
        echo "未检测到 screen，正在安装..."
        apt install -y screen
        if [ $? -eq 0 ]; then
            echo "screen 已成功安装"
        else
            echo "错误：screen 安装失败，请手动安装（sudo apt install screen）"
            exit 1
        fi
    else
        echo "screen 已安装，继续执行..."
    fi

    # 定义输出文件路径
    KEYS_FILE="$TAKER_DIR/keys.txt"
    API_FILE="$TAKER_DIR/api.txt"
    REFER_FILE="$TAKER_DIR/refer.txt"

    # 提示用户输入 Private Keys（多行输入，Enter + Ctrl+D 结束，直接 Ctrl+D 跳过）
    echo "请输入 Private Keys（每行一个私钥，输入完成后按 Enter 再 Ctrl+D 结束，直接 Ctrl+D 跳过）："
    Private_Keys=""
    while IFS= read -r line; do
    # 忽略空行
    if [ -n "$line" ]; then
        Private_Keys="$Private_Keys$line\n"
    fi
    done
    Private_Keys=${Private_Keys%\\n}  # 移除末尾换行符

    # 保存 Private Keys 到 keys.txt
    if [ -z "$Private_Keys" ]; then
    echo "警告：未输入 Private Keys，将创建空的 keys.txt"
    > "$KEYS_FILE"
    else
    echo -e "$Private_Keys" > "$KEYS_FILE"
    if [ $? -ne 0 ]; then
        echo "错误：写入 keys.txt 失败，请检查 /root/Taker2 目录权限（尝试 chmod u+w /root/Taker2）"
        exit 1
    fi
    echo "Private Keys 已保存到 $KEYS_FILE"
    fi

    # 提示用户输入 API Key（单行输入）
    echo "请输入 Capsolver API Key（单行输入，按 Enter 确认，不能为空）："
    read -r API_Key
    if [ -z "$API_Key" ]; then
    echo "错误：API Key 不能为空"
    exit 1
    fi

    # 保存 API Key 到 api.txt
    echo "$API_Key" > "$API_FILE"
    if [ $? -ne 0 ]; then
    echo "错误：写入 api.txt 失败，请检查 /root/Taker2 目录权限（尝试 chmod u+w /root/Taker2）"
    exit 1
    fi
    echo "API Key 已保存到 $API_FILE"

    # 提示用户输入 Referral Code（单行输入，空输入使用默认值）
    echo "请输入 Referral Code（单行输入，按 Enter 确认，留空使用默认 MPR4HWEW）："
    read -r Referral_Code
    if [ -z "$Referral_Code" ]; then
    Referral_Code="MPR4HWEW"
    echo "警告：未输入 Referral Code，将使用默认值 MPR4HWEW"
    fi

    # 保存 Referral Code 到 refer.txt
    echo "$Referral_Code" > "$REFER_FILE"
    if [ $? -ne 0 ]; then
    echo "错误：写入 refer.txt 失败，请检查 /root/Taker2 目录权限（尝试 chmod u+w /root/Taker2）"
    exit 1
    fi
    echo "Referral Code 已保存到 $REFER_FILE"

    # 显示生成的文件内容
    echo "生成的文件内容如下："
    echo "---- keys.txt ----"
    cat "$KEYS_FILE"
    echo "---- api.txt ----"
    cat "$API_FILE"
    echo "---- refer.txt ----"
    cat "$REFER_FILE"
    echo "所有配置已成功保存到 $TAKER_DIR"

    # 提示用户输入 PROXY
    echo "请输入 PROXY（每行一个代理，输入完成后按 回车再Ctrl+D 结束；直接按 Ctrl+D 跳过）："
    PROXY=""
    while IFS= read -r line; do
        PROXY="$PROXY$line\n"
    done
    PROXY=${PROXY%\\n}  # 移除末尾换行符

    # 检查 PROXY 输入并生成 proxy.txt
    proxy_file="/root/Taker2/proxy.txt"
    if [ -z "$PROXY" ]; then
        echo "警告：未输入 PROXY，将不使用代理。"
        > "$proxy_file"  # 创建空文件或清空现有文件
    else
        echo -e "$PROXY" > "$proxy_file"
        if [ $? -eq 0 ]; then
            echo "proxy.txt 已从输入的 PROXY 成功生成！"
        else
            echo "错误：生成 proxy.txt 失败，请检查 /root/Taker2 目录的写入权限（尝试 chmod u+w /root/Taker2 或以 sudo 运行）"
            exit 1
        fi
    fi

    echo "正在使用 screen 启动 npm start..."
    screen -S sowingtaker -dm  # 创建新的 screen 会话，名称为 sowingtaker
    sleep 1  # 等待1秒钟确保会话已启动

    # 进入目录并启动脚本
    screen -S sowingtaker -X stuff "cd /root/Taker2 && npm start\n"
    echo "使用 'screen -r sowingtaker' 命令来查看日志。"

    # 提示用户按任意键返回主菜单
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# 主菜单函数
function main_menu() {
    while true; do
        clear
        echo "脚本由大赌社区哈哈哈哈编写，推特 @ferdie_jhovie，免费开源，请勿相信收费"
        echo "如有问题，可联系推特，仅此只有一个号"
        echo "================================================================"
        echo "退出脚本，请按键盘 ctrl + C 退出即可"
        echo "请选择要执行的操作:"
        echo "1. 安装 Taker 24小时挖矿"
        echo "2. 安装 SowingTaker 3小时挖矿"
        echo "3. 退出"

        read -p "请输入您的选择 (1,2,3): " choice
        case $choice in
            1)
                setup_Taker  # 调用安装和配置函数
                ;; 
            2)
                setup_sowingTaker  # 调用安装和配置函数
                ;; 
            3)
                echo "退出脚本..."
                exit 0
                ;;
            *)
                echo "无效的选择，请重试."
                read -n 1 -s -r -p "按任意键继续..."
                ;;
        esac
    done
}

# 进入主菜单
main_menu
