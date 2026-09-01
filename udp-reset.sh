# 2025.9.14 16:36 更新以支持rocky系统
#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# 备份 udp_stats_out 链的规则，并移除计数器的值
nft list chain inet filter udp_stats_out > /tmp/udp_stats_out_rules.tmp 2>/dev/null
sed -i 's/counter packets [0-9]* bytes [0-9]*/counter/g' /tmp/udp_stats_out_rules.tmp

# 删除 udp_stats_out 链
nft delete chain inet filter udp_stats_out

# 重新创建 udp_stats_out 链
nft add chain inet filter udp_stats_out { type filter hook output priority 0 \; policy accept\; }

# 重新加载备份的规则
if [ -s /tmp/udp_stats_out_rules.tmp ]; then
    # 提取并添加规则，只选择以 "udp sport" 开头的行
    grep -E '^\s*udp sport' /tmp/udp_stats_out_rules.tmp | while IFS= read -r rule; do
        # 移除规则前的空白字符
        cleaned_rule=$(echo "$rule" | sed -e 's/^[ \t]*//')
        if [[ -n "$cleaned_rule" ]]; then
            nft add rule inet filter udp_stats_out "$cleaned_rule"
        fi
    done
fi

# 删除临时文件
rm -f /tmp/udp_stats_out_rules.tmp

# 显示更新后的规则集
nft list ruleset

