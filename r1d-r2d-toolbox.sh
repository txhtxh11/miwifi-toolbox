#!/bin/sh
# ============================================================
#  R1D / R2D 小米路由器 一键工具箱 (menu)
#  - 自动识别 R1D / R2D / 其他小米路由
#  - Entware + nano + 开机自动挂载
#  - 内网访问后台 + SMB 监听 WAN
#  - 全盘 SMB 共享 + 屏蔽隐藏目录
#  - MIXBOX 安装 / 更新 / 卸载
#  - 状态查询 / 回滚
#
#  用法:
#    sh r1d-r2d-toolbox.sh               交互菜单
#    sh r1d-r2d-toolbox.sh status        只看状态
#    sh r1d-r2d-toolbox.sh entware       装 Entware+nano+开机挂载
#    sh r1d-r2d-toolbox.sh lan           开内网访问（防火墙+Samba WAN）
#    sh r1d-r2d-toolbox.sh smb           全盘共享 + 屏蔽隐藏目录
#    sh r1d-r2d-toolbox.sh mixbox        装 MIXBOX
#    sh r1d-r2d-toolbox.sh all           依次执行上面四步
#    sh r1d-r2d-toolbox.sh rollback      还原最近的 Samba/防火墙备份
# ============================================================

VERSION="1.0.0"
SHARE_NAME=""      # 由型号决定，如 R1D / R2D
DATA_DIR=""        # 共享路径
SMB_TPL=""         # samba 模板
SMB_CONF=""        # 生效配置
WAN_IF=""
ENTWARE_FEED=""
MODEL=""
KERNEL=""
ARCH=""

