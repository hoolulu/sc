#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 定义配置文件和数据目录
KCPTUN_DIR="/usr/local/kcptun"
UDP_DIR="/root/udp"
PORTS_CONF="$UDP_DIR/ports.conf"

# 检查必要的目录和文件
check_environment() {
    echo "开始环境检查..."
    
    # 检查kcptun目录是否存在
    if [ ! -d "$KCPTUN_DIR" ]; then
        echo -e "${RED}错误: $KCPTUN_DIR 目录不存在${NC}"
        exit 1
    fi
    
    # 检查UDP目录是否存在
    if [ ! -d "$UDP_DIR" ]; then
        echo -e "${RED}错误: $UDP_DIR 目录不存在${NC}"
        exit 1
    fi

    # 检查nftables是否安装
    if ! command -v nft &> /dev/null; then
        echo -e "${YELLOW}nftables未安装，正在安装...${NC}"
        yum install -y nftables
        systemctl enable nftables
        systemctl start nftables
        systemctl status nftables
        
        # 再次检查nftables是否安装成功
        if ! command -v nft &> /dev/null; then
            echo -e "${RED}错误: nftables安装失败${NC}"
            exit 1
        fi
        echo -e "${GREEN}nftables安装成功${NC}"
    else
        echo -e "${GREEN}nftables已安装${NC}"
    fi

    # 检查nftables服务状态
    if ! systemctl is-active nftables &> /dev/null; then
        echo -e "${YELLOW}nftables服务未运行，正在启动...${NC}"
        systemctl start nftables
        if ! systemctl is-active nftables &> /dev/null; then
            echo -e "${RED}错误: nftables服务启动失败${NC}"
            exit 1
        fi
        echo -e "${GREEN}nftables服务启动成功${NC}"
    else
        echo -e "${GREEN}nftables服务正在运行${NC}"
    fi

    # 检查ports.conf文件
    if [ ! -f "$PORTS_CONF" ]; then
        touch "$PORTS_CONF"
        echo -e "${GREEN}创建了新的ports.conf文件${NC}"
    fi

    echo -e "${GREEN}环境检查完成${NC}"
}

# 检查nftables表和链
setup_nftables() {
    echo "配置nftables规则..."
    
    # 检查并创建filter表
    if ! nft list table inet filter &> /dev/null; then
        echo "创建inet filter表..."
        if ! nft add table inet filter; then
            echo -e "${RED}错误: 创建inet filter表失败${NC}"
            return 1
        fi
        echo -e "${GREEN}成功创建inet filter表${NC}"
    else
        echo -e "${GREEN}inet filter表已存在${NC}"
    fi
    
    # 检查并创建udp_stats_out链
    if ! nft list chain inet filter udp_stats_out &> /dev/null; then
        echo "创建udp_stats_out链..."
        if ! nft add chain inet filter udp_stats_out { type filter hook output priority 0 \; policy accept\; }; then
            echo -e "${RED}错误: 创建udp_stats_out链失败${NC}"
            return 1
        fi
        echo -e "${GREEN}成功创建udp_stats_out链${NC}"
    else
        echo -e "${GREEN}udp_stats_out链已存在${NC}"
    fi
    
    return 0
}

