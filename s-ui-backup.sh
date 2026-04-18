#!/bin/bash
set -eo pipefail

# 全局基础配置
SCRIPT_ABS_PATH=$(realpath "$0")
CONFIG_FILE=""
TEMP_DIR=""
VERSION="3.0"
# 跳过SSL证书验证（解决自签名证书问题，不需要可改为false）
SKIP_SSL_VERIFY=true
# 调试模式：开启后会输出详细的WebDAV文件解析过程，排查问题用，正常使用可改为false
DEBUG_MODE=true

# CURL公共参数（统一配置，避免重复代码）
CURL_COMMON=("-sS")
if [[ "$SKIP_SSL_VERIFY" == "true" ]]; then
  CURL_COMMON+=("-k")
fi

# 临时文件强制清理函数
force_clean_temp() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR" > /dev/null 2>&1
  fi
}

# 错误退出函数
error_exit() {
  echo "错误: $1" >&2
  force_clean_temp
  exit 1
}

# WebDAV连通性&权限预校验函数
check_webdav_access() {
  local webdav_url="$1"
  local webdav_user="$2"
  local webdav_pass="$3"
  
  echo ">> 正在预校验WebDAV连通性与权限..."
  # 执行校验，捕获状态码
  HTTP_STATUS=$(curl "${CURL_COMMON[@]}" -u "$webdav_user:$webdav_pass" -X PROPFIND "$webdav_url" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
  
  case "$HTTP_STATUS" in
    207)
      echo "WebDAV连通性校验成功，地址、账号密码正常"
      return 0
      ;;
    401)
      error_exit "WebDAV校验失败：账号密码错误（401），请重新核对"
      ;;
    403)
      error_exit "WebDAV校验失败：账号无访问权限（403），请确认账号有写入/创建目录权限"
      ;;
    404)
      error_exit "WebDAV校验失败：地址不存在（404），请确认完整的WebDAV根路径是否正确"
      ;;
    405)
      error_exit "WebDAV校验失败：该地址不是有效的WebDAV服务路径（405），请获取正确的WebDAV地址"
      ;;
    *)
      error_exit "WebDAV校验失败：网络异常或服务不可用，HTTP状态码：$HTTP_STATUS"
      ;;
  esac
}

# 定时任务自动添加函数
auto_add_crontab() {
  local cron_interval="$1"
  local config_file_path="$2"
  
  echo ">> 正在自动添加定时任务..."

  # 生成crontab时间表达式
  if [[ $cron_interval -eq 60 ]]; then
    CRON_EXPR="0 * * * *"
  else
    CRON_EXPR="*/$cron_interval * * * *"
  fi
  # 无日志定时任务命令
  CRON_CMD="$CRON_EXPR /bin/bash $SCRIPT_ABS_PATH -c $config_file_path > /dev/null 2>&1"

  # 读取现有crontab，过滤掉本脚本的旧任务（去重）
  EXISTING_CRONTAB=$(crontab -l 2>/dev/null | grep -v -F "$SCRIPT_ABS_PATH" || true)
  
  # 写入新的crontab配置
  (echo "$EXISTING_CRONTAB"; echo "$CRON_CMD") | crontab - > /dev/null 2>&1
  
  # 验证添加结果，给出明确反馈
  if crontab -l 2>/dev/null | grep -q -F "$CRON_CMD"; then
    echo "✅ 定时任务添加成功！"
    echo "   执行周期：每${cron_interval}分钟自动执行一次备份"
    echo "   执行命令：$CRON_CMD"
    echo ""
    echo "===== 当前用户全部定时任务列表 ====="
    crontab -l 2>/dev/null || echo "暂无其他定时任务"
    echo "========================================"
  else
    error_exit "❌ 定时任务添加失败，请检查系统cron服务是否正常运行、当前用户是否有crontab权限"
  fi
}