# ---------- 小工具 ----------
say()  { printf '%s\n' "$*"; }
ok()   { printf '  [OK] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*"; }
err()  { printf '  [XX] %s\n' "$*"; }
line() { printf '%s\n' "------------------------------------------------------------"; }

need_root() {
  [ "$(id -u)" = "0" ] || { err "请用 root 运行（ssh root@路由器IP）"; exit 1; }
}

confirm() {
  # $1 提示；返回 0=确认
  printf '%s [y/N]: ' "$1"
  read ans
  case "$ans" in
    y|Y|yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

remount_rw() {
  # 根目录解锁写保护（R1D/R2D 默认只读）
  if mount | grep -q '^/dev/root on / type'; then
    :
  fi
  mount -rw -o remount / 2>/dev/null || true
  # 验证
  if touch /etc/.write_test 2>/dev/null; then
    rm -f /etc/.write_test
    ok "根目录可写"
  else
    warn "根目录仍只读（可能已是 rw，或需要先 mount -rw -o remount /）"
  fi
}

backup_file() {
  [ -f "$1" ] || return 0
  ts=$(date +%s)
  cp "$1" "$1.bak.$ts" 2>/dev/null && say "  备份: $1.bak.$ts"
}

# ---------- 型号 / 环境识别 ----------
detect_env() {
  MODEL=$(nvram get model 2>/dev/null | tr -d '\r')
  [ -z "$MODEL" ] && MODEL=$(nvram get productname 2>/dev/null | tr -d '\r')
  [ -z "$MODEL" ] && MODEL=$(cat /proc/mi_modules/mi_sysinfo 2>/dev/null | sed -n 's/.*model[^:]*:[[:space:]]*//p' | head -n1)
  [ -z "$MODEL" ] && MODEL="UNKNOWN"

  KERNEL=$(uname -r)
  ARCH=$(uname -m)

  case "$MODEL" in
    *R1D*|*r1d*) MODEL="R1D" ;;
    *R2D*|*r2d*) MODEL="R2D" ;;
    *R3D*|*r3d*) MODEL="R3D" ;;
    *R3*|*r3*)   MODEL="R3"  ;;
    *) : ;;
  esac
  SHARE_NAME=$(printf '%s' "$MODEL" | tr -d ' ' | tr 'a-z' 'A-Z')
  [ -z "$SHARE_NAME" ] && SHARE_NAME="R1D"

  # 数据目录
  if [ -d /userdisk/data ]; then
    DATA_DIR="/userdisk/data"
  elif [ -d /userdisk ]; then
    DATA_DIR="/userdisk"
  elif [ -d /extdisks/sda1 ]; then
    DATA_DIR="/extdisks/sda1"
  else
    DATA_DIR=""
  fi

  # Samba 配置
  SMB_TPL=""
  [ -f /etc/samba/smb.conf.template ] && SMB_TPL="/etc/samba/smb.conf.template"
  if [ -f /var/etc/smb.conf ]; then
    SMB_CONF="/var/etc/smb.conf"
  elif [ -f /etc/samba/smb.conf ]; then
    SMB_CONF="/etc/samba/smb.conf"
  fi

  # WAN 接口
  WAN_IF=$(uci get network.wan.ifname 2>/dev/null)
  [ -z "$WAN_IF" ] && WAN_IF=$(uci get network.wan.device 2>/dev/null)
  [ -z "$WAN_IF" ] && WAN_IF="eth0.2"

  # WAN 防火墙 zone 索引（R1D/R2D 一般都是 1，但按名字查找更稳）
  WAN_ZONE=""
  i=0
  while [ $i -lt 10 ]; do
    zname=$(uci -q get firewall.@zone[$i].name 2>/dev/null)
    [ -z "$zname" ] && break
    if [ "$zname" = "wan" ]; then WAN_ZONE=$i; break; fi
    i=$((i + 1))
  done
  [ -z "$WAN_ZONE" ] && WAN_ZONE=1

  # MIXBOX 安装位置（硬盘优先）
  MB_ROOT=""
  MB_DATA=""
  if [ -d /userdisk ]; then
    MB_ROOT="/userdisk"; MB_DATA="/userdisk/data"
  elif [ -d /extdisks/sda1 ]; then
    MB_ROOT="/extdisks/sda1"; MB_DATA="/extdisks/sda1"
  fi

  # Entware feed
  case "$ARCH" in
    armv7l|armv7*)
      case "$KERNEL" in
        2.6*) ENTWARE_FEED="armv7sf-k2.6" ;;
        3.*|4.*|5.*) ENTWARE_FEED="armv7sf-k3.2" ;;
        *) ENTWARE_FEED="armv7sf-k2.6" ;;
      esac ;;
    aarch64|arm64) ENTWARE_FEED="aarch64-k3.10" ;;
    mips*) ENTWARE_FEED="mipselsf-k3.4" ;;
    x86_64) ENTWARE_FEED="x64-k3.2" ;;
    *) ENTWARE_FEED="" ;;
  esac
}

