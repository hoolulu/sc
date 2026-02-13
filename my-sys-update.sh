#!/bin/bash

# ============================================
# 系统安全更新脚本 - my-sys-update.sh
# 功能：自动检测系统类型，列出安全更新，
#       询问用户是否更新，安全处理内核更新
# 作者：系统管理员
# 版本：1.0
# ============================================

# 颜色定义（让输出更美观）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 脚本标题
clear
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}    系统安全更新脚本 v1.0${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# 检查是否以root权限运行（部分命令需要sudo）
if [ "$EUID" -ne 0 ]; then 
    echo -e "${YELLOW}提示: 部分命令需要root权限，可能会提示输入密码${NC}"
    echo ""
fi

# 检测系统类型
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        SYSTEM_ID=$ID
        SYSTEM_NAME=$PRETTY_NAME
        SYSTEM_VERSION=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        SYSTEM_ID="rhel"
        SYSTEM_NAME=$(cat /etc/redhat-release)
    elif [ -f /etc/debian_version ]; then
        SYSTEM_ID="debian"
        SYSTEM_NAME="Debian"
    else
        SYSTEM_ID="unknown"
        SYSTEM_NAME="未知系统"
    fi
}

# 显示系统信息
show_system_info() {
    echo -e "${CYAN}系统信息：${NC}"
    echo -e "  ${GREEN}系统类型：${NC}$SYSTEM_NAME"
    echo -e "  ${GREEN}当前内核：${NC}$(uname -r)"
    echo -e "  ${GREEN}主机名：${NC}$(hostname)"
    echo -e "  ${GREEN}当前时间：${NC}$(date)"
    echo ""
}

# Red Hat 系列检查更新
check_rhel_updates() {
    echo -e "${BLUE}正在检查安全更新...${NC}"
    echo ""
    
    # 获取安全更新列表
    if command -v dnf &>/dev/null; then
        SEC_UPDATES=$(sudo dnf updateinfo list --security 2>/dev/null | grep -E "重要/|中危/|低危/|Critical|Important|Moderate|Low" || echo "")
    else
        SEC_UPDATES=$(sudo yum updateinfo list --security 2>/dev/null | grep -E "重要/|中危/|低危/|Critical|Important|Moderate|Low" || echo "")
    fi
    
    # 检查是否有内核更新
    KERNEL_UPDATES=$(echo "$SEC_UPDATES" | grep -i kernel || echo "")
    
    if [ -z "$SEC_UPDATES" ]; then
        echo -e "${GREEN}✓ 没有发现待处理的安全更新${NC}"
        return 1
    else
        echo -e "${YELLOW}发现以下安全更新：${NC}"
        echo "----------------------------------------"
        echo "$SEC_UPDATES" | while read line; do
            echo -e "  ${RED}$line${NC}"
        done
        echo "----------------------------------------"
        
        # 如果有内核更新，特别提示
        if [ ! -z "$KERNEL_UPDATES" ]; then
            echo ""
            echo -e "${PURPLE}⚠️  警告：检测到内核更新！${NC}"
            echo -e "${YELLOW}内核更新后需要重启系统才能生效${NC}"
            echo -e "${YELLOW}脚本会保留旧内核作为备用，以防新内核启动失败${NC}"
        fi
        return 0
    fi
}

# Debian/Ubuntu 系列检查更新
check_debian_updates() {
    echo -e "${BLUE}正在更新软件包列表...${NC}"
    sudo apt update &>/dev/null
    echo -e "${BLUE}正在检查安全更新...${NC}"
    echo ""
    
    # 获取安全更新列表
    SEC_UPDATES=$(apt list --upgradable 2>/dev/null | grep -i security || echo "")
    
    # 检查是否有内核更新
    KERNEL_UPDATES=$(echo "$SEC_UPDATES" | grep -E "linux-image|linux-headers" || echo "")
    
    if [ -z "$SEC_UPDATES" ]; then
        echo -e "${GREEN}✓ 没有发现待处理的安全更新${NC}"
        return 1
    else
        echo -e "${YELLOW}发现以下安全更新：${NC}"
        echo "----------------------------------------"
        echo "$SEC_UPDATES" | while read line; do
            echo -e "  ${RED}$line${NC}"
        done
        echo "----------------------------------------"
        
        # 如果有内核更新，特别提示
        if [ ! -z "$KERNEL_UPDATES" ]; then
            echo ""
            echo -e "${PURPLE}⚠️  警告：检测到内核更新！${NC}"
            echo -e "${YELLOW}内核更新后需要重启系统才能生效${NC}"
            echo -e "${YELLOW}脚本会保留旧内核作为备用，以防新内核启动失败${NC}"
        fi
        return 0
    fi
}

