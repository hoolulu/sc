#!/bin/bash
set -eo pipefail

# 全局基础配置
SCRIPT_ABS_PATH=$(realpath "$0")
CONFIG_FILE=""
TEMP_DIR=""
VERSION="3.3"  # 修复版本
# 跳过SSL证书验证（解决自签名证书问题，不需要可改为false）
SKIP_SSL_VERIFY=true
# 调试模式：开启后会输出详细的WebDAV文件解析过程，排查问题用，正常使用可改为false
DEBUG_MODE=true

# 核心修复：优先使用本地数据库文件备份，避免API序列化大表导致内存爆炸
# 如果脚本与S-UI在同一台机器，强烈建议保持true；如远程备份S-UI，设为false
USE_LOCAL_DB_FIRST=true

# API模式：排除大数据表（流量统计），多个表用逗号分隔，如 "clientTraffics,clientInfos"
# 留空表示不排除（不推荐，会拉取全量数据库）
DB_EXCLUDE_FIELDS="clientTraffics"

# 是否同时备份配置JSON（通过load API）。false可显著减少资源消耗。
BACKUP_LOAD_JSON=false

# CURL公共参数（基础版，用于WebDAV探测等操作）
# 修复：移除 --compressed，避免大文件传输时CPU飙高
CURL_COMMON_BASE=("-sS" "--ipv4" "--connect-timeout" "15" "--max-time" "120")
if [[ "$SKIP_SSL_VERIFY" == "true" ]]; then
  CURL_COMMON_BASE+=("-k")
fi

# CURL下载参数（用于文件下载/上传，添加失败检测）
CURL_COMMON_DOWNLOAD=("${CURL_COMMON_BASE[@]}" "--fail")
# CURL上传参数
CURL_COMMON_UPLOAD=("${CURL_COMMON_BASE[@]}" "--fail")

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

# WebDAV连通性&权限预校验函数（增强版，带重试）
check_webdav_access() {
  local webdav_url="$1"
  local webdav_user="$2"
  local webdav_pass="$3"
  local max_retries=2
  local retry_delay=2
  
  echo ">> 正在预校验WebDAV连通性与权限..."
  
  for ((i=1; i<=max_retries; i++)); do
    HTTP_STATUS=$(curl "${CURL_COMMON_BASE[@]}" \
      -u "$webdav_user:$webdav_pass" \
      -X PROPFIND \
      "$webdav_url" \
      -o /dev/null \
      -w "%{http_code}" 2>/dev/null || echo "000")
    
    case "$HTTP_STATUS" in
      207)
        echo "✅ WebDAV连通性校验成功，地址、账号密码正常"
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
      000)
        if [[ $i -lt $max_retries ]]; then
          echo "   ⚠️  连接失败，${retry_delay}秒后重试（$i/$max_retries）..."
          sleep $retry_delay
        else
          echo ""
          echo "❌ WebDAV连接失败，HTTP状态码: 000"
          echo "调试命令（请手动执行验证）："
          echo "  curl -v -k -u '账号:密码' -X PROPFIND '$webdav_url'"
          error_exit "WebDAV校验失败：无法连接到服务器"
        fi
        ;;
      *)
        if [[ $i -lt $max_retries ]]; then
          echo "   ⚠️  收到异常状态码 $HTTP_STATUS，${retry_delay}秒后重试..."
          sleep $retry_delay
        else
          error_exit "WebDAV校验失败：服务器返回异常状态码 $HTTP_STATUS"
        fi
        ;;
    esac
  done
}