# ---------- 状态查询 ----------
show_status() {
  detect_env
  line
  say "  设备状态  $MODEL    (工具版本 $VERSION)"
  line
  say "  型号      : $MODEL"
  say "  架构/内核 : $ARCH / $KERNEL"
  say "  固件      : $(grep -h DISTRIB_DESCRIPTION /etc/openwrt_release 2>/dev/null | cut -d'"' -f2)"
  say "  数据目录  : ${DATA_DIR:-未找到}"
  say "  WAN 接口  : $WAN_IF"
  say "  Entware源 : ${ENTWARE_FEED:-不支持的架构}"
  say ""

  # 根目录
  if touch /etc/.wtest 2>/dev/null; then rm -f /etc/.wtest; ok "根目录可写"; else warn "根目录只读（功能3需要先解锁）"; fi

  # /opt
  if mount | grep -q ' on /opt '; then
    ok "/opt 已挂载 ($(df -h /opt 2>/dev/null | tail -1 | awk '{print $2" 总/"$4" 可用"}'))"
  else
    warn "/opt 未挂载"
  fi

  # Entware / opkg / nano
  if [ -x /opt/bin/opkg ]; then ok "opkg 已安装"; else warn "opkg 未安装"; fi
  if [ -x /opt/bin/nano ]; then
    ok "nano 已安装 ($(/opt/bin/nano --version 2>/dev/null | head -n1))"
  else
    warn "nano 未安装"
  fi
  if echo "$PATH" | grep -q '/opt/bin' || grep -q '^export PATH=/opt/bin' /etc/profile 2>/dev/null; then
    ok "PATH 已配置 (/opt/bin)"
  else
    warn "PATH 未配置 /opt/bin"
  fi

  # 开机挂载
  if [ -f /etc/rc.local ] && grep -q 'mount -o bind /userdisk/opt /opt' /etc/rc.local 2>/dev/null; then
    ok "开机自动挂载已配置"
  else
    warn "开机自动挂载未配置"
  fi

  # 防火墙
  fw=$(uci get firewall.@zone[$WAN_ZONE].input 2>/dev/null)
  if [ "$fw" = "ACCEPT" ]; then ok "WAN 防火墙已放行 (zone[$WAN_ZONE].input=ACCEPT)"; else warn "WAN 防火墙未放行 (当前: ${fw:-未知})"; fi

  # Samba 监听
  if [ -n "$SMB_TPL" ] && grep -q "interfaces *= *br-lan.*$WAN_IF" "$SMB_TPL" 2>/dev/null; then
    ok "Samba 模板已监听 WAN ($WAN_IF)"
  else
    warn "Samba 未监听 WAN"
  fi
  if netstat -lntp 2>/dev/null | grep -q ':445'; then
    ok "445 端口监听: $(netstat -lntp 2>/dev/null | grep ':445' | awk '{print $4}' | tr '\n' ' ')"
  else
    warn "445 端口未监听"
  fi

  # 共享
  if [ -n "$SMB_CONF" ] && grep -q "^\[$SHARE_NAME\]" "$SMB_CONF" 2>/dev/null; then
    ok "共享 [$SHARE_NAME] 已存在"
    if grep -A8 "^\[$SHARE_NAME\]" "$SMB_CONF" 2>/dev/null | grep -q 'veto files'; then
      ok "隐藏目录已屏蔽 (veto)"
    else
      warn "隐藏目录未屏蔽"
    fi
  else
    warn "共享 [$SHARE_NAME] 不存在"
  fi

  # 免登录白名单（小米自带共享的 MAC 白名单）
  WL="/userdisk/datacenterConfig/nonLoginMac.cfg"
  if [ -f "$WL" ]; then
    n=$(grep -c ':' "$WL" 2>/dev/null)
    ok "免登录白名单: ${n:-0} 个 MAC"
  else
    warn "免登录白名单文件不存在"
  fi

  # MIXBOX
  if [ -n "$MB_ROOT" ] && { [ -d "$MB_ROOT/mixbox" ] || [ -L /etc/mixbox ]; }; then
    ver=$("$MB_ROOT/mixbox/bin/mbdb" get mixbox.main.version 2>/dev/null)
    [ -z "$ver" ] && ver=$(grep '^version=' "$MB_ROOT/mixbox/config/mixbox.uci" 2>/dev/null | cut -d= -f2)
    ok "MIXBOX 已安装 (${ver:-未知版本}) @ $MB_ROOT/mixbox"
  else
    warn "MIXBOX 未安装"
  fi

  # 空间
  say ""
  say "  磁盘空间:"
  df -h 2>/dev/null | grep -E 'Filesystem|/userdisk|/opt|/extdisks' | sed 's/^/    /'
  line
}

