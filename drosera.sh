#!/bin/bash

# 确保 PATH 包含 Drosera 和其他工具
export PATH=$PATH:/root/.drosera/bin:/root/.bun/bin:/root/.foundry/bin

# 脚本保存路径
SCRIPT_PATH="$HOME/Drosera.sh"

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 权限运行此脚本 (sudo)"
    exit 1
fi

# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive

# 函数：验证 YAML 语法
validate_yaml() {
    local file=$1
    if command -v docker-compose &> /dev/null; then
        docker-compose -f "$file" config > /dev/null 2>&1 || { echo "文件 $file 的 YAML 语法错误"; return 1; }
    elif docker compose version &> /dev/null; then
        docker compose -f "$file" config > /dev/null 2>&1 || { echo "文件 $file 的 YAML 语法错误"; return 1; }
    else
        echo "错误：未找到 docker-compose 或 docker compose 命令"
        exit 1
    fi
    echo "文件 $file 的 YAML 语法验证通过"
}

# 函数：获取 EVM 钱包地址
get_evm_address() {
    local private_key=$1
    local address=$(cast wallet address --private-key "$private_key" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "$address"
        return 0
    else
        echo "错误：无法从私钥获取地址"
        return 1
    fi
}

# 函数：验证 EVM 地址格式
validate_evm_address() {
    local address=$1
    if [[ "$address" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        return 0
    else
        return 1
    fi
}

# 函数：安全输入私钥
get_private_key() {
    local prompt=$1
    local private_key
    while true; do
        echo -n "$prompt"
        read -s private_key
        echo
        if [ -z "$private_key" ]; then
            echo "错误：私钥不能为空，请重新输入"
            continue
        fi
        # 验证私钥格式（64个十六进制字符）
        if [[ ! "$private_key" =~ ^[0-9a-fA-F]{64}$ ]]; then
            echo "错误：私钥格式不正确，应为64个十六进制字符"
            continue
        fi
        break
    done
    echo "$private_key"
}

# 函数：显示进度条
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    local remaining=$((width - completed))
    
    printf "\r["
    printf "%${completed}s" | tr " " "="
    printf "%${remaining}s" | tr " " " "
    printf "] %d%%" $percentage
}

# 函数：检查网络连接
check_network() {
    echo "正在检查网络连接..."
    if ping -c 1 -W 5 api.ipify.org > /dev/null 2>&1; then
        echo "网络连接正常"
        return 0
    else
        echo "错误：网络连接异常，请检查网络设置"
        return 1
    fi
}

# 函数：检查系统要求
check_system_requirements() {
    echo "正在检查系统要求..."
    
    # 检查内存
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$total_mem" -lt 2048 ]; then
        echo "警告：系统内存小于 2GB，可能会影响性能"
    fi
    
    # 检查磁盘空间
    local free_space=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$free_space" -lt 10240 ]; then
        echo "警告：可用磁盘空间小于 10GB，建议清理空间"
    fi
    
    # 检查 CPU 核心数
    local cpu_cores=$(nproc)
    if [ "$cpu_cores" -lt 2 ]; then
        echo "警告：CPU 核心数小于 2，可能会影响性能"
    fi
    
    echo "系统检查完成"
}

# 函数：清理临时文件
cleanup() {
    echo "正在清理临时文件..."
    rm -f /tmp/drosera_*.tmp
    echo "清理完成"
}

# 设置退出时清理
trap cleanup EXIT

# 检查系统要求
check_system_requirements

# 检查网络连接
check_network || { echo "按任意键退出..."; read -r; exit 1; }

# 命令1：安装 Drosera 节点
function install_drosera_node() {
    echo "开始安装 Drosera 节点..."
    
    # 更新系统包并安装依赖
    echo "正在更新系统包并安装依赖..."
    apt-get update && apt-get upgrade -y -o Dpkg::Options::="--force-confold" || { echo "系统包更新失败"; exit 1; }
    apt-get install -y curl ufw iptables build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip -o Dpkg::Options::="--force-confold" || { echo "依赖安装失败"; exit 1; }
    echo "依赖安装完成"

    # 检查并安装 jq
    if ! command -v jq &> /dev/null; then
        echo "jq 未安装，正在安装..."
        apt-get install -y jq -o Dpkg::Options::="--force-confold" || { echo "jq 安装失败"; exit 1; }
        echo "jq 安装完成"
    else
        echo "jq 已安装，检查更新..."
        apt-get install -y jq -o Dpkg::Options::="--force-confold"
    fi

    # 检查并安装 Docker
    if ! command -v docker &> /dev/null; then
        echo "Docker 未安装，正在安装..."
        apt-get install -y apt-transport-https ca-certificates curl software-properties-common -o Dpkg::Options::="--force-confold"
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io -o Dpkg::Options::="--force-confold" || { echo "Docker 安装失败"; exit 1; }
        echo "Docker 安装完成"
    else
        echo "Docker 已安装，检查更新..."
        apt-get install -y docker-ce docker-ce-cli containerd.io -o Dpkg::Options::="--force-confold"
    fi

    # 启动并启用 Docker 服务
    systemctl start docker || { echo "Docker 服务启动失败"; exit 1; }
    systemctl enable docker || { echo "Docker 服务启用失败"; exit 1; }

    # 检查并安装 Docker Compose
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        echo "Docker Compose 未安装，正在安装最新版本..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        docker-compose --version &> /dev/null || { echo "Docker Compose 安装失败"; exit 1; }
        echo "Docker Compose 安装完成"
    else
        echo "Docker Compose 已安装，检查更新..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi

    # 安装 Bun
    echo "正在安装 Bun..."
    if ! command -v unzip &> /dev/null; then
        apt-get install -y unzip -o Dpkg::Options::="--force-confold" || { echo "unzip 安装失败"; exit 1; }
        echo "unzip 安装完成"
    fi
    curl -fsSL https://bun.sh/install | bash || { echo "Bun 安装失败"; exit 1; }
    if [ -f "/root/.bun/bin/bun" ]; then
        echo "Bun 安装完成"
        export PATH=$PATH:/root/.bun/bin
        echo 'export PATH=$PATH:/root/.bun/bin' >> /root/.bashrc
    else
        echo "Bun 安装失败，请检查网络或 https://bun.sh/install"
        exit 1
    fi

    # 安装 Foundry
    echo "正在安装 Foundry..."
    curl -L https://foundry.paradigm.xyz | bash || { echo "Foundry 安装失败"; exit 1; }
    if [ -f "/root/.foundry/bin/foundryup" ]; then
        /root/.foundry/bin/foundryup
        export PATH=$PATH:/root/.foundry/bin
        echo 'export PATH=$PATH:/root/.foundry/bin' >> /root/.bashrc
        forge --version || { echo "forge 未安装"; exit 1; }
        echo "Foundry 安装完成"
    else
        echo "Foundry 安装失败，请检查网络或 https://foundry.paradigm.xyz"
        exit 1
    fi

    # 安装 Drosera
    echo "正在安装 Drosera..."
    curl -L https://app.drosera.io/install | bash || { echo "Drosera 安装失败"; exit 1; }
    source /root/.bashrc
    export PATH=$PATH:/root/.drosera/bin
    echo 'export PATH=$PATH:/root/.drosera/bin' >> /root/.bashrc
    if command -v droseraup &> /dev/null; then
        droseraup || { echo "droseraup 执行失败"; exit 1; }
        echo "Drosera 安装完成"
    else
        echo "droseraup 命令未找到，Drosera 安装失败"
        exit 1
    fi

    # 检查 Drosera 二进制文件并验证版本
    DROsera_BIN="/root/.drosera/bin/drosera"
    if [ -f "$DROsera_BIN" ]; then
        echo "找到 Drosera，正在验证版本..."
        $DROsera_BIN --version || { echo "Drosera 版本检查失败"; exit 1; }
        echo "Drosera 版本检查成功"
    else
        echo "Drosera 未找到（$DROsera_BIN 不存在）"
        exit 1
    fi

    # 创建 my-drosera-trap 目录并切换
    echo "创建 my-drosera-trap 目录并切换..."
    mkdir -p /root/my-drosera-trap && cd /root/my-drosera-trap || { echo "目录创建或切换失败"; exit 1; }

    # 配置 Git 用户信息
    echo "配置 Git 用户信息..."
    git config --global user.email "user@example.com" || { echo "Git 配置失败"; exit 1; }
    git config --global user.name "DroseraUser" || { echo "Git 配置失败"; exit 1; }

    # 初始化 Foundry 模板
    echo "初始化 Foundry 模板..."
    forge init -t drosera-network/trap-foundry-template || { echo "Foundry 模板初始化失败"; exit 1; }
    echo "Foundry 模板初始化完成"

    # 执行 bun install
    echo "执行 bun install..."
    bun install || { echo "bun install 失败"; exit 1; }
    echo "bun install 完成"

    # 执行 forge build
    echo "执行 forge build..."
    forge build || { echo "forge build 失败"; exit 1; }
    echo "forge build 完成"

    # 获取私钥
    echo "请输入你的 EVM 钱包私钥（用于 drosera apply）："
    DROSERA_PRIVATE_KEY=$(get_private_key "请输入 EVM 钱包私钥（隐藏输入）：")
    EVM_ADDRESS=$(get_evm_address "$DROSERA_PRIVATE_KEY")
    
    if [ $? -eq 0 ]; then
        echo "你的 EVM 钱包地址: $EVM_ADDRESS"
    else
        echo "错误：无法获取 EVM 地址"
        exit 1
    fi

    # 执行第一次 drosera apply
    echo "正在执行第一次 drosera apply..."
    export DROSERA_PRIVATE_KEY="$DROSERA_PRIVATE_KEY"
    if echo "ofc" | drosera apply; then
        echo "第一次 drosera apply 完成"
    else
        echo "第一次 drosera apply 失败，请检查错误信息"
        exit 1
    fi

    # 询问用户是否继续进行下一步
    echo "所有操作已完成，是否继续进行下一步（drosera dryrun、第二次 drosera apply、Drosera Operator 安装和注册、配置 Drosera-Network 仓库、启动 Docker Compose 服务）？（y/n）"
    read -r CONTINUE
    if [ "$CONTINUE" = "y" ] || [ "$CONTINUE" = "Y" ]; then
        # 执行 drosera dryrun
        echo "正在执行 drosera dryrun..."
        if echo "ofc" | drosera dryrun; then
            echo "drosera dryrun 完成"
        else
            echo "drosera dryrun 失败，请检查错误信息"
            exit 1
        fi

        # 执行第二次 drosera apply
        echo "正在执行第二次 drosera apply..."
        if echo "ofc" | drosera apply; then
            echo "第二次 drosera apply 完成"
        else
            echo "第二次 drosera apply 失败，请检查错误信息"
            exit 1
        fi

        # 安装 Drosera Operator
        echo "正在安装 Drosera Operator..."
        cd /root || { echo "切换到 /root 目录失败"; exit 1; }
        git clone https://github.com/drosera-network/drosera-operator.git || { echo "克隆 Drosera Operator 仓库失败"; exit 1; }
        cd drosera-operator || { echo "切换到 drosera-operator 目录失败"; exit 1; }
        bun install || { echo "bun install 失败"; exit 1; }
        echo "Drosera Operator 安装完成"

        # 注册 Drosera Operator
        echo "正在注册 Drosera Operator..."
        if bun run register; then
            echo "Drosera Operator 注册完成"
        else
            echo "Drosera Operator 注册失败，请检查错误信息"
            exit 1
        fi

        # 配置 Drosera-Network 仓库
        echo "正在配置 Drosera-Network 仓库..."
        cd /root || { echo "切换到 /root 目录失败"; exit 1; }
        git clone https://github.com/drosera-network/drosera-network.git || { echo "克隆 Drosera-Network 仓库失败"; exit 1; }
        cd drosera-network || { echo "切换到 drosera-network 目录失败"; exit 1; }
        echo "Drosera-Network 仓库配置完成"

        # 启动 Docker Compose 服务
        echo "正在启动 Docker Compose 服务..."
        if command -v docker-compose &> /dev/null; then
            echo "使用 docker-compose 启动服务..."
            docker-compose -f docker-compose.yaml up -d || { echo "Docker Compose 服务启动失败"; exit 1; }
            echo "正在收集 Docker Compose 日志..."
            docker-compose -f docker-compose.yaml logs --no-color > drosera.log 2>&1 || { echo "无法收集 Docker Compose 日志"; exit 1; }
            echo "Docker Compose 日志已保存到 $PWD/drosera.log"
        elif docker compose version &> /dev/null; then
            echo "使用 docker compose 启动服务..."
            docker compose -f docker-compose.yaml up -d || { echo "Docker Compose 服务启动失败"; exit 1; }
            echo "正在收集 Docker Compose 日志..."
            docker compose -f docker-compose.yaml logs --no-color > drosera.log 2>&1 || { echo "无法收集 Docker Compose 日志"; exit 1; }
            echo "Docker Compose 日志已保存到 $PWD/drosera.log"
        else
            echo "错误：未找到 docker-compose 或 docker compose 命令"
            exit 1
        fi
        echo "Docker Compose 服务启动完成"

        echo "所有后续步骤已完成！"
        echo "你可以使用以下命令查看服务状态："
        echo "1. 查看 drosera-node 日志：docker logs -f drosera-node"
        echo "2. 查看 Docker Compose 日志：cat $PWD/drosera.log"
        echo "3. 重启服务：cd /root/drosera-network && docker-compose restart"
    else
        echo "用户选择退出，安装 Drosera 节点结束。"
        unset DROSERA_PRIVATE_KEY
        return
    fi

    # 清理私钥变量
    unset DROSERA_PRIVATE_KEY
    echo "私钥变量已清理"
    echo "按任意键返回主菜单..."
    read -r
}

# 命令2：查看日志
function view_logs() {
    echo "正在检查 drosera-node 容器..."
    if docker ps -a --format '{{.Names}}' | grep -q "^drosera-node$"; then
        echo "正在查看 drosera-node 日志..."
        docker logs -f drosera-node
    else
        echo "错误：drosera-node 容器不存在，请先运行安装流程"
    fi
    echo "日志查看结束，按任意键返回主菜单..."
    read -r
}

# 命令3：重启 Operators
function restart_operators() {
    echo "正在重启 Operators..."
    cd ~/Drosera-Network || { echo "切换到 Drosera-Network 目录失败"; exit 1; }
    if [ ! -f "docker-compose.yaml" ]; then
        echo "错误：未找到 docker-compose.yaml 文件，请确保 Drosera-Network 目录正确"
        exit 1
    fi
    if command -v docker-compose &> /dev/null; then
        echo "使用 docker-compose 停止服务..."
        docker-compose -f docker-compose.yaml down || { echo "Docker Compose 服务停止失败"; exit 1; }
        echo "使用 docker-compose 启动服务..."
        docker-compose -f docker-compose.yaml up -d || { echo "Docker Compose 服务启动失败"; exit 1; }
        echo "正在收集 Docker Compose 日志..."
        docker-compose -f docker-compose.yaml logs --no-color > drosera.log 2>&1 || { echo "无法收集 Docker Compose 日志"; exit 1; }
        echo "Docker Compose 日志已保存到 $PWD/drosera.log"
    elif docker compose version &> /dev/null; then
        echo "使用 docker compose 停止服务..."
        docker compose -f docker-compose.yaml down || { echo "Docker Compose 服务停止失败"; exit 1; }
        echo "使用 docker compose 启动服务..."
        docker compose -f docker-compose.yaml up -d || { echo "Docker Compose 服务启动失败"; exit 1; }
        echo "正在收集 Docker Compose 日志..."
        docker compose -f docker-compose.yaml logs --no-color > drosera.log 2>&1 || { echo "无法收集 Docker Compose 日志"; exit 1; }
        echo "Docker Compose 日志已保存到 $PWD/drosera.log"
    else
        echo "错误：未找到 docker-compose 或 docker compose 命令"
        exit 1
    fi
    echo "Operators 重启完成"
    echo "按任意键返回主菜单..."
    read -r
}

# 命令4：升级到1.17并修改 drosera_rpc
function upgrade_to_1_17() {
    # 安装 Drosera
    echo "正在安装 Drosera..."
    curl -L https://app.drosera.io/install | bash || { echo "Drosera 安装失败"; exit 1; }
    source /root/.bashrc
    export PATH=$PATH:/root/.drosera/bin
    echo 'export PATH=$PATH:/root/.drosera/bin' >> /root/.bashrc
    if command -v droseraup &> /dev/null; then
        droseraup || { echo "droseraup 执行失败"; exit 1; }
        echo "Drosera 安装完成"
    else
        echo "droseraup 命令未找到，Drosera 安装失败"
        exit 1
    fi

    # 检查 Drosera 二进制文件并验证版本
    DROsera_BIN="/root/.drosera/bin/drosera"
    if [ -f "$DROsera_BIN" ]; then
        echo "找到 Drosera，正在验证版本..."
        $DROsera_BIN --version || { echo "Drosera 版本检查失败"; exit 1; }
        echo "Drosera 版本检查成功"
    else
        echo "Drosera 未找到（$DROsera_BIN 不存在）"
        exit 1
    fi

    # 切换到 my-drosera-trap 目录
    echo "切换到 /root/my-drosera-trap 目录..."
    cd /root/my-drosera-trap || { echo "错误：无法切换到 /root/my-drosera-trap 目录，请确保目录存在"; exit 1; }

    # 检查 drosera.toml 文件
    DROsera_TOML="/root/my-drosera-trap/drosera.toml"
    if [ ! -f "$DROsera_TOML" ]; then
        echo "错误：未找到 drosera.toml 文件 ($DROsera_TOML)。请确保 Drosera 安装正确并生成了配置文件。"
        exit 1
    fi

    # 修改 drosera.toml 中的 drosera_rpc
    DROsera_RPC="https://relay.testnet.drosera.io"
    echo "正在更新 drosera.toml 中的 drosera_rpc 配置..."
    if grep -q "^drosera_rpc = " "$DROsera_TOML"; then
        sed -i "s|^drosera_rpc = .*|drosera_rpc = \"$DROsera_RPC\"|" "$DROsera_TOML"
        echo "已更新 drosera_rpc 为 $DROsera_RPC"
    else
        echo "drosera_rpc = \"$DROsera_RPC\"" >> "$DROsera_TOML"
        echo "已添加 drosera_rpc = $DROsera_RPC 到 drosera.toml"
    fi

    # 验证 drosera.toml 是否正确更新
    if grep -q "drosera_rpc = \"$DROsera_RPC\"" "$DROsera_TOML"; then
        echo "drosera.toml 配置验证通过"
    else
        echo "错误：drosera.toml 中的 drosera_rpc 配置更新失败"
        exit 1
    fi

    # 获取私钥
    echo "请输入你的 EVM 钱包私钥（用于 drosera apply）："
    DROSERA_PRIVATE_KEY=$(get_private_key "请输入 EVM 钱包私钥（隐藏输入）：")
    EVM_ADDRESS=$(get_evm_address "$DROSERA_PRIVATE_KEY")
    
    if [ $? -eq 0 ]; then
        echo "你的 EVM 钱包地址: $EVM_ADDRESS"
    else
        echo "错误：无法获取 EVM 地址"
        exit 1
    fi

    # 执行 drosera apply
    echo "正在执行 drosera apply..."
    echo "等待 20 秒以确保准备就绪..."
    sleep 20
    export DROSERA_PRIVATE_KEY="$DROSERA_PRIVATE_KEY"
    if echo "ofc" | drosera apply; then
        echo "drosera apply 完成"
    else
        echo "drosera apply 失败，请手动运行 'cd /root/my-drosera-trap && export DROSERA_PRIVATE_KEY=your_private_key && echo \"ofc\" | drosera apply' 并检查错误日志。"
        unset DROSERA_PRIVATE_KEY
        exit 1
    fi

    # 清理私钥变量
    unset DROSERA_PRIVATE_KEY
    echo "私钥变量已清理"

    echo "升级到1.17及 drosera apply 执行完成"
    echo "按任意键返回主菜单..."
    read -r
}

# 命令5：获取Cadet角色
function claim_cadet_role() {
    echo "正在准备获取 Drosera Cadet 角色..."

    # 提示用户输入 EVM 钱包地址
    while true; do
        echo "请输入你的 EVM 钱包地址（用于验证 Responder 状态，例如：0x123...）："
        read -r OWNER_ADDRESS
        if [ -z "$OWNER_ADDRESS" ]; then
            echo "错误：EVM 钱包地址不能为空，请重新输入"
        elif [[ ! "$OWNER_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
            echo "错误：请输入有效的 EVM 钱包地址（以 0x 开头，42 个字符）"
        else
            break
        fi
    done

    # 执行 cast call 验证 Responder 状态
    echo "正在验证 Responder 状态..."
    CAST_CALL_RESULT=$(cast call 0x4608Afa7f277C8E0BE232232265850d1cDeB600E "isResponder(address)(bool)" "$OWNER_ADDRESS" --rpc-url https://ethereum-holesky-rpc.publicnode.com 2>/dev/null)
    if [ $? -eq 0 ] && [ "$CAST_CALL_RESULT" = "true" ]; then
        echo "验证成功：EVM 钱包地址 $OWNER_ADDRESS 是 Responder"
    else
        echo "验证失败：EVM 钱包地址 $OWNER_ADDRESS 不是 Responder 或 cast call 出错。请检查地址是否正确，或稍后重试。"
        echo "你可手动运行以下命令验证："
        echo "cast call 0x4608Afa7f277C8E0BE232232265850d1cDeB600E \"isResponder(address)(bool)\" $OWNER_ADDRESS --rpc-url https://ethereum-holesky-rpc.publicnode.com"
        echo "继续执行后续步骤，但请在 Discord 验证前确认 Responder 状态。"
    fi

    # 切换到 my-drosera-trap 目录
    echo "切换到 /root/my-drosera-trap 目录..."
    cd /root/my-drosera-trap || { echo "错误：无法切换到 /root/my-drosera-trap 目录，请确保目录存在（运行选项1安装Drosera节点）"; echo "按任意键返回主菜单..."; read -r; return; }

    # 验证 src 目录存在
    if [ ! -d "src" ]; then
        echo "错误：src 目录不存在，请确保 Drosera 节点已正确安装（运行选项1）"
        echo "按任意键返回主菜单..."
        read -r
        return
    fi

    # 提示用户输入 Discord 用户名
    while true; do
        echo "请输入你的 Discord 用户名（例如：user#1234，区分大小写，无前后空格）："
        read -r DISCORD_USERNAME
        if [ -z "$DISCORD_USERNAME" ]; then
            echo "错误：Discord 用户名不能为空，请重新输入"
        else
            break
        fi
    done

    # 定义 Trap.sol 文件内容
    TRAP_SOL_CONTENT=$(cat << EOF
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITrap} from "drosera-contracts/interfaces/ITrap.sol";

interface IMockResponse {
    function isActive() external view returns (bool);
}

contract Trap is ITrap {
    address public constant RESPONSE_CONTRACT = 0x4608Afa7f277C8E0BE232232265850d1cDeB600E;
    string constant discordName = "$DISCORD_USERNAME"; // add your discord name here

    function collect() external view returns (bytes memory) {
        bool active = IMockResponse(RESPONSE_CONTRACT).isActive();
        return abi.encode(active, discordName);
    }

    function shouldRespond(bytes[] calldata data) external pure returns (bool, bytes memory) {
        // take the latest block data from collect
        (bool active, string memory name) = abi.decode(data[0], (bool, string));
        // will not run if the contract is not active or the discord name is not set
        if (!active || bytes(name).length == 0) {
            return (false, bytes(""));
        }

        return (true, abi.encode(name));
    }
}
EOF
)

    # 创建或更新 src/Trap.sol 文件
    echo "正在创建/更新 src/Trap.sol 文件..."
    echo "$TRAP_SOL_CONTENT" > src/Trap.sol || { echo "错误：无法写入 src/Trap.sol 文件"; exit 1; }

    # 验证 Trap.sol 是否正确生成
    if [ -f "src/Trap.sol" ] && grep -q "string constant discordName = \"$DISCORD_USERNAME\";" src/Trap.sol; then
        echo "src/Trap.sol 文件创建成功，Discord 用户名已设置为 $DISCORD_USERNAME"
    else
        echo "错误：src/Trap.sol 文件创建失败或 Discord 用户名未正确设置"
        exit 1
    fi

    # 修改 drosera.toml 文件
    echo "正在修改 drosera.toml 文件..."
    DROsera_TOML="drosera.toml"
    if [ ! -f "$DROsera_TOML" ]; then
        echo "错误：未找到 drosera.toml 文件 ($DROsera_TOML)。请确保 Drosera 节点已正确安装（运行选项1）"
        exit 1
    fi

    # 备份 drosera.toml
    cp "$DROsera_TOML" "${DROsera_TOML}.bak" || { echo "错误：无法备份 drosera.toml 文件"; exit 1; }
    echo "已备份 drosera.toml 到 ${DROsera_TOML}.bak"

    # 更新或添加指定的配置项
    # 更新 path
    if grep -q "^path = " "$DROsera_TOML"; then
        sed -i 's|^path = .*|path = "out/Trap.sol/Trap.json"|' "$DROsera_TOML" || { echo "错误：无法更新 drosera.toml 的 path"; exit 1; }
    else
        echo 'path = "out/Trap.sol/Trap.json"' >> "$DROsera_TOML" || { echo "错误：无法添加 drosera.toml 的 path"; exit 1; }
    fi

    # 更新 response_contract
    if grep -q "^response_contract = " "$DROsera_TOML"; then
        sed -i 's|^response_contract = .*|response_contract = "0x4608Afa7f277C8E0BE232232265850d1cDeB600E"|' "$DROsera_TOML" || { echo "错误：无法更新 drosera.toml 的 response_contract"; exit 1; }
    else
        echo 'response_contract = "0x4608Afa7f277C8E0BE232232265850d1cDeB600E"' >> "$DROsera_TOML" || { echo "错误：无法添加 drosera.toml 的 response_contract"; exit 1; }
    fi

    # 更新 response_function
    if grep -q "^response_function = " "$DROsera_TOML"; then
        sed -i 's|^response_function = .*|response_function = "respondWithDiscordName(string)"|' "$DROsera_TOML" || { echo "错误：无法更新 drosera.toml 的 response_function"; exit 1; }
    else
        echo 'response_function = "respondWithDiscordName(string)"' >> "$DROsera_TOML" || { echo "错误：无法添加 drosera.toml 的 response_function"; exit 1; }
    fi

    # 验证 drosera.toml 是否正确更新
    if [ -f "$DROsera_TOML" ] && \
       grep -q 'path = "out/Trap.sol/Trap.json"' "$DROsera_TOML" && \
       grep -q 'response_contract = "0x4608Afa7f277C8E0BE232232265850d1cDeB600E"' "$DROsera_TOML" && \
       grep -q 'response_function = "respondWithDiscordName(string)"' "$DROsera_TOML"; then
        echo "drosera.toml 文件更新成功"
    else
        echo "错误：drosera.toml 文件更新失败或内容未正确设置"
        exit 1
    fi

    # 执行 forge build
    echo "执行 forge build..."
    forge build || { echo "forge build 失败，请确保 Foundry 已安装（运行选项1）"; exit 1; }
    echo "forge build 完成"

    # 获取私钥
    echo "请输入你的 EVM 钱包私钥（用于 drosera apply）："
    DROSERA_PRIVATE_KEY=$(get_private_key "请输入 EVM 钱包私钥（隐藏输入，用于 drosera apply）：")
    EVM_ADDRESS=$(get_evm_address "$DROSERA_PRIVATE_KEY")
    
    if [ $? -eq 0 ]; then
        echo "你的 EVM 钱包地址: $EVM_ADDRESS"
    else
        echo "错误：无法获取 EVM 地址"
        exit 1
    fi

    # 执行 drosera apply
    echo "正在执行 drosera apply..."
    export DROSERA_PRIVATE_KEY="$DROSERA_PRIVATE_KEY"
    if echo "ofc" | drosera apply; then
        echo "drosera apply 完成"
    else
        echo "drosera apply 失败，请手动运行 'cd /root/my-drosera-trap && export DROSERA_PRIVATE_KEY=your_private_key && echo \"ofc\" | drosera apply' 并检查错误日志。"
        unset DROSERA_PRIVATE_KEY
        echo "按任意键返回主菜单..."
        read -r
        return
    fi

    # 提示用户输入 EVM 钱包地址
    while true; do
        echo "请输入你的 EVM 钱包地址（用于验证 Responder 状态，例如：0x123...）："
        read -r OWNER_ADDRESS
        if [ -z "$OWNER_ADDRESS" ]; then
            echo "错误：EVM 钱包地址不能为空，请重新输入"
        elif [[ ! "$OWNER_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
            echo "错误：请输入有效的 EVM 钱包地址（以 0x 开头，42 个字符）"
        else
            break
        fi
    done

    # 执行 cast call 验证 Responder 状态
    echo "正在验证 Responder 状态..."
    CAST_CALL_RESULT=$(cast call 0x4608Afa7f277C8E0BE232232265850d1cDeB600E "isResponder(address)(bool)" "$OWNER_ADDRESS" --rpc-url https://ethereum-holesky-rpc.publicnode.com 2>/dev/null)
    if [ $? -eq 0 ] && [ "$CAST_CALL_RESULT" = "true" ]; then
        echo "验证成功：EVM 钱包地址 $OWNER_ADDRESS 是 Responder"
    else
        echo "验证失败：EVM 钱包地址 $OWNER_ADDRESS 不是 Responder 或 cast call 出错。请检查地址是否正确，或稍后重试。"
        echo "你可手动运行以下命令验证："
        echo "cast call 0x4608Afa7f277C8E0BE232232265850d1cDeB600E \"isResponder(address)(bool)\" $OWNER_ADDRESS --rpc-url https://ethereum-holesky-rpc.publicnode.com"
        echo "继续执行后续步骤，但请在 Discord 验证前确认 Responder 状态。"
    fi

    # 切换到 Drosera-Network 目录
    echo "切换到 /root/Drosera-Network 目录..."
    cd /root/Drosera-Network || { echo "错误：无法切换到 /root/Drosera-Network 目录，请确保目录存在（运行选项1安装Drosera节点）"; exit 1; }

    # 验证 docker-compose.yaml 存在
    if [ ! -f "docker-compose.yaml" ]; then
        echo "错误：未找到 docker-compose.yaml 文件，请确保 Drosera-Network 仓库正确配置（运行选项1）"
        exit 1
    fi

    # 启动 Docker Compose 服务
    echo "正在启动 Docker Compose 服务..."
    if command -v docker-compose &> /dev/null; then
        echo "使用 docker-compose 启动服务..."
        docker-compose -f docker-compose.yaml up -d || { echo "Docker Compose 服务启动失败"; exit 1; }
        echo "正在收集 Docker Compose 日志..."
        docker-compose -f docker-compose.yaml logs --no-color > drosera.log 2>&1 || { echo "无法收集 Docker Compose 日志"; exit 1; }
        echo "Docker Compose 日志已保存到 $PWD/drosera.log"
    elif docker compose version &> /dev/null; then
        echo "使用 docker compose 启动服务..."
        docker compose -f docker-compose.yaml up -d || { echo "Docker Compose 服务启动失败"; exit 1; }
        echo "正在收集 Docker Compose 日志..."
        docker compose -f docker-compose.yaml logs --no-color > drosera.log 2>&1 || { echo "无法收集 Docker Compose 日志"; exit 1; }
        echo "Docker Compose 日志已保存到 $PWD/drosera.log"
    else
        echo "错误：未找到 docker-compose 或 docker compose 命令，请确保 Docker Compose 已安装（运行选项1）"
        exit 1
    fi
    echo "Docker Compose 服务启动完成"

    # 清理私钥变量
    unset DROSERA_PRIVATE_KEY
    echo "私钥变量已清理"

    # 提供后续步骤
    echo "Cadet 角色配置和验证完成！请按照以下步骤获取 Cadet 角色："
    echo "1. 确保你已加入 Drosera 的官方 Discord 服务器：https://discord.gg/drosera"
    echo "2. 在 Discord 的认证频道（通常为 #verify 或 #authentication）中，等待 Drosera 网络验证你的提交。"
    echo "3. 验证通过后，Discord 机器人会自动分配 Cadet 角色。"
    echo "注意："
    echo "- 如果长时间未获得角色，请检查 Holesky 测试网交易状态或在 Discord 中联系 Drosera 团队。"
    echo "- 如果 Responder 验证失败，可稍后重试 cast call 命令或确认 EVM 钱包地址正确性。"
    echo "- 可查看 $PWD/drosera.log 检查 Docker Compose 服务状态。"

    echo "按任意键返回主菜单..."
    read -r

    # 获取 Discord 用户名列表
    echo "正在获取已注册的 Discord 用户名列表..."
    source /root/.bashrc
    DISCORD_NAMES=$(cast call 0x4608Afa7f277C8E0BE232232265850d1cDeB600E "getDiscordNamesBatch(uint256,uint256)(string[])" 0 2000 --rpc-url https://ethereum-holesky-rpc.publicnode.com/ 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        echo "已注册的 Discord 用户名列表："
        echo "$DISCORD_NAMES" | tr ',' '\n' | sed 's/\[//g' | sed 's/\]//g' | sed 's/"//g' | grep -v "^$" | sort | uniq
        echo
        echo "正在检查你的 Discord 用户名是否已注册..."
        if echo "$DISCORD_NAMES" | grep -q "\"$DISCORD_USERNAME\""; then
            echo "找到你的 Discord 用户名：$DISCORD_USERNAME"
        else
            echo "未找到你的 Discord 用户名：$DISCORD_USERNAME"
            echo "请确保："
            echo "1. Discord 用户名输入正确（区分大小写）"
            echo "2. 等待几分钟后重试，因为链上数据可能需要时间同步"
            echo "3. 如果问题持续，请在 Discord 中联系 Drosera 团队"
        fi
    else
        echo "获取 Discord 用户名列表失败，请稍后重试"
    fi
    
    echo "按任意键返回主菜单..."
    read -r
}

# 主菜单函数
function main_menu() {
    while true; do
        clear
        echo "================================================================"
        echo "脚本由哈哈哈哈编写，推特 @ferdie_jhovie，免费开源，请勿相信收费"
        echo "如有问题，可联系推特，仅此只有一个号"
        echo "================================================================"
        echo "退出脚本，请按键盘 Ctrl + C"
        echo "请选择要执行的操作:"
        echo "1. 安装 Drosera 节点"
        echo "2. 查看 drosera-node 日志"
        echo "3. 重启 Operators"
        echo "4. 升级到1.17并修改 drosera_rpc"
        echo "5. 获取Cadet角色"
        echo -n "请输入选项 (1-5): "
        read -r choice
        case $choice in
            1) install_drosera_node ;;
            2) view_logs ;;
            3) restart_operators ;;
            4) upgrade_to_1_17 ;;
            5) claim_cadet_role ;;
            *) echo "无效选项，请输入 1、2、3 或 4、5" ; sleep 2 ;;
        esac
    done
}

# 启动主菜单
main_menu 