# 核心备份主函数
run_backup() {
  # 配置参数校验
  [[ -z "$TOKEN" ]] && error_exit "S-UI API TOKEN 未配置"
  [[ -z "$HOST" ]] && error_exit "S-UI HOST 地址未配置"
  [[ -z "$WEBDAV_URL" ]] && error_exit "WebDAV 地址未配置"
  [[ -z "$WEBDAV_USER" ]] && error_exit "WebDAV 用户名未配置"
  [[ -z "$WEBDAV_PASS" ]] && error_exit "WebDAV 密码未配置"
  [[ -z "$WEBDAV_DIR" ]] && error_exit "WebDAV 备份目录未配置"
  [[ -z "$RETENTION_COUNT" ]] && RETENTION_COUNT=2

  # 路径标准化处理（双重保险，强力去除可能引入的多余斜杠）
  HOST="${HOST%/}"
  WEBDAV_URL="${WEBDAV_URL%/}"
  WEBDAV_FULL_URL="${WEBDAV_URL}/${WEBDAV_DIR}"
  WEBDAV_FULL_URL_WITH_SLASH="${WEBDAV_FULL_URL}/"
  DATE=$(date +%Y%m%d_%H%M%S)

  # 交互式运行时输出进度
  if [[ -t 0 ]]; then
    echo "=== 开始执行S-UI备份任务 ==="
    echo "备份时间: $(date '+%Y-%m-%d %H:%M:%S')"
    # 预校验WebDAV
    check_webdav_access "$WEBDAV_URL" "$WEBDAV_USER" "$WEBDAV_PASS"
  fi

  # 创建临时目录，交由陷阱自动清理
  TEMP_DIR=$(mktemp -d -t s-ui-backup.XXXXXX)
  trap force_clean_temp EXIT INT TERM

  DB_FILE="$TEMP_DIR/s-ui-db-$DATE.db"
  CONFIG_FILE="$TEMP_DIR/s-ui-config-$DATE.json"

  # 1. 拉取S-UI数据库备份
  if [[ -t 0 ]]; then echo ">> 正在拉取S-UI数据库备份..."; fi
  if ! curl "${CURL_COMMON[@]}" -f -H "Token: $TOKEN" "$HOST/app/apiv2/getdb" -o "$DB_FILE"; then
    error_exit "数据库备份拉取失败，请检查TOKEN和HOST地址"
  fi
  [[ ! -s "$DB_FILE" ]] && error_exit "拉取的数据库文件为空，备份终止"

  # 2. 拉取S-UI全量配置备份
  if [[ -t 0 ]]; then echo ">> 正在拉取S-UI配置备份..."; fi
  if ! curl "${CURL_COMMON[@]}" -f -H "Token: $TOKEN" "$HOST/app/apiv2/load" -o "$CONFIG_FILE"; then
    error_exit "配置备份拉取失败，请检查TOKEN和HOST地址"
  fi
  [[ ! -s "$CONFIG_FILE" ]] && error_exit "拉取的配置文件为空，备份终止"

  # 3. 检查并创建WebDAV备份目录
  if [[ -t 0 ]]; then echo ">> 正在检查WebDAV备份目录..."; fi
  PROPFIND_STATUS=$(curl "${CURL_COMMON[@]}" -u "$WEBDAV_USER:$WEBDAV_PASS" -X PROPFIND "$WEBDAV_FULL_URL_WITH_SLASH" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
  
  if [[ "$PROPFIND_STATUS" != "207" ]]; then
    if [[ -t 0 ]]; then echo "   目录不存在，正在创建WebDAV备份目录: $WEBDAV_DIR"; fi
    MKCOL_STATUS=$(curl "${CURL_COMMON[@]}" -u "$WEBDAV_USER:$WEBDAV_PASS" -X MKCOL "$WEBDAV_FULL_URL_WITH_SLASH" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
    if [[ "$MKCOL_STATUS" != "201" && "$MKCOL_STATUS" != "204" ]]; then
      error_exit "WebDAV目录创建失败，HTTP状态码：$MKCOL_STATUS，请检查地址、账号权限"
    fi
    if [[ -t 0 ]]; then echo "   WebDAV备份目录创建成功"; fi
  else
    if [[ -t 0 ]]; then echo "   WebDAV备份目录已存在，跳过创建"; fi
  fi

  # 4. 上传备份文件到WebDAV
  if [[ -t 0 ]]; then echo ">> 正在上传备份文件到WebDAV..."; fi
  if ! curl "${CURL_COMMON[@]}" -f -u "$WEBDAV_USER:$WEBDAV_PASS" -T "$DB_FILE" "$WEBDAV_FULL_URL_WITH_SLASH" > /dev/null; then
    error_exit "数据库备份上传WebDAV失败"
  fi
  if ! curl "${CURL_COMMON[@]}" -f -u "$WEBDAV_USER:$WEBDAV_PASS" -T "$CONFIG_FILE" "$WEBDAV_FULL_URL_WITH_SLASH" > /dev/null; then
    error_exit "配置备份上传WebDAV失败"
  fi

  if [[ -t 0 ]]; then echo "   备份文件上传完成！"; fi

  # 5. 清理WebDAV远端备份文件（彻底重构版：使用绝对正则替代脆弱的XML解析）
  if [[ -t 0 ]]; then echo ">> 正在清理WebDAV远端备份文件，仅保留最新的 ${RETENTION_COUNT} 份..."; fi

  # 拉取WebDAV文件列表
  WEBDAV_LIST_TMP="$TEMP_DIR/webdav_list.xml"
  curl "${CURL_COMMON[@]}" -u "$WEBDAV_USER:$WEBDAV_PASS" -X PROPFIND -H "Depth: 1" "$WEBDAV_FULL_URL_WITH_SLASH" > "$WEBDAV_LIST_TMP" 2>/dev/null

  if [[ "$DEBUG_MODE" == "true" && -t 0 ]]; then
    echo "   [调试] WebDAV返回的原始内容预览："
    head -20 "$WEBDAV_LIST_TMP"
    echo "   ----------------------------------------"
  fi

  # 【核心修复】直接从原始报文中暴力提取我们脚本规范生成的备份文件时间戳（完全免疫各种XML嵌套格式导致的解析错误）
  # 提取类似 20260418_151931 的纯时间戳字符串 -> 去重 -> 按时间倒序(从新到旧)
  SORTED_TIMESTAMPS=($(grep -oE 's-ui-(config|db)-[0-9]{8}_[0-9]{6}\.(json|db)' "$WEBDAV_LIST_TMP" | grep -oE '[0-9]{8}_[0-9]{6}' | sort -ur))

  if [[ -t 0 ]]; then
    echo "   共发现 ${#SORTED_TIMESTAMPS[@]} 组完整备份"
    if [[ ${#SORTED_TIMESTAMPS[@]} -gt 0 ]]; then
      echo "   备份时间戳（从新到旧）：${SORTED_TIMESTAMPS[*]}"
    fi
  fi

  DELETED_COUNT=0
  if [[ ${#SORTED_TIMESTAMPS[@]} -gt $RETENTION_COUNT ]]; then
    # 计算需要淘汰的旧备份组数
    DELETE_COUNT=$((${#SORTED_TIMESTAMPS[@]} - RETENTION_COUNT))
    # 截取过期的备份时间戳列表
    EXPIRED_TIMESTAMPS=("${SORTED_TIMESTAMPS[@]:$RETENTION_COUNT:$DELETE_COUNT}")
    
    if [[ -t 0 ]]; then
      echo "   将保留最新 ${RETENTION_COUNT} 组，清理 ${#EXPIRED_TIMESTAMPS[@]} 组过期备份"
    fi

    for ts in "${EXPIRED_TIMESTAMPS[@]}"; do
      db_file="s-ui-db-${ts}.db"
      cfg_file="s-ui-config-${ts}.json"
      
      # 删除旧DB文件
      if [[ -t 0 ]]; then echo "   正在删除过期备份: $db_file"; fi
      if curl "${CURL_COMMON[@]}" -f -u "$WEBDAV_USER:$WEBDAV_PASS" -X DELETE "$WEBDAV_FULL_URL_WITH_SLASH$db_file" > /dev/null 2>&1; then
        DELETED_COUNT=$((DELETED_COUNT + 1))
        if [[ -t 0 ]]; then echo "   ✅ 已删除: $db_file"; fi
      fi

      # 删除旧JSON文件
      if [[ -t 0 ]]; then echo "   正在删除过期备份: $cfg_file"; fi
      if curl "${CURL_COMMON[@]}" -f -u "$WEBDAV_USER:$WEBDAV_PASS" -X DELETE "$WEBDAV_FULL_URL_WITH_SLASH$cfg_file" > /dev/null 2>&1; then
        DELETED_COUNT=$((DELETED_COUNT + 1))
        if [[ -t 0 ]]; then echo "   ✅ 已删除: $cfg_file"; fi
      fi
    done
  else
    if [[ -t 0 ]]; then
      echo "   当前备份组数未超过保留限制（${#SORTED_TIMESTAMPS[@]} <= $RETENTION_COUNT），无需清理"
    fi
  fi

  if [[ -t 0 ]]; then
    echo "   备份清理结束，本次共成功删除 $DELETED_COUNT 个过期文件"
    echo "=== 备份任务全部执行完成 ==="
  fi
}

# 交互式配置向导
interactive_setup() {
  echo "========================================"
  echo "      S-UI WebDAV 备份脚本配置向导"
  echo "========================================"
  echo "请按提示输入配置，默认值可直接回车确认"
  echo "----------------------------------------"

  # 1. S-UI API Token 输入
  while true; do
    read -p "请输入S-UI API Token (必填): " TOKEN
    [[ -n "$TOKEN" ]] && break
    echo "错误: Token不能为空，请重新输入"
  done

  # 2. S-UI HOST 地址输入
  read -e -i "http://localhost:2095" -p "请输入S-UI HOST地址: " HOST
  HOST=${HOST%/}
  if [[ ! "$HOST" =~ ^http ]]; then
    error_exit "HOST地址必须以http/https开头"
  fi

  # 3. WebDAV 完整地址输入
  while true; do
    echo "【重要提醒：WebDAV地址末尾请勿加 / 斜杠，正确示例：https://dav.example.com】"
    read -p "请输入WebDAV完整地址(必填): " WEBDAV_URL
    [[ -z "$WEBDAV_URL" ]] && echo "错误: WebDAV地址不能为空，请重新输入" && continue
    [[ ! "$WEBDAV_URL" =~ ^http ]] && echo "错误: WebDAV地址必须以http/https开头，请重新输入" && continue
    if [[ "$WEBDAV_URL" =~ /$ ]]; then
      WEBDAV_URL="${WEBDAV_URL%/}"
      echo "已自动去除地址末尾的斜杠，修正后地址：$WEBDAV_URL"
    fi
    break
  done
  echo "----------------------------------------"

  # 4. WebDAV 用户名输入
  while true; do
    read -p "请输入WebDAV用户名: " WEBDAV_USER
    [[ -n "$WEBDAV_USER" ]] && break
    echo "错误: WebDAV用户名不能为空"
  done

  # 5. WebDAV 密码显性输入
  while true; do
    read -p "请输入WebDAV密码: " WEBDAV_PASS
    [[ -n "$WEBDAV_PASS" ]] && break
    echo "错误: WebDAV密码不能为空"
  done

  # 6. WebDAV 专属备份目录名称
  while true; do
    read -p "请输入WebDAV专属备份目录名称(例: s-ui-backups): " WEBDAV_DIR
    [[ -n "$WEBDAV_DIR" ]] && break
    echo "错误: 备份目录名称不能为空"
  done

  # 7. 备份保留份数设置（默认2份）
  while true; do
    read -e -i "2" -p "请输入WebDAV上保留的备份份数(默认2份，仅保留最新的N次完整备份): " RETENTION_COUNT
    RETENTION_COUNT=${RETENTION_COUNT:-2}
    [[ "$RETENTION_COUNT" =~ ^[1-9][0-9]*$ ]] && break
    echo "错误: 保留份数必须是正整数"
  done

  # 生成配置文件
  echo "----------------------------------------"
  read -e -i "$HOME/.s-ui-backup.conf" -p "请输入配置文件保存路径: " CONFIG_FILE
  CONFIG_FILE=${CONFIG_FILE:-$HOME/.s-ui-backup.conf}

  cat > "$CONFIG_FILE" << EOF
# S-UI WebDAV 备份配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
TOKEN="$TOKEN"
HOST="$HOST"
WEBDAV_URL="$WEBDAV_URL"
WEBDAV_USER="$WEBDAV_USER"
WEBDAV_PASS="$WEBDAV_PASS"
WEBDAV_DIR="$WEBDAV_DIR"
RETENTION_COUNT="$RETENTION_COUNT"
EOF

  chmod 600 "$CONFIG_FILE"
  echo "配置文件已生成，权限已设置为600（仅所有者可读写）"

  # 8. 试运行验证
  echo "----------------------------------------"
  read -p "是否现在执行试运行备份? (y/n，默认y): " RUN_TEST
  RUN_TEST=${RUN_TEST:-y}
  RUN_BACKUP_EXIT_CODE=0
  if [[ "$RUN_TEST" =~ ^[Yy]$ ]]; then
    echo "----------------------------------------"
    # 临时关闭 -e 选项，避免子shell失败导致主脚本退出
    set +e
    (run_backup)
    RUN_BACKUP_EXIT_CODE=$?
    set -e
    echo "----------------------------------------"
    if [[ $RUN_BACKUP_EXIT_CODE -eq 0 ]]; then
      echo "✅ 试运行完成！执行成功，配置正常"
    else
      echo "⚠️  试运行完成！执行失败，请检查上方报错信息"
    fi
  else
    echo "跳过试运行，后续可手动执行脚本测试"
  fi

  # 9. 强制询问是否添加定时任务
  echo "----------------------------------------"
  read -p "是否确认自动添加定时任务? (y/n，默认y): " ADD_CRON
  ADD_CRON=${ADD_CRON:-y}
  if [[ "$ADD_CRON" =~ ^[Yy]$ ]]; then
    while true; do
      read -e -i "60" -p "请输入定时运行间隔(单位:分钟，默认60分钟=1小时): " CRON_INTERVAL
      CRON_INTERVAL=${CRON_INTERVAL:-60}
      [[ "$CRON_INTERVAL" =~ ^[1-9][0-9]*$ ]] && break
      echo "错误: 运行间隔必须是正整数"
    done
    auto_add_crontab "$CRON_INTERVAL" "$CONFIG_FILE"
  else
    echo "已取消定时任务添加，可后续手动配置"
  fi

  echo "========================================"
  echo "脚本配置全部完成！"
  echo "========================================"
}

# 脚本入口参数解析
while getopts "c:h" opt; do
  case $opt in
    c)
      CONFIG_FILE="$OPTARG"
      ;;
    h)
      echo "S-UI WebDAV 备份脚本 v$VERSION"
      echo "用法:"
      echo "  交互式配置: $0"
      echo "  非交互式运行: $0 -c <配置文件路径>"
      echo "  查看帮助: $0 -h"
      exit 0
      ;;
    *)
      error_exit "无效参数，使用 -h 查看帮助"
      ;;
  esac
done

# 运行模式判断
if [[ -n "$CONFIG_FILE" ]]; then
  # 非交互式定时任务模式（自动关闭调试模式，避免输出）
  DEBUG_MODE=false
  [[ ! -f "$CONFIG_FILE" ]] && error_exit "配置文件 $CONFIG_FILE 不存在"
  source "$CONFIG_FILE"
  run_backup
else
  # 交互式配置模式
  interactive_setup
fi