# ---------- 1. Entware + nano + 开机挂载 ----------
# 只做 PATH 与开机挂载（幂等，可单独调用）
ensure_path_and_rc() {
  remount_rw

  # PATH
  if ! grep -q '^export PATH=/opt/bin' /etc/profile 2>/dev/null; then
    backup_file /etc/profile
    sed -i 's#^export PATH=.*#export PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin#' /etc/profile
    grep -q '^export PATH=/opt/bin' /etc/profile && ok "PATH 已更新" || warn "PATH 更新失败，请手动检查 /etc/profile"
  else
    ok "PATH 已含 /opt/bin"
  fi

  # 开机挂载
  if [ -f /etc/rc.local ] && grep -q 'mount -o bind /userdisk/opt /opt' /etc/rc.local 2>/dev/null; then
    ok "开机自动挂载已配置"
  else
    say "  写入 /etc/rc.local 开机挂载..."
    [ -f /etc/rc.local ] || { printf '#!/bin/sh\n\nexit 0\n' > /etc/rc.local; chmod +x /etc/rc.local; }
    backup_file /etc/rc.local
    if grep -q '^exit 0$' /etc/rc.local 2>/dev/null; then
      awk '
        /^mount -o bind \/userdisk\/opt \/opt$/ {done=1}
        /^exit 0$/ && !done { print "mount -o bind /userdisk/opt /opt"; print "/opt/etc/init.d/rc.unslung start"; done=1 }
        {print}
      ' /etc/rc.local > /etc/rc.local.new && mv /etc/rc.local.new /etc/rc.local
    else
      printf '\nmount -o bind /userdisk/opt /opt\n/opt/etc/init.d/rc.unslung start\nexit 0\n' >> /etc/rc.local
    fi
    chmod +x /etc/rc.local
    ok "开机自动挂载已写入"
  fi

  PATH=/opt/bin:/opt/sbin:$PATH
  export PATH
}

do_entware() {
  detect_env
  line
  say "  步骤 1/4  Entware + nano + 开机自动挂载"
  line
  [ -z "$ENTWARE_FEED" ] && { err "不支持的架构 $ARCH"; return 1; }

  if [ -x /opt/bin/opkg ] && [ -x /opt/bin/nano ]; then
    ok "Entware + nano 已安装，只检查 PATH 和开机挂载"
    ensure_path_and_rc
    return 0
  fi
  confirm "将安装 Entware($ENTWARE_FEED) + nano，继续?" || return 1

  remount_rw

  # /opt 挂到硬盘
  if ! mount | grep -q ' on /opt '; then
    mkdir -p /userdisk/opt
    mount -o bind /userdisk/opt /opt 2>/dev/null || mount --bind /userdisk/opt /opt
    ok "/opt -> /userdisk/opt 已挂载"
  else
    ok "/opt 已挂载"
  fi

  # 安装 Entware
  if [ ! -x /opt/bin/opkg ]; then
    cd /userdisk || { err "无法进入 /userdisk"; return 1; }
    say "  下载 Entware 安装脚本 ($ENTWARE_FEED)..."
    rm -f generic.sh
    wget -q -O generic.sh "http://bin.entware.net/$ENTWARE_FEED/installer/generic.sh" 2>/dev/null
    if [ ! -s generic.sh ]; then
      warn "官方源失败，尝试北外镜像..."
      wget -q -O generic.sh "https://mirrors.bfsu.edu.cn/entware/$ENTWARE_FEED/installer/generic.sh" 2>/dev/null
    fi
    if [ ! -s generic.sh ]; then
      err "下载失败（检查 DNS/网络），可手动下载后重跑"
      return 1
    fi
    chmod +x generic.sh
    ./generic.sh || { err "Entware 安装脚本执行失败"; return 1; }
    ok "Entware 安装完成"
  else
    ok "opkg 已存在，跳过 Entware 安装"
  fi

  # opkg update + nano
  /opt/bin/opkg update >/dev/null 2>&1 && ok "opkg update 完成" || warn "opkg update 失败（可忽略，稍后手动重试）"
  if [ ! -x /opt/bin/nano ]; then
    /opt/bin/opkg install nano >/dev/null 2>&1 && ok "nano 安装完成" || { err "nano 安装失败"; return 1; }
  else
    ok "nano 已存在"
  fi

  ensure_path_and_rc

  say ""
  say "  验证:"
  say "    /opt/bin/nano --version"
  say "    opkg update"
}

