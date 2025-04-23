#!/bin/bash

# 脚本保存路径
SCRIPT_PATH="$HOME/Drosera.sh"

# 命令1：安装 Drosera 节点
function install_drosera_node() {
    # 检查是否以 root 权限运行
    if [ "$EUID" -ne 0 ]; then
        echo "请以 root 权限运行此脚本 (sudo)"
        exit 1
    fi

    # 更新系统包
    echo "正在更新系统包..."
    apt-get update && apt-get upgrade -y

    # 检查 jq 是否安装
    if ! command -v jq &> /dev/null; then
        echo "jq 未安装，正在安装..."
        apt-get install -y jq
        echo "jq 安装完成"
    else
        echo "jq 已安装，检查更新..."
        apt-get install -y jq
    fi

    # 检查 Docker 是否安装
    if ! command -v docker &> /dev/null; then
        echo "Docker 未安装，正在安装..."
        apt-get install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io
        echo "Docker 安装完成"
    else
        echo "Docker 已安装，检查更新..."
        apt-get install -y docker-ce docker-ce-cli containerd.io
    fi

    # 启动并启用 Docker 服务
    systemctl start docker
    systemctl enable docker

    # 检查 Docker Compose 是否安装
    if ! command -v docker-compose &> /dev/null; then
        echo "Docker Compose 未安装，正在安装最新版本..."
        DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        echo "Docker Compose 安装完成"
    else
        echo "Docker Compose 已安装，检查更新..."
        DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi

    # 安装 Bun
    echo "正在安装 Bun..."
    curl -fsSL https://bun.sh/install | bash
    # 检查 Bun 是否安装成功
    BUN_BIN="/root/.bun/bin/bun"
    if [ -f "$BUN_BIN" ]; then
        echo "Bun 安装完成"
    else
        echo "Bun 安装失败，请检查网络或 https://bun.sh/install"
        exit 1
    fi

    # 安装 Foundry
    echo "正在安装 Foundry..."
    curl -L https://foundry.paradigm.xyz | bash
    # 添加 Foundry 的环境变量（确保 foundryup 可执行）
    if [ -f "/root/.foundry/bin/foundryup" ]; then
        /root/.foundry/bin/foundryup
        echo "Foundry 安装完成"
    else
        echo "Foundry 安装失败，请检查网络或 https://foundry.paradigm.xyz"
        exit 1
    fi

    # 安装 Drosera
    echo "正在安装 Drosera..."
    curl -L https://app.drosera.io/install | bash
    echo "Drosera 安装完成"

    # 检查并运行 Drosera
    DROsera_BIN="/root/.drosera/bin/drosera"
    if [ -f "$DROsera_BIN" ]; then
        echo "找到 Drosera，正在运行..."
        $DROsera_BIN
    else
        echo "Drosera 未找到（$DROsera_BIN 不存在），可能是安装失败"
    fi

    # 运行 droseraup
    if command -v droseraup &> /dev/null; then
        echo "正在运行 droseraup..."
        droseraup
    else
        echo "droseraup 命令未找到，可能是未正确安装或不在 PATH 中"
    fi

    # 创建 my-drosera-trap 目录并切换
    echo "创建 my-drosera-trap 目录并切换..."
    mkdir -p /root/my-drosera-trap && cd /root/my-drosera-trap

    # 配置 Git 用户信息
    echo "配置 Git 用户信息..."
    git config --global user.email "1"
    git config --global user.name "1"

    # 初始化 Foundry 模板
    echo "初始化 Foundry 模板..."
    forge init -t drosera-network/trap-foundry-template
    if [ $? -eq 0 ]; then
        echo "Foundry 模板初始化完成"
    else
        echo "Foundry 模板初始化失败，请检查网络或 drosera-network/trap-foundry-template 仓库"
        exit 1
    fi

    # 执行 bun install
    echo "执行 bun install..."
    bun install
    if [ $? -eq 0 ]; then
        echo "bun install 完成"
    else
        echo "bun install 失败，请检查 package.json 或 Bun 环境"
        exit 1
    fi

    # 执行 forge build
    echo "执行 forge build..."
    forge build
    if [ $? -eq 0 ]; then
        echo "forge build 完成"
    else
        echo "forge build 失败，请检查项目配置或 Foundry 环境"
        exit 1
    fi

    # 提示用户确保 Holesky ETH 资金并输入 EVM 钱包私钥
    echo "请确保你的钱包地址在 Holesky 测试网上有足够的 ETH 用于交易。"
    echo "请输入 EVM 钱包私钥："
    read DROSERA_PRIVATE_KEY
    if [ -z "$DROSERA_PRIVATE_KEY" ]; then
        echo "错误：未提供私钥，drosera apply 将跳过"
    else
        echo "正在执行 drosera apply..."
        export DROSERA_PRIVATE_KEY
        echo "ofc" | drosera apply
        if [ $? -eq 0 ]; then
            echo "drosera apply 完成"
        else
            echo "drosera apply 失败，请检查私钥或 Drosera 配置"
            exit 1
        fi
    fi

    # 询问用户是否继续进行下一步
    echo "所有操作已完成，是否继续进行下一步（drosera dryrun、第二次 drosera apply、Drosera Operator 安装和注册、防火墙配置、检查并停止 drosera 服务、配置 Drosera-Network 仓库、启动 Docker Compose 服务）？（y/n）"
    read -r CONTINUE
    if [ "$CONTINUE" = "y" ] || [ "$CONTINUE" = "Y" ]; then
        echo "正在执行 drosera dryrun..."
        cd /root/my-drosera-trap
        drosera dryrun
        if [ $? -eq 0 ]; then
            echo "drosera dryrun 完成"
        else
            echo "drosera dryrun 失败，请检查 Drosera 配置或环境"
            exit 1
        fi

            # 提示用户输入 EVM 钱包地址并修改 drosera.toml
    echo "请输入 EVM 钱包地址（用于 drosera.toml 的 whitelist）："
    read WALLET_ADDRESS
    if [ -z "$WALLET_ADDRESS" ]; then
        echo "错误：未提供钱包地址，drosera.toml 修改将失败"
        exit 1
    fi

    # 检查 drosera.toml 是否存在
    DROsera_TOML="/root/my-drosera-trap/drosera.toml"
    if [ -f "$DROsera_TOML" ]; then
        # 修改 whitelist
        if grep -q "whitelist = \[\]" "$DROsera_TOML"; then
            sed -i "s/whitelist = \[\]/whitelist = [\"$WALLET_ADDRESS\"]/g" "$DROsera_TOML"
            echo "已更新 drosera.toml 的 whitelist 为 [\"$WALLET_ADDRESS\"]"
        else
            echo "错误：drosera.toml 中未找到 'whitelist = []'，请检查文件内容"
            exit 1
        fi
        # 添加 private_trap = true
        echo "private_trap = true" >> "$DROsera_TOML"
        echo "已添加 private_trap = true 到 drosera.toml"
    else
        echo "错误：drosera.toml 未找到（$DROsera_TOML），可能是 forge init 失败"
        exit 1
    fi

        # 执行第二次 drosera apply
        if [ -z "$DROSERA_PRIVATE_KEY" ]; then
            echo "错误：未提供私钥，第二次 drosera apply 将跳过"
        else
            echo "正在执行第二次 drosera apply..."
            cd /root/my-drosera-trap
            DROSERA_PRIVATE_KEY=$DROSERA_PRIVATE_KEY echo "ofc" | drosera apply
            if [ $? -eq 0 ]; then
                echo "第二次 drosera apply 完成"
            else
                echo "第二次 drosera apply 失败，请检查私钥或 Drosera 配置"
                exit 1
            fi
        fi

        # 切换到主目录并安装 Drosera Operator
        echo "切换到主目录并安装 Drosera Operator..."
        cd ~
        curl -LO https://github.com/drosera-network/releases/releases/download/v1.16.2/drosera-operator-v1.16.2-x86_64-unknown-linux-gnu.tar.gz
        tar -xvf drosera-operator-v1.16.2-x86_64-unknown-linux-gnu.tar.gz
        echo "Drosera Operator 安装完成"

        # 测试 Drosera Operator
        echo "测试 Drosera Operator 是否正常运行..."
        ./drosera-operator --version
        if [ $? -eq 0 ]; then
            echo "Drosera Operator 版本检查成功"
        else
            echo "Drosera Operator 版本检查失败，请检查二进制文件"
            exit 1
        fi

        # 复制 Drosera Operator 到 /usr/bin
        echo "复制 Drosera Operator 到 /usr/bin..."
        sudo cp drosera-operator /usr/bin
        if [ $? -eq 0 ]; then
            echo "Drosera Operator 已成功复制到 /usr/bin"
        else
            echo "复制 Drosera Operator 到 /usr/bin 失败"
            exit 1
        fi

        # 拉取 Drosera Operator 的最新 Docker 镜像
        echo "正在拉取 Drosera Operator 的最新 Docker 镜像..."
        docker pull ghcr.io/drosera-network/drosera-operator:latest
        if [ $? -eq 0 ]; then
            echo "Drosera Operator Docker 镜像拉取完成"
        else
            echo "Drosera Operator Docker 镜像拉取失败，请检查网络或 Docker 配置"
            exit 1
        fi

        # 运行 Drosera Operator 注册
        if [ -z "$DROSERA_PRIVATE_KEY" ]; then
            echo "错误：未提供私钥，drosera-operator register 将跳过"
        else
            echo "正在运行 Drosera Operator 注册..."
            drosera-operator register --eth-rpc-url https://ethereum-holesky-rpc.publicnode.com --eth-private-key $DROSERA_PRIVATE_KEY
            if [ $? -eq 0 ]; then
                echo "Drosera Operator 注册完成"
            else
                echo "Drosera Operator 注册失败，请检查私钥或 Holesky RPC 连接"
                exit 1
            fi
        fi

        # 配置并启用防火墙
        echo "正在配置并启用防火墙..."
        sudo ufw allow ssh
        sudo ufw allow 22
        sudo ufw enable
        echo "防火墙已启用，允许 SSH 和端口 22"

        # 允许 Drosera 端口
        echo "正在允许 Drosera 端口..."
        sudo ufw allow 31313/tcp
        sudo ufw allow 31314/tcp
        echo "已允许 Drosera 端口 31313/tcp 和 31314/tcp"

        # 检查并停止 drosera 服务
        echo "正在检查 drosera 服务状态..."
        if systemctl is-active --quiet drosera; then
            echo "drosera 服务正在运行，正在停止并禁用..."
            sudo systemctl stop drosera
            sudo systemctl disable drosera
            echo "drosera 服务已停止并禁用"
        else
            echo "drosera 服务未运行，无需停止"
        fi

        # 拉取 Drosera-Network 仓库
        echo "正在拉取 Drosera-Network 仓库..."
        git clone https://github.com/sdohuajia/Drosera-Network.git
        if [ $? -eq 0 ]; then
            echo "Drosera-Network 仓库拉取完成"
        else
            echo "Drosera-Network 仓库拉取失败，请检查网络或 https://github.com/sdohuajia/Drosera-Network.git"
            exit 1
        fi

        # 切换到 Drosera-Network 目录并复制 .env 文件
        echo "切换到 Drosera-Network 目录并复制 .env 文件..."
        cd Drosera-Network
        cp .env.example .env
        if [ $? -eq 0 ]; then
            echo ".env 文件复制完成"
        else
            echo ".env 文件复制失败，请检查 .env.example 是否存在"
            exit 1
        fi

        # 提示用户输入服务器 IP 并写入 .env
        echo "请输入服务器公网 IP 地址（用于 .env 的 VPS_IP）："
        read SERVER_IP
        if [ -z "$SERVER_IP" ]; then
            echo "错误：未提供服务器 IP，.env 配置将失败"
            exit 1
        fi
        sed -i "s/VPS_IP=.*/VPS_IP=$SERVER_IP/" .env
        echo "已更新 .env 的 VPS_IP 为 $SERVER_IP"

        # 写入 ETH_PRIVATE_KEY 到 .env
        if [ -z "$DROSERA_PRIVATE_KEY" ]; then
            echo "错误：未提供私钥，ETH_PRIVATE_KEY 配置将跳过"
        else
            sed -i "s/ETH_PRIVATE_KEY=.*/ETH_PRIVATE_KEY=$DROSERA_PRIVATE_KEY/" .env
            echo "已更新 .env 的 ETH_PRIVATE_KEY"
        fi

        # 启动 Docker Compose 服务
        echo "正在启动 Docker Compose 服务..."
        docker compose up -d
        if [ $? -eq 0 ]; then
            echo "Docker Compose 服务启动完成"
        else
            echo "Docker Compose 服务启动失败，请检查 docker-compose.yml 或 Docker 配置"
            exit 1
        fi
    else
        echo "用户选择退出，安装 Drosera 节点结束。"
        return
    fi

    echo "Drosera 节点安装和配置完成！"
    echo "按任意键返回主菜单..."
    read -r
}

# 命令2：查看日志
function view_logs() {
    echo "正在查看 drosera-node 日志..."
    docker logs -f drosera-node
    echo "日志查看结束，按任意键返回主菜单..."
    read -r
}

# 主菜单函数
function main_menu() {
    while true; do
        clear
        echo "脚本由哈哈哈哈编写，推特 @ferdie_jhovie，免费开源，请勿相信收费"
        echo "如有问题，可联系推特，仅此只有一个号"
        echo "================================================================"
        echo "退出脚本，请按键盘 ctrl + C 退出即可"
        echo "请选择要执行的操作:"
        echo "1. 安装 Drosera 节点"
        echo "2. 查看日志"
        echo -n "请输入选项 (1-2): "
        read choice
        case $choice in
            1) install_drosera_node ;;
            2) view_logs ;;
            *) echo "无效选项，请输入 1 或 2" ; sleep 2 ;;
        esac
    done
}

# 启动主菜单
main_menu