# 检查nftables表和链是否存在
check_nftables_chain() {
    if ! nft list table inet filter >/dev/null 2>&1 || ! nft list chain inet filter udp_stats_out >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# 从json文件中提取端口范围
extract_port_range() {
    local file="$1"
    local listen_line=$(grep -E '"listen":\s*":([0-9]+-[0-9]+)",' "$file")
    if [ -z "$listen_line" ]; then
        return 1
    fi
    echo "$listen_line" | sed -E 's/.*":([0-9]+)-([0-9]+)".*/\1-\2/'
}

# 检查nftables规则是否存在
check_nftables_rule() {
    local start_port=$1
    local end_port=$2
    local remark=$3
    
    # 保存当前规则到临时文件
    local tmp_rules="/tmp/nft_rules.tmp"
    nft list chain inet filter udp_stats_out > "$tmp_rules"
    
    # 使用更精确的匹配方式检查规则是否存在
    if grep -F "udp sport $start_port-$end_port counter packets" "$tmp_rules" | grep -F "comment \"$remark\"" > /dev/null; then
        echo -e "${YELLOW}跳过添加规则: 端口范围 $start_port-$end_port ($remark) 的规则已存在${NC}"
        rm -f "$tmp_rules"
        return 0
    fi
    rm -f "$tmp_rules"
    return 1
}

# 添加nftables规则前先清理同名规则
clean_existing_rule() {
    local remark=$1
    
    echo "检查并清理已存在的规则: $remark"
    # 保存当前规则到临时文件
    local tmp_rules="/tmp/nft_rules.tmp"
    nft list chain inet filter udp_stats_out > "$tmp_rules"
    
    # 查找包含相同备注的规则的handle
    local handle=$(grep -F "comment \"$remark\"" "$tmp_rules" | grep -o 'handle [0-9]*' | cut -d' ' -f2)
    
    if [ ! -z "$handle" ]; then
        echo -e "${YELLOW}删除已存在的规则: $remark (handle $handle)${NC}"
        nft delete rule inet filter udp_stats_out handle $handle
    fi
    
    rm -f "$tmp_rules"
}

# 添加nftables规则
add_nftables_rule() {
    local start_port=$1
    local end_port=$2
    local remark=$3
    
    echo "处理端口范围 $start_port-$end_port 的nftables规则..."
    
    # 检查规则是否已存在
    if check_nftables_rule "$start_port" "$end_port" "$remark"; then
        return 0
    fi
    
    # 清理同名的旧规则
    clean_existing_rule "$remark"
    
    if ! nft add rule inet filter udp_stats_out udp sport $start_port-$end_port counter comment \"$remark\"; then
        echo -e "${RED}错误: 添加nftables规则失败: $remark ($start_port-$end_port)${NC}"
        return 1
    fi
    echo -e "${GREEN}成功添加nftables规则: $remark ($start_port-$end_port)${NC}"
    return 0
}

# 获取当前所有json文件的备注名列表
get_current_remarks() {
    local remarks=()
    for json_file in "$KCPTUN_DIR"/*.json; do
        if [ -f "$json_file" ]; then
            remarks+=($(basename "$json_file" .json))
        fi
    done
    echo "${remarks[@]}"
}

# 删除指定备注的nftables规则
delete_nftables_rule() {
    local remark=$1
    echo "删除 $remark 的nftables规则..."
    
    # 获取规则handle
    local handles=$(nft -a list chain inet filter udp_stats_out | grep "comment \"$remark\"" | grep -o 'handle [0-9]*' | awk '{print $2}')
    
    if [ ! -z "$handles" ]; then
        for handle in $handles; do
            echo -e "${YELLOW}删除规则: $remark (handle $handle)${NC}"
            if ! nft delete rule inet filter udp_stats_out handle $handle; then
                echo -e "${RED}删除规则失败: $remark (handle $handle)${NC}"
                return 1
            fi
        done
        return 0
    fi
    echo -e "${YELLOW}未找到规则: $remark${NC}"
    return 0
}

# 同步配置和规则
sync_configurations() {
    echo -e "\n开始同步配置..."
    
    # 检查nftables表和链是否存在
    if ! check_nftables_chain; then
        echo -e "${YELLOW}nftables表或链不存在，跳过同步步骤${NC}"
        return 0
    fi
    
    # 第一步：同步 ports.conf
    echo "1. 同步 ports.conf 配置文件..."
    
    # 创建临时文件存储新的ports.conf内容
    local temp_conf="/tmp/ports.conf.tmp"
    > "$temp_conf"
    
    # 遍历json文件，更新ports.conf
    for json_file in "$KCPTUN_DIR"/*.json; do
        if [ -f "$json_file" ]; then
            local remark=$(basename "$json_file" .json)
            local port_range=$(extract_port_range "$json_file")
            if [ ! -z "$port_range" ]; then
                echo "$remark|$port_range" >> "$temp_conf"
                echo -e "${GREEN}保留配置: $remark ($port_range)${NC}"
            fi
        fi
    done
    
    # 第二步：同步 nftables 规则
    echo -e "\n2. 同步 nftables 规则..."
    
    # 获取当前所有nftables规则
    local temp_rules="/tmp/nft_rules.tmp"
    nft -a list chain inet filter udp_stats_out > "$temp_rules" 2>/dev/null || true
    
    # 如果规则文件为空，创建一个空文件避免grep错误
    if [ ! -f "$temp_rules" ]; then
        touch "$temp_rules"
    fi
    
    # 删除所有不在新配置中的规则
    while read line; do
        if [[ $line =~ comment\ \"([^\"]+)\" ]]; then
            local rule_remark="${BASH_REMATCH[1]}"
            if ! grep -q "^$rule_remark|" "$temp_conf"; then
                echo -e "${YELLOW}删除多余规则: $rule_remark${NC}"
                if ! delete_nftables_rule "$rule_remark"; then
                    echo -e "${RED}警告: 删除规则失败: $rule_remark${NC}"
                fi
            fi
        fi
    done < "$temp_rules"
    
    # 更新ports.conf
    mv "$temp_conf" "$PORTS_CONF"
    
    # 重新获取最新的规则列表
    nft -a list chain inet filter udp_stats_out > "$temp_rules" 2>/dev/null || true
    
    # 添加或更新ports.conf中的规则
    while IFS='|' read -r remark port_range || [[ -n "$remark" ]]; do
        if [ -z "$port_range" ]; then
            continue
        fi
        
        local start_port=$(echo $port_range | cut -d'-' -f1)
        local end_port=$(echo $port_range | cut -d'-' -f2)
        
        # 检查规则是否存在且正确
        if ! grep -q "udp sport $start_port-$end_port.*comment \"$remark\"" "$temp_rules" 2>/dev/null; then
            # 如果规则存在但端口范围不同，先删除旧规则
            if grep -q "comment \"$remark\"" "$temp_rules" 2>/dev/null; then
                echo -e "${YELLOW}更新规则: $remark${NC}"
                delete_nftables_rule "$remark"
            else
                echo -e "${GREEN}添加新规则: $remark${NC}"
            fi
            add_nftables_rule "$start_port" "$end_port" "$remark"
        fi
    done < "$PORTS_CONF"
    
    # 清理临时文件
    rm -f "$temp_rules"
    
    echo -e "${GREEN}nftables 规则同步完成${NC}"
    
    # 显示当前所有nftables规则
    echo -e "\n${YELLOW}当前nftables规则列表：${NC}"
    echo "===================="
    nft list ruleset
    echo "===================="
}

# 主程序
main() {
    # 检查环境
    check_environment || exit 1
    
    # 同步配置和规则
    sync_configurations
    
    # 设置nftables
    setup_nftables || exit 1
    
    # 清空ports.conf
    > "$PORTS_CONF"
    
    # 处理所有json文件
    echo "开始处理json文件..."
    for json_file in "$KCPTUN_DIR"/*.json; do
        if [ ! -f "$json_file" ]; then
            echo -e "${YELLOW}警告: 未找到任何json文件${NC}"
            continue
        fi
        
        # 获取文件名（不包含路径和扩展名）作为备注
        remark=$(basename "$json_file" .json)
        echo "处理配置文件: $remark"
        
        # 提取端口范围
        port_range=$(extract_port_range "$json_file")
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: 无法从 $json_file 提取端口范围${NC}"
            continue
        fi
        
        # 检查是否存在相同备注的配置并删除
        if grep -q "^$remark|" "$PORTS_CONF"; then
            echo -e "${YELLOW}发现重复配置: $remark，正在更新...${NC}"
            # 创建临时文件，排除已存在的配置
            grep -v "^$remark|" "$PORTS_CONF" > "$PORTS_CONF.tmp"
            mv "$PORTS_CONF.tmp" "$PORTS_CONF"
        fi
        
        # 写入ports.conf
        echo "$remark|$port_range" >> "$PORTS_CONF"
        echo -e "${GREEN}已添加配置: $remark|$port_range${NC}"
        
        # 添加nftables规则
        start_port=$(echo $port_range | cut -d'-' -f1)
        end_port=$(echo $port_range | cut -d'-' -f2)
        add_nftables_rule "$start_port" "$end_port" "$remark" || continue
    done
    
    echo -e "${GREEN}批量处理完成${NC}"

    # 显示同步后的nftables规则
    echo -e "\n${YELLOW}同步后的nftables规则列表：${NC}"
    echo "===================="
    nft list ruleset
    echo "===================="
    
    # 显示ports.conf的内容
    echo -e "\n${YELLOW}当前ports.conf内容:${NC}"
    echo "===================="
    cat "$PORTS_CONF"
    echo "===================="
    
    # 设置定时任务
    echo -e "\n设置定时任务..."
    
    # 获取当前的crontab内容
    local temp_cron="/tmp/crontab.tmp"
    crontab -l 2>/dev/null > "$temp_cron"
    
    # 准备新的定时任务
    local reset_task="1 0 1 * * /root/udp/udp-reset.sh >> /root/udp/udp-reset.log 2>&1"
    local monitor_task="* * * * * /root/udp/udp-monitor.sh"
    local need_update=false
    
    # 检查重置任务
    if grep -q "udp-reset.sh" "$temp_cron"; then
        echo -e "${YELLOW}发现已存在的重置统计任务，正在更新...${NC}"
        sed -i '/udp-reset.sh/d' "$temp_cron"
        need_update=true
    else
        echo "添加重置统计任务..."
    fi
    echo "$reset_task" >> "$temp_cron"
    
    # 检查监控任务
    if grep -q "udp-monitor.sh" "$temp_cron"; then
        echo -e "${YELLOW}发现已存在的监控任务，正在更新...${NC}"
        sed -i '/udp-monitor.sh/d' "$temp_cron"
        need_update=true
    else
        echo "添加监控任务..."
    fi
    echo "$monitor_task" >> "$temp_cron"
    
    # 更新crontab
    if crontab "$temp_cron"; then
        if $need_update; then
            echo -e "${GREEN}定时任务更新成功！${NC}"
        else
            echo -e "${GREEN}定时任务添加成功！${NC}"
        fi
        
        echo -e "\n${GREEN}当前的定时任务列表：${NC}"
        echo "===================="
        crontab -l
        echo "===================="
        rm -f "$temp_cron"
    else
        echo -e "${RED}错误：定时任务设置失败${NC}"
        rm -f "$temp_cron"
        exit 1
    fi
}

# 运行主程序
main