# ---------- 2. 内网访问（防火墙 + Samba WAN） ----------
do_lan_access() {
  detect_env
  line
  say "  步骤 2/4  内网访问后台 + Samba 监听 WAN"
  line
  confirm "将放行 WAN 防火墙并把 Samba 监听 WAN($WAN_IF)，继续?" || return 1

  remount_rw
  backup_file /etc/config/firewall

  uci set firewall.@zone[$WAN_ZONE].input='ACCEPT' 2>/dev/null
  uci commit firewall 2>/dev/null
  /etc/init.d/firewall restart >/dev/null 2>&1 && ok "防火墙已放行 WAN" || warn "防火墙重启失败"

  if [ -n "$SMB_TPL" ]; then
    backup_file "$SMB_TPL"
    sed -i "s|^[[:space:]]*interfaces[[:space:]]*=.*|	interfaces = br-lan $WAN_IF|" "$SMB_TPL"
    ok "Samba 模板已改为 br-lan $WAN_IF"
  else
    warn "未找到 smb.conf.template，跳过 Samba WAN 配置"
  fi

  /etc/init.d/samba restart >/dev/null 2>&1 && ok "Samba 已重启" || warn "Samba 重启失败"
  sleep 2
  say ""
  say "  445 监听:"
  netstat -lntp 2>/dev/null | grep ':445' | sed 's/^/    /'
  say ""
  wan_ip=$(uci get network.wan.ipaddr 2>/dev/null)
  [ -z "$wan_ip" ] && wan_ip="<WAN_IP>"
  say "  验证: 浏览器 http://$wan_ip"
  say "        Windows \\\\$wan_ip\\共享"
}

# ---------- 3. 全盘共享 + 屏蔽隐藏目录 ----------
do_smb_share() {
  detect_env
  line
  say "  步骤 3/4  全盘共享 [$SHARE_NAME] + 屏蔽隐藏目录"
  line
  [ -z "$DATA_DIR" ] && { err "找不到数据目录（/userdisk/data 或 /userdisk）"; return 1; }
  [ -z "$SMB_CONF" ] && { err "找不到 samba 配置文件"; return 1; }
  say "  共享名: [$SHARE_NAME]   路径: $DATA_DIR"
  confirm "继续?" || return 1

  remount_rw
  backup_file "$SMB_CONF"
  [ -n "$SMB_TPL" ] && backup_file "$SMB_TPL"

  # 已有同名段则跳过添加
  if grep -q "^\[$SHARE_NAME\]" "$SMB_CONF" 2>/dev/null; then
    ok "共享 [$SHARE_NAME] 已存在，跳过创建"
  else
    for f in "$SMB_CONF" "$SMB_TPL"; do
      [ -n "$f" ] || continue
      [ -f "$f" ] || continue
      grep -q "^\[$SHARE_NAME\]" "$f" 2>/dev/null && continue
      cat >> "$f" <<EOF

[$SHARE_NAME]
	path = $DATA_DIR
	read only = no
	guest ok = yes
	create mask = 0777
	directory mask = 0777
	force user = root
	browseable = yes
EOF
    done
    ok "共享 [$SHARE_NAME] 已添加"
  fi

  # veto 隐藏目录
  for f in "$SMB_CONF" "$SMB_TPL"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    grep -q 'veto files = /.filetransfer_tmp/' "$f" 2>/dev/null && continue
    awk -v sec="[$SHARE_NAME]" '
      $0 == sec { print; print "\tveto files = /.filetransfer_tmp/.systemconfig/.upload_tmp/"; print "\tdelete veto files = yes"; print "\thide dot files = yes"; next }
      { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
  ok "隐藏目录已屏蔽 (.filetransfer_tmp / .systemconfig / .upload_tmp)"

  /etc/init.d/samba restart >/dev/null 2>&1 && ok "Samba 已重启" || warn "Samba 重启失败"
  sleep 2
  say ""
  say "  验证: testparm -s | grep -A10 '\\[$SHARE_NAME\\]'"
  say "        Windows: \\\\<WAN_IP>\\$SHARE_NAME"
}

# ---------- 4. MIXBOX ----------
MIXBOX_URL="https://gcore.jsdelivr.net/gh/monlor/mbfiles"

# ---------- 免登录白名单（小米自带共享用） ----------
do_whitelist() {
  detect_env
  line
  say "  添加本机 MAC 到免登录白名单"
  line
  WL="/userdisk/datacenterConfig/nonLoginMac.cfg"
  if [ ! -f "$WL" ]; then
    err "找不到 $WL（非小米路由或固件不同）"
    return 1
  fi

  client_ip=$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $1}')
  [ -z "$client_ip" ] && client_ip=$(printf '%s' "${SSH_CLIENT:-}" | awk '{print $1}')
  mac=""
  if [ -n "$client_ip" ]; then
    mac=$(awk -v ip="$client_ip" '$1==ip {print $4}' /proc/net/arp 2>/dev/null | head -n1)
    [ -n "$mac" ] && say "  SSH 来源: $client_ip"
  fi
  if [ -z "$mac" ]; then
    say "  无法自动识别 MAC，请手动输入（格式 42:95:91:f6:f4:08）:"
    printf '  MAC: '
    read mac
  fi
  mac=$(printf '%s' "$mac" | tr 'A-Z' 'a-z')
  case "$mac" in
    [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) : ;;
    *) err "MAC 格式不对: $mac"; return 1 ;;
  esac

  if grep -qi "$mac" "$WL" 2>/dev/null; then
    ok "已在白名单: $mac"
    return 0
  fi
  confirm "把 $mac 加入免登录白名单?" || return 1
  backup_file "$WL"
  printf '%s\n' "$mac" >> "$WL"
  ok "已添加: $mac"
  /etc/init.d/samba restart >/dev/null 2>&1 && ok "Samba 已重启"
  say "  提示: 小米自带共享（如 XiaoMi/共享）现在对本机免登录可写"
}

