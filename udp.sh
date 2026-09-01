#!/bin/bash

# 定义配置文件和数据目录
UDP_DIR="/root/udp"
PORTS_CONF="$UDP_DIR/ports.conf"
DATA_FILE="$UDP_DIR/data.txt"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查环境
check_environment() {
    echo "正在检查环境..."
    
    # 检查是否以root权限运行
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用root权限运行此脚本${NC}"
        exit 1
    fi

    # 检查nftables是否安装
    if ! command -v nft &> /dev/null; then
        echo -e "${YELLOW}nftables未安装，正在安装...${NC}"
        yum install -y nftables
        systemctl enable nftables
        systemctl start nftables
        systemctl status nftables
    fi

    # 创建必要的目录和文件
    if [ ! -d "$UDP_DIR" ]; then
        mkdir -p "$UDP_DIR"
    fi

    if [ ! -f "$PORTS_CONF" ]; then
        touch "$PORTS_CONF"
    fi

    if [ ! -f "$DATA_FILE" ]; then
        touch "$DATA_FILE"
    fi

    # 检查nftables表和链
    if ! nft list table inet filter &> /dev/null; then
        nft add table inet filter
    fi
    
    # 添加output链用于流量统计
    if ! nft list chain inet filter udp_stats_out &> /dev/null; then
        nft add chain inet filter udp_stats_out { type filter hook output priority 0 \; policy accept\; }
    fi

    echo -e "${GREEN}环境检查完成${NC}"
}

# 验证端口号
validate_port() {
    local port=$1
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

# 检查端口范围是否重叠
check_port_overlap() {
    local start_port=$1
    local end_port=$2
    
    while IFS='|' read -r existing_remark port_range || [[ -n "$existing_remark" ]]; do
        if [ -z "$port_range" ]; then
            continue
        fi
        local existing_start=$(echo $port_range | cut -d'-' -f1)
        local existing_end=$(echo $port_range | cut -d'-' -f2)
        
        # 检查重叠
        if [ $start_port -le $existing_end ] && [ $end_port -ge $existing_start ]; then
            echo -e "${RED}端口范围与现有配置 $existing_remark: $port_range 重叠${NC}"
            return 1
        fi
    done < "$PORTS_CONF"
    return 0
}

# 添加新端口配置
add_port_config() {
    echo "添加新端口配置"
    echo "==============="

    # 输入备注名
    while true; do
        read -p "请输入备注名（如k3）: " remark
        remark=$(echo "$remark" | xargs)  # 去除前后空格
        if [ -z "$remark" ]; then
            echo -e "${RED}备注名不能为空${NC}"
            continue
        fi
        if grep -q "^$remark|" "$PORTS_CONF"; then
            echo -e "${RED}备注名已存在，请使用其他备注名${NC}"
            continue
        fi
        break
    done

    # 输入起始端口
    while true; do
        read -p "请输入起始端口 (1-65535): " start_port
        if ! validate_port "$start_port"; then
            echo -e "${RED}无效的端口号，请输入1-65535之间的数字${NC}"
            continue
        fi
        break
    done

    # 输入结束端口
    while true; do
        read -p "请输入结束端口 ($start_port-65535): " end_port
        if ! validate_port "$end_port"; then
            echo -e "${RED}无效的端口号，请输入1-65535之间的数字${NC}"
            continue
        fi
        if [ "$end_port" -lt "$start_port" ]; then
            echo -e "${RED}结束端口必须大于或等于起始端口${NC}"
            continue
        fi
        break
    done

    # 检查端口范围重叠
    if ! check_port_overlap "$start_port" "$end_port"; then
        echo -e "${RED}请使用其他端口范围${NC}"
        return 1
    fi

    # 添加配置
    echo "准备写入的配置: $remark|$start_port-$end_port"
    echo "$remark|$start_port-$end_port" >> "$PORTS_CONF"
    
    # 添加nftables规则
    nft add rule inet filter udp_stats_out udp sport $start_port-$end_port counter

    echo -e "${GREEN}端口配置添加成功${NC}"
}

# 查看统计信息
view_statistics() {
    echo -e "${YELLOW}$(cat "$DATA_FILE")${NC}"
}

# 删除端口配置
delete_port_config() {
    echo "删除端口配置"
    echo "==============="

    if [ ! -s "$PORTS_CONF" ]; then
        echo -e "${YELLOW}没有配置的端口范围${NC}"
        return
    fi

    echo "现有配置："
    echo "---------------"
    # 创建临时数组存储备注名和端口范围
    declare -a remarks=()
    declare -a port_ranges=()
    local i=1
    
    while IFS='|' read -r remark port_range || [[ -n "$remark" ]]; do
        if [ -z "$port_range" ]; then
            continue
        fi
        remarks+=("$remark")
        port_ranges+=("$port_range")
        echo "$i. $remark: $port_range"
        ((i++))
    done < "$PORTS_CONF"
    echo "---------------"

    # 获取用户选择
    local total=${#remarks[@]}
    while true; do
        read -p "请选择要删除的序号 (1-$total): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ]; then
            break
        fi
        echo -e "${RED}无效的选择，请输入1-$total之间的数字${NC}"
    done

    # 获取选中的备注名和端口范围
    local select_remark=${remarks[$choice-1]}
    local select_port_range=${port_ranges[$choice-1]}

    # 确认删除
    echo -e "${YELLOW}将要删除以下配置：${NC}"
    echo "备注名: $select_remark"
    echo "端口范围: $select_port_range"
    read -p "确认删除？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消删除操作"
        return
    fi

    # 删除nftables规则
    # 首先获取规则的handle
    handle=$(nft -a list chain inet filter udp_stats_out | grep "sport $select_port_range" | awk -F'#' '{gsub("handle ", "", $2); print $2}')
    echo "提取的handle值: $handle"  # 调试输出
    if [ ! -z "$handle" ]; then
        nft delete rule inet filter udp_stats_out handle $handle
    else
        echo -e "${RED}未找到对应的nftables规则${NC}"
    fi

    # 删除配置文件中的记录
    sed -i "/^$select_remark|/d" "$PORTS_CONF"
    
    # 删除data.txt中的记录
    sed -i "/^\[$select_remark\]/,+1d" "$DATA_FILE"

    echo -e "${GREEN}端口配置删除成功${NC}"
}

# 主菜单
show_menu() {
    echo
    echo "UDP端口管理工具"
    echo "================="
    echo "1. 查看端口统计"
    echo "2. 添加端口配置"
    echo "3. 删除端口配置"
    echo "0. 退出"
    echo
    read -p "请选择操作 (0-3): " choice
    echo

    case $choice in
        1) view_statistics ;;
        2) add_port_config ;;
        3) delete_port_config ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效的选择${NC}" ;;
    esac
}

# 主程序
check_environment

while true; do
    show_menu
done