# 定时任务自动添加函数
auto_add_crontab() {
  local cron_interval="$1"
  local config_file_path="$2"
  
  echo ">> 正在自动添加定时任务..."

  if [[ $cron_interval -eq 60 ]]; then
    CRON_EXPR="0 * * * *"
  else
    CRON_EXPR="*/$cron_interval * * * *"
  fi
  CRON_CMD="$CRON_EXPR /bin/bash $SCRIPT_ABS_PATH -c $config_file_path > /dev/null 2>&1"

  EXISTING_CRONTAB=$(crontab -l 2>/dev/null | grep -v -F "$SCRIPT_ABS_PATH" || true)
  
  (echo "$EXISTING_CRONTAB"; echo "$CRON_CMD") | crontab - > /dev/null 2>&1
  
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

# 修复：本地数据库文件备份函数（零开销，不经过API）
backup_local_db() {
  local db_src="/usr/local/s-ui/db/s-ui.db"
  local db_dst="$1"
  
  if [[ ! -f "$db_src" ]]; then
    return 1
  fi
  
  if command -v sqlite3 &> /dev/null; then
    # 使用sqlite3在线备份，不锁库，服务零感知
    sqlite3 "$db_src" ".backup '$db_dst'" > /dev/null 2>&1
  else
    # 回退到cp（需确保S-UI当前无写入，通常夜间备份安全）
    cp -f "$db_src" "$db_dst"
  fi
  
  [[ -s "$db_dst" ]]
}

# 修复：通过API下载数据库，排除大表并流式解码base64
download_db_via_api() {
  local api_url="$1"
  local token="$2"
  local out_file="$3"
  
  local exclude_param=""
  if [[ -n "$DB_EXCLUDE_FIELDS" ]]; then
    exclude_param="?exclude=${DB_EXCLUDE_FIELDS}"
  fi
  
  # 关键修复：
  # 1. 使用 -w 同时获取HTTP状态码和输出到stdout
  # 2. 通过管道流式传给jq提取obj字段，再base64解码
  # 3. 避免一次性将大JSON加载到内存
  # 4. 移除 --compressed，减少CPU消耗
  
  local http_status
  http_status=$(curl "${CURL_COMMON_DOWNLOAD[@]}" \
    -H "Token: $token" \
    -w "\n%{http_code}" \
    -o - \
    "${api_url}${exclude_param}" 2>/dev/null | {
      local body=""
      local code=""
      while IFS= read -r line; do
        if [[ "$line" =~ ^[0-9]{3}$ ]]; then
          code="$line"
        else
          body="${body}${line}"$'\n'
        fi
      done
      
      if [[ "$code" != "200" ]]; then
        echo "HTTP_$code" >&2
        exit 1
      fi
      
      # 流式解析：提取obj字段的base64并解码
      # 注意：如果响应体极大，jq解析仍可能消耗较多内存，但比shell字符串处理高效得多
      if ! echo "$body" | jq -r '.obj // empty' | base64 -d > "$out_file" 2>/dev/null; then
        echo "DECODE_ERROR" >&2
        exit 1
      fi
    })
  
  local curl_exit=$?
  if [[ $curl_exit -ne 0 ]] || [[ ! -s "$out_file" ]]; then
    return 1
  fi
  return 0
}

# 修复：通过API下载配置JSON（可选）
download_config_via_api() {
  local api_url="$1"
  local token="$2"
  local out_file="$3"
  
  if ! curl "${CURL_COMMON_DOWNLOAD[@]}" -H "Token: $token" "$api_url" -o "$out_file"; then
    return 1
  fi
  # 验证是否为有效JSON
  if ! jq -e '.success' "$out_file" > /dev/null 2>&1; then
    return 1
  fi
  return 0
}

# 核心备份主函数（修复版）
run_backup() {
  # 配置参数校验
  [[ -z "$TOKEN" ]] && error_exit "S-UI API TOKEN 未配置"
  [[ -z "$HOST" ]] && error_exit "S-UI HOST 地址未配置"
  [[ -z "$WEBDAV_URL" ]] && error_exit "WebDAV 地址未配置"
  [[ -z "$WEBDAV_USER" ]] && error_exit "WebDAV 用户名未配置"
  [[ -z "$WEBDAV_PASS" ]] && error_exit "WebDAV 密码未配置"
  [[ -z "$WEBDAV_DIR" ]] && error_exit "WebDAV 备份目录未配置"
  [[ -z "$RETENTION_COUNT" ]] && RETENTION_COUNT=2

  # 路径标准化处理
  HOST="${HOST%/}"
  WEBDAV_URL="${WEBDAV_URL%/}"
  WEBDAV_FULL_URL="${WEBDAV_URL}/${WEBDAV_DIR}"
  WEBDAV_FULL_URL_WITH_SLASH="${WEBDAV_FULL_URL}/"
  DATE=$(date +%Y%m%d_%H%M%S)

  # 交互式运行时输出进度
  if [[ -t 0 ]]; then
    echo "=== 开始执行S-UI备份任务 ==="
    echo "备份时间: $(date '+%Y-%m-%d %H:%M:%S')"
    if [[ "$USE_LOCAL_DB_FIRST" == "true" ]]; then
      echo "备份模式: 优先本地数据库文件（零API开销）"
    else
      echo "备份模式: API远程拉取（排除字段: ${DB_EXCLUDE_FIELDS:-无}）"
    fi
    check_webdav_access "$WEBDAV_URL" "$WEBDAV_USER" "$WEBDAV_PASS"
  fi

  # 创建临时目录，交由陷阱自动清理
  TEMP_DIR=$(mktemp -d -t s-ui-backup.XXXXXX)
  trap force_clean_temp EXIT INT TERM

  DB_FILE="$TEMP_DIR/s-ui-db-$DATE.db"
  CONFIG_FILE="$TEMP_DIR/s-ui-config-$DATE.json"
  LOCAL_BACKUP_SUCCESS=false

  # 修复点1：优先使用本地文件备份，避免API拉取大文件导致内存爆炸
  if [[ "$USE_LOCAL_DB_FIRST" == "true" ]]; then
    if [[ -t 0 ]]; then echo ">> 正在通过本地文件备份数据库..."; fi
    if backup_local_db "$DB_FILE"; then
      if [[ -t 0 ]]; then echo "   ✅ 本地数据库备份成功（通过sqlite3在线备份）"; fi
      LOCAL_BACKUP_SUCCESS=true
    else
      if [[ -t 0 ]]; then echo "   ⚠️  本地备份失败（文件不存在或无sqlite3），回退到API模式..."; fi
    fi
  fi

  # 修复点2：本地备份失败时，使用API但排除流量统计大表
  if [[ "$LOCAL_BACKUP_SUCCESS" != "true" ]]; then
    if [[ -t 0 ]]; then echo ">> 正在通过API拉取数据库备份（已排除大字段: ${DB_EXCLUDE_FIELDS:-无}）..."; fi
    
    if ! download_db_via_api "$HOST/app/apiv2/getdb" "$TOKEN" "$DB_FILE"; then
      # 如果带exclude失败，尝试不带exclude（兼容旧版本）
      if [[ -n "$DB_EXCLUDE_FIELDS" ]]; then
        if [[ -t 0 ]]; then echo "   ⚠️  带排除参数失败，尝试拉取全量数据库..."; fi
        DB_EXCLUDE_FIELDS=""
        if ! download_db_via_api "$HOST/app/apiv2/getdb" "$TOKEN" "$DB_FILE"; then
          error_exit "数据库备份拉取失败，请检查TOKEN、HOST地址及S-UI服务状态"
        fi
      else
        error_exit "数据库备份拉取失败，请检查TOKEN和HOST地址"
      fi
    fi
    
    # 验证是否为有效的SQLite文件（SQLite文件头为 SQLite format 3\0）
    if [[ -s "$DB_FILE" ]]; then
      local magic
      magic=$(head -c 16 "$DB_FILE" | tr -d '\0')
      if [[ "$magic" != *"SQLite format 3"* ]]; then
        error_exit "拉取的数据库文件不是有效的SQLite格式，可能是API返回异常或base64解码失败"
      fi
    else
      error_exit "拉取的数据库文件为空，备份终止"
    fi
  fi

  # 修复点3：配置JSON备份改为可选（默认关闭），减少资源消耗
  if [[ "$BACKUP_LOAD_JSON" == "true" ]]; then
    if [[ -t 0 ]]; then echo ">> 正在拉取S-UI配置备份（可选）..."; fi
    if ! download_config_via_api "$HOST/app/apiv2/load" "$TOKEN" "$CONFIG_FILE"; then
      if [[ -t 0 ]]; then echo "   ⚠️  配置备份拉取失败（非致命错误，数据库备份已完成）"; fi
      # 创建一个空标记文件避免后续上传报错
      echo '{"success":false,"msg":"load backup skipped"}' > "$CONFIG_FILE"
    fi
  else
    # 创建空标记文件，保持WebDAV文件命名一致性
    echo '{"success":false,"msg":"load backup disabled"}' > "$CONFIG_FILE"
  fi

  # 3. 检查并创建WebDAV备份目录
  if [[ -t 0 ]]; then echo ">> 正在检查WebDAV备份目录..."; fi
  PROPFIND_STATUS=$(curl "${CURL_COMMON_BASE[@]}" -u "$WEBDAV_USER:$WEBDAV_PASS" -X PROPFIND "$WEBDAV_FULL_URL_WITH_SLASH" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
  
  if [[ "$PROPFIND_STATUS" != "207" ]]; then
    if [[ -t 0 ]]; then echo "   目录不存在，正在创建WebDAV备份目录: $WEBDAV_DIR"; fi
    MKCOL_STATUS=$(curl "${CURL_COMMON_BASE[@]}" -u "$WEBDAV_USER:$WEBDAV_PASS" -X MKCOL "$WEBDAV_FULL_URL_WITH_SLASH" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
    if [[ "$MKCOL_STATUS" != "201" && "$MKCOL_STATUS" != "204" ]]; then
      error_exit "WebDAV目录创建失败，HTTP状态码：$MKCOL_STATUS，请检查地址、账号权限"
    fi
    if [[ -t 0 ]]; then echo "   WebDAV备份目录创建成功"; fi
  else
    if [[ -t 0 ]]; then echo "   WebDAV备份目录已存在，跳过创建"; fi
  fi

  # 4. 上传备份文件到WebDAV
  if [[ -t 0 ]]; then echo ">> 正在上传备份文件到WebDAV..."; fi
  if ! curl "${CURL_COMMON_UPLOAD[@]}" -u "$WEBDAV_USER:$WEBDAV_PASS" -T "$DB_FILE" "$WEBDAV_FULL_URL_WITH_SLASH" > /dev/null; then
    error_exit "数据库备份上传WebDAV失败"
  fi
  if ! curl "${CURL_COMMON_UPLOAD[@]}" -u "$WEBDAV_USER:$WEBDAV_PASS" -T "$CONFIG_FILE" "$WEBDAV_FULL_URL_WITH_SLASH" > /dev/null; then
    error_exit "配置备份上传WebDAV失败"
  fi

  if [[ -t 0 ]]; then echo "   备份文件上传完成！"; fi

  # 5. 清理WebDAV远端备份文件
  if [[ -t 0 ]]; then echo ">> 正在清理WebDAV远端备份文件，仅保留最新的 ${RETENTION_COUNT} 份..."; fi

  WEBDAV_RESPONSE=$(curl "${CURL_COMMON_BASE[@]}" -u "$WEBDAV_USER:$WEBDAV_PASS" -X PROPFIND -H "Depth: 1" "$WEBDAV_FULL_URL_WITH_SLASH" 2>/dev/null)
  
  if [[ "$DEBUG_MODE" == "true" && -t 0 ]]; then
    echo "   [调试] WebDAV返回内容大小: ${#WEBDAV_RESPONSE} 字节"
  fi

  SORTED_TIMESTAMPS=($(echo "$WEBDAV_RESPONSE" | grep -oE 's-ui-(config|db)-[0-9]{8}_[0-9]{6}\.(json|db)' | grep -oE '[0-9]{8}_[0-9]{6}' | sort -ur))

  if [[ -t 0 ]]; then
    echo "   共发现 ${#SORTED_TIMESTAMPS[@]} 组完整备份"
    if [[ ${#SORTED_TIMESTAMPS[@]} -gt 0 ]]; then
      echo "   备份时间戳（从新到旧）：${SORTED_TIMESTAMPS[*]}"
    fi
  fi

  DELETED_COUNT=0
  if [[ ${#SORTED_TIMESTAMPS[@]} -gt $RETENTION_COUNT ]]; then
    DELETE_COUNT=$((${#SORTED_TIMESTAMPS[@]} - RETENTION_COUNT))
    EXPIRED_TIMESTAMPS=("${SORTED_TIMESTAMPS[@]:$RETENTION_COUNT:$DELETE_COUNT}")
    
    if [[ -t 0 ]]; then
      echo "   将保留最新 ${RETENTION_COUNT} 组，清理 ${#EXPIRED_TIMESTAMPS[@]} 组过期备份"
    fi

    for ts in "${EXPIRED_TIMESTAMPS[@]}"; do
      db_file="s-ui-db-${ts}.db"
      cfg_file="s-ui-config-${ts}.json"
      
      if [[ -t 0 ]]; then echo "   正在删除过期备份: $db_file"; fi
      if curl "${CURL_COMMON_BASE[@]}" -u "$WEBDAV_USER:$WEBDAV_PASS" -X DELETE "$WEBDAV_FULL_URL_WITH_SLASH$db_file" -o /dev/null -w "%{http_code}" 2>/dev/null | grep -qE "20[0-9]|204"; then
        DELETED_COUNT=$((DELETED_COUNT + 1))
        if [[ -t 0 ]]; then echo "   ✅ 已删除: $db_file"; fi
      fi

      if [[ -t 0 ]]; then echo "   正在删除过期备份: $cfg_file"; fi
      if curl "${CURL_COMMON_BASE[@]}" -u "$WEBDAV_USER:$WEBDAV_PASS" -X DELETE "$WEBDAV_FULL_URL_WITH_SLASH$cfg_file" -o /dev/null -w "%{http_code}" 2>/dev/null | grep -qE "20[0-9]|204"; then
        DELETED_COUNT=$((DELETED_COUNT + 1))
        if [[ -t 0 ]]; then echo "   ✅ 已删除: $cfg_file"; fi
      fi
    done
  else
    if [[ -t 0 ]]; then
      echo "   当前备份组数未超过保留限制（${#SORTED_TIMESTAMPS[@]} <= $RETENTION_COUNT），无需清理"
    fi
  fi

  unset WEBDAV_RESPONSE

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

  # 修复提示：说明优先本地备份
  echo "----------------------------------------"
  echo "【重要】备份模式选择："
  echo "  1) 本地优先模式（推荐）：如果脚本与S-UI同机，直接复制数据库文件，零API开销"
  echo "  2) API模式：通过API拉取，适合远程备份"
  read -e -i "1" -p "请选择备份模式 (1-本地优先, 2-API模式): " BACKUP_MODE
  if [[ "$BACKUP_MODE" == "2" ]]; then
    USE_LOCAL_DB_FIRST=false
    echo "   已选择API模式"
    echo "   建议排除流量统计大表以减少资源消耗"
    read -e -i "clientTraffics" -p "请输入要排除的数据库字段（留空不排除）: " DB_EXCLUDE_FIELDS
  else
    USE_LOCAL_DB_FIRST=true
    echo "   已选择本地优先模式"
    if [[ -f /usr/local/s-ui/db/s-ui.db ]]; then
      echo "   ✅ 检测到本地数据库文件"
    else
      echo "   ⚠️ 未检测到本地数据库文件，将自动回退到API模式"
    fi
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

  # 7. 备份保留份数设置
  while true; do
    read -e -i "2" -p "请输入WebDAV上保留的备份份数(默认2份): " RETENTION_COUNT
    RETENTION_COUNT=${RETENTION_COUNT:-2}
    [[ "$RETENTION_COUNT" =~ ^[1-9][0-9]*$ ]] && break
    echo "错误: 保留份数必须是正整数"
  done

  # 修复：是否备份配置JSON（默认是）
  read -e -i "y" -p "是否同时备份配置JSON文件(load API，会额外消耗资源)? (y/n): " BACKUP_JSON
  if [[ "$BACKUP_JSON" =~ ^[Yy]$ ]]; then
    BACKUP_LOAD_JSON=true
  else
    BACKUP_LOAD_JSON=false
  fi

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
# 修复新增：优先使用本地数据库文件备份，避免API拉取导致内存爆炸
USE_LOCAL_DB_FIRST=$USE_LOCAL_DB_FIRST
# 修复新增：API模式下排除的大数据表（逗号分隔）
DB_EXCLUDE_FIELDS="$DB_EXCLUDE_FIELDS"
# 修复新增：是否同时备份配置JSON（默认false，减少资源消耗）
BACKUP_LOAD_JSON=$BACKUP_LOAD_JSON
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

  # 9. 定时任务
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
  DEBUG_MODE=false
  [[ ! -f "$CONFIG_FILE" ]] && error_exit "配置文件 $CONFIG_FILE 不存在"
  source "$CONFIG_FILE"
  run_backup
else
  interactive_setup
fi