do_mixbox_install() {
  detect_env
  line
  say "  步骤 4/4  安装 MIXBOX"
  line
  if [ -z "$MB_ROOT" ]; then
    err "找不到可写的硬盘目录（/userdisk 或 /extdisks/sda1），无法安装"
    return 1
  fi
  if [ -d "$MB_ROOT/mixbox" ] || [ -L /etc/mixbox ]; then
    ok "MIXBOX 已安装，跳过（需要重装请先卸载）"
    return 0
  fi
  confirm "从 $MIXBOX_URL 安装 MIXBOX 到 $MB_ROOT，继续?" || return 1
  say "  下载并安装（安装位置 $MB_ROOT，用户目录 $MB_DATA）..."
  if printf '\n%s\n%s\n' "$MB_ROOT" "$MB_DATA" | sh -c "$(curl -kfsSl $MIXBOX_URL/install.sh)" >/tmp/mixbox_install.log 2>&1; then
    if [ -d "$MB_ROOT/mixbox" ]; then
      ok "MIXBOX 安装完成 @ $MB_ROOT/mixbox"
      say "  用法: 重新登录 SSH 后执行 mixbox"
    else
      err "安装脚本执行了但目录不存在，查看 /tmp/mixbox_install.log"
      tail -n 15 /tmp/mixbox_install.log | sed 's/^/    /'
      return 1
    fi
  else
    err "安装脚本失败，日志:"
    tail -n 15 /tmp/mixbox_install.log | sed 's/^/    /'
    return 1
  fi
}

do_mixbox_update() {
  line
  say "  更新 MIXBOX"
  line
  sh -c "$(curl -kfsSl $MIXBOX_URL/update.sh)" && source /etc/profile 2>/dev/null
  ok "更新完成"
}

do_mixbox_uninstall() {
  line
  say "  卸载 MIXBOX"
  line
  confirm "确认卸载 MIXBOX（/etc/mixbox 与 /userdisk/mixbox）?" || return 1
  sh -c "$(curl -kfsSl https://gcore.jsdelivr.net/gh/monlor/MIXBOX/apps/mixbox/scripts/uninstall.sh)"
  ok "卸载完成"
}