# SUSE 系列检查更新
check_suse_updates() {
    echo -e "${BLUE}正在检查安全更新...${NC}"
    echo ""
    
    SEC_UPDATES=$(sudo zypper list-patches --category security 2>/dev/null | grep -E "important|moderate|low" || echo "")
    
    if [ -z "$SEC_UPDATES" ]; then
        echo -e "${GREEN}✓ 没有发现待处理的安全更新${NC}"
        return 1
    else
        echo -e "${YELLOW}发现以下安全更新：${NC}"
        echo "----------------------------------------"
        echo "$SEC_UPDATES"
        echo "----------------------------------------"
        return 0
    fi
}

# Red Hat 系列执行更新
update_rhel() {
    echo ""
    echo -e "${BLUE}正在执行安全更新...${NC}"
    
    if command -v dnf &>/dev/null; then
        sudo dnf update --security -y
    else
        sudo yum update --security -y
    fi
    
    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✓ 安全更新完成${NC}"
        
        # 检查是否需要重启
        if [ ! -z "$KERNEL_UPDATES" ]; then
            echo ""
            echo -e "${PURPLE}⚠️  重要提示：${NC}"
            echo -e "${YELLOW}1. 内核已更新，建议重启系统${NC}"
            echo -e "${YELLOW}2. 重启命令：sudo reboot${NC}"
            echo -e "${YELLOW}3. 重启后请运行 'uname -r' 确认内核版本${NC}"
            echo -e "${YELLOW}4. 如果新内核无法启动，可以在GRUB启动菜单选择旧内核${NC}"
        else
            echo -e "${YELLOW}提示：部分更新可能需要重启相关服务${NC}"
        fi
    else
        echo ""
        echo -e "${RED}✗ 更新过程中出现错误${NC}"
    fi
}

# Debian/Ubuntu 系列执行更新
update_debian() {
    echo ""
    echo -e "${BLUE}正在执行安全更新...${NC}"
    
    # 先模拟运行，让用户看到会更新什么
    echo -e "${YELLOW}将要更新的软件包：${NC}"
    apt-get --dry-run upgrade | grep "^Inst" | grep -i security
    
    echo ""
    read -p "确认要安装这些更新吗？(y/n): " confirm_install
    if [[ $confirm_install == "y" || $confirm_install == "Y" ]]; then
        sudo apt-get upgrade -y
        
        if [ $? -eq 0 ]; then
            echo ""
            echo -e "${GREEN}✓ 安全更新完成${NC}"
            
            # 检查是否需要重启
            if [ -f /var/run/reboot-required ]; then
                echo ""
                echo -e "${PURPLE}⚠️  重要提示：${NC}"
                echo -e "${YELLOW}1. 系统需要重启（检测到 /var/run/reboot-required）${NC}"
                echo -e "${YELLOW}2. 重启命令：sudo reboot${NC}"
                echo -e "${YELLOW}3. 重启后请运行 'uname -r' 确认内核版本${NC}"
                if [ -f /var/run/reboot-required.pkgs ]; then
                    echo -e "${YELLOW}4. 导致重启的软件包：${NC}"
                    cat /var/run/reboot-required.pkgs
                fi
            else
                echo -e "${YELLOW}提示：部分更新可能需要重启相关服务${NC}"
            fi
        else
            echo ""
            echo -e "${RED}✗ 更新过程中出现错误${NC}"
        fi
    else
        echo -e "${YELLOW}已取消更新${NC}"
    fi
}

# SUSE 系列执行更新
update_suse() {
    echo ""
    echo -e "${BLUE}正在执行安全更新...${NC}"
    
    sudo zypper patch --category security
    
    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✓ 安全更新完成${NC}"
        echo -e "${YELLOW}提示：如果内核有更新，建议重启系统${NC}"
    else
        echo ""
        echo -e "${RED}✗ 更新过程中出现错误${NC}"
    fi
}

# 主函数
main() {
    # 检测系统
    detect_system
    show_system_info
    
    # 根据系统类型检查更新
    case $SYSTEM_ID in
        rocky|centos|rhel|almalinux|fedora|rocky|ol)
            check_rhel_updates
            if [ $? -eq 0 ]; then
                echo ""
                read -p "是否安装以上安全更新？(y/n): " confirm
                if [[ $confirm == "y" || $confirm == "Y" ]]; then
                    update_rhel
                else
                    echo -e "${YELLOW}已取消更新${NC}"
                fi
            fi
            ;;
        ubuntu|debian)
            check_debian_updates
            if [ $? -eq 0 ]; then
                update_debian
            fi
            ;;
        opensuse*|suse)
            check_suse_updates
            if [ $? -eq 0 ]; then
                echo ""
                read -p "是否安装以上安全更新？(y/n): " confirm
                if [[ $confirm == "y" || $confirm == "Y" ]]; then
                    update_suse
                else
                    echo -e "${YELLOW}已取消更新${NC}"
                fi
            fi
            ;;
        *)
            echo -e "${RED}未知系统类型，无法自动处理${NC}"
            echo "支持的系统："
            echo "  - Red Hat 系列 (RHEL, CentOS, Rocky, Alma, Fedora)"
            echo "  - Debian/Ubuntu 系列"
            echo "  - openSUSE/SUSE 系列"
            ;;
    esac
    
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}脚本执行完毕${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# 执行主函数
main