# ---------- 回滚 ----------
do_rollback() {
  detect_env
  line
  say "  回滚（恢复最近的备份）"
  line
  say "  可用备份:"
  ls -t /etc/config/firewall.bak.* 2>/dev/null | head -3 | sed 's/^/    /'
  ls -t /var/etc/smb.conf.bak.* 2>/dev/null | head -3 | sed 's/^/    /'
  ls -t /etc/samba/smb.conf.template.bak.* 2>/dev/null | head -3 | sed 's/^/    /'
  confirm "恢复最新备份并重启防火墙/Samba?" || return 1

  last_fw=$(ls -t /etc/config/firewall.bak.* 2>/dev/null | head -n1)
  [ -n "$last_fw" ] && cp "$last_fw" /etc/config/firewall && ok "防火墙已还原: $last_fw"

  last_smb=$(ls -t /var/etc/smb.conf.bak.* 2>/dev/null | head -n1)
  [ -n "$last_smb" ] && cp "$last_smb" "$SMB_CONF" && ok "Samba 已还原: $last_smb"

  last_tpl=$(ls -t /etc/samba/smb.conf.template.bak.* 2>/dev/null | head -n1)
  [ -n "$last_tpl" ] && cp "$last_tpl" /etc/samba/smb.conf.template && ok "模板已还原: $last_tpl"

  /etc/init.d/firewall restart >/dev/null 2>&1
  /etc/init.d/samba restart >/dev/null 2>&1
  ok "服务已重启"
}

# ---------- 一键全部 ----------
do_all() {
  detect_env
  line
  say "  一键执行: $MODEL"
  line
  confirm "将依次执行 1)Entware 2)内网访问 3)全盘共享 4)MIXBOX，继续?" || return 1
  do_entware
  do_lan_access
  do_smb_share
  do_mixbox_install
  line
  say "  全部完成，最终状态:"
  show_status
}

# ---------- 菜单 ----------
menu() {
  detect_env
  while :; do
    printf '\n'
    line
    printf '  %s 工具箱  v%s\n' "$MODEL" "$VERSION"
    line
    printf '  1) 状态查询\n'
    printf '  2) 安装 Entware + nano + 开机挂载\n'
    printf '  3) 内网访问（防火墙 + Samba WAN）\n'
    printf '  4) 全盘共享 + 屏蔽隐藏目录\n'
    printf '  5) 安装 MIXBOX\n'
    printf '  6) 更新 MIXBOX\n'
    printf '  7) 卸载 MIXBOX\n'
    printf '  8) 一键全部（2+3+4+5）\n'
    printf '  9) 回滚（恢复备份）\n'
    printf ' 10) 添加本机 MAC 到免登录白名单\n'
    printf '  0) 退出\n'
    line
    printf '  请选择: '
    read choice
    case "$choice" in
      1) show_status ;;
      2) do_entware ;;
      3) do_lan_access ;;
      4) do_smb_share ;;
      5) do_mixbox_install ;;
      6) do_mixbox_update ;;
      7) do_mixbox_uninstall ;;
      8) do_all ;;
      9) do_rollback ;;
      10) do_whitelist ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

# ---------- 入口 ----------
need_root
detect_env

case "${1:-}" in
  status)          show_status ;;
  entware)         do_entware ;;
  lan)             do_lan_access ;;
  smb)             do_smb_share ;;
  mixbox)          do_mixbox_install ;;
  mixbox-update)   do_mixbox_update ;;
  mixbox-uninstall)do_mixbox_uninstall ;;
  all)             do_all ;;
  rollback)        do_rollback ;;
  whitelist)       do_whitelist ;;
  "" )             menu ;;
  *) say "用法: $0 {status|entware|lan|smb|mixbox|mixbox-update|mixbox-uninstall|all|rollback|whitelist}"; exit 1 ;;
esac
