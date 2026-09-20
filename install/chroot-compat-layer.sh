#!/system/bin/sh
R=/data/openeuler
mkdir -p $R/usr/local/sbin $R/usr/local/bin $R/var/log

echo "########## 1) iptables 走 legacy（内核不支持 nf_tables）##########"
for t in iptables ip6tables; do
  cat > $R/usr/local/sbin/$t <<EOF
#!/bin/sh
# 茉莉定制：本内核(4.9)不支持 nf_tables，iptables 统一走 legacy 表
exec /usr/sbin/${t}-legacy "\$@"
EOF
  chmod 755 $R/usr/local/sbin/$t
done
ls -l $R/usr/local/sbin/iptables $R/usr/local/sbin/ip6tables

echo "########## 2) systemctl 兼容层 -> /etc/init.d ##########"
cat > $R/usr/local/sbin/systemctl <<'EOS'
#!/bin/sh
# 茉莉定制：chroot 里的 systemctl 兼容层
# 把 systemctl 的常用动作映射到 /etc/init.d/<服务>，让宝塔面板在无 systemd 的 chroot 里也能启停服务
VERB=""; UNITS=""
for a in "$@"; do
    case "$a" in
        -*) ;;
        daemon-reload|daemon-reexec|reset-failed|mask|unmask)
            case "$VERB" in
                "") VERB="$a" ;;
            esac ;;
        *)
            if [ -z "$VERB" ]; then VERB="$a"; else UNITS="$UNITS $a"; fi ;;
    esac
done
[ -z "$VERB" ] && { echo "systemctl(shim): 缺少动作"; exit 1; }

name_of(){ echo "$1" | sed 's/\.service$//'; }

rc_dir_make(){ mkdir -p /etc/rc.d/rc2.d /etc/rc.d/rc3.d /etc/rc.d/rc4.d /etc/rc.d/rc5.d 2>/dev/null; }

case "$VERB" in
    daemon-reload|daemon-reexec|reset-failed|unmask) exit 0 ;;
    mask) exit 0 ;;
    list-units|list-unit-files)
        for s in /etc/init.d/*; do [ -x "$s" ] && basename "$s"; done
        exit 0 ;;
    is-enabled)
        s=$(name_of "$1")
        [ -x "/etc/init.d/$s" ] && { echo enabled; exit 0; }
        echo disabled; exit 1 ;;
    is-active)
        s=$(name_of "$1")
        if [ -x "/etc/init.d/$s" ] && "/etc/init.d/$s" status >/dev/null 2>&1; then echo active; exit 0; fi
        echo inactive; exit 3 ;;
    enable|disable)
        rc_dir_make
        for u in $UNITS; do
            s=$(name_of "$u")
            if [ "$VERB" = "enable" ]; then
                for d in 2 3 4 5; do ln -sf "/etc/init.d/$s" "/etc/rc.d/rc$d.d/S99$s"; done
                [ -x "/etc/init.d/$s" ] && (grep -q "^chkconfig" "/etc/init.d/$s" 2>/dev/null; chkconfig --add "$s" 2>/dev/null)
            else
                for d in 2 3 4 5; do rm -f "/etc/rc.d/rc$d.d/S99$s"; done
                chkconfig --del "$s" 2>/dev/null
            fi
        done
        exit 0 ;;
    status)
        s=$(name_of "$1")
        if [ -x "/etc/init.d/$s" ]; then
            out=$("/etc/init.d/$s" status 2>&1); rc=$?
            echo "● $s.service - $s (茉莉 chroot)"
            echo "     Loaded: loaded (/etc/init.d/$s; enabled)"
            if [ $rc -eq 0 ]; then echo "     Active: active (running)"; else echo "     Active: inactive (dead)"; fi
            [ -n "$out" ] && echo "$out"
            exit $rc
        fi
        echo "$s.service could not be found."; exit 4 ;;
    start|stop|restart|reload|reload-or-restart|try-restart|force-reload|condrestart)
        rc=0
        for u in $UNITS; do
            s=$(name_of "$u")
            if [ ! -x "/etc/init.d/$s" ]; then echo "Failed to $VERB $s.service: Unit $s.service not found."; rc=5; continue; fi
            v="$VERB"
            case "$VERB" in reload|reload-or-restart|force-reload) v="reload";; condrestart|try-restart) v="restart";; esac
            "/etc/init.d/$s" "$v" || rc=$?
        done
        exit $rc ;;
    *) echo "systemctl(shim): 未支持的动作 $VERB"; exit 1 ;;
esac
EOS
chmod 755 $R/usr/local/sbin/systemctl

echo "########## 3) service 兼容层 ##########"
cat > $R/usr/local/sbin/service <<'EOS'
#!/bin/sh
# 茉莉定制：service <name> <verb> -> /etc/init.d/<name> <verb>
s=$1; v=$2; shift 2 2>/dev/null
[ -z "$v" ] && v=status
if [ -x "/etc/init.d/$s" ]; then exec "/etc/init.d/$s" "$v"; fi
echo "service(shim): $s: 未找到服务"; exit 1
EOS
chmod 755 $R/usr/local/sbin/service

echo "########## 4) start-stop-daemon 兼容层（Debian 风格 init 脚本用）##########"
cat > $R/usr/local/sbin/start-stop-daemon <<'EOS'
#!/bin/sh
# 茉莉定制：极简 start-stop-daemon，支持 --start/--stop/--pidfile/--exec/--chuid/--background/--make-pidfile/--name/--quiet
MODE=""; EXEC=""; PIDFILE=""; NAME=""; BACKGROUND=0; MAKEPID=0; CHUID=""; ARGS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --start) MODE=start;;
    --stop) MODE=stop;;
    --status) MODE=status;;
    --exec) EXEC="$2"; shift;;
    --pidfile) PIDFILE="$2"; shift;;
    --name) NAME="$2"; shift;;
    --chuid|--user) CHUID="$2"; shift;;
    --background) BACKGROUND=1;;
    --make-pidfile) MAKEPID=1;;
    --quiet|-q|--oknodo|-o|--retry|--verbose|-v|--signal|--startas|--chdir|--umask|--nicelevel|--remove-pidfile|--no-close) [ "$1" = "--chdir" -o "$1" = "--signal" -o "$1" = "--startas" ] && shift;;
    --) shift; ARGS="$*"; break;;
    *) ;;
  esac
  shift
done
target=""
[ -n "$PIDFILE" ] && [ -f "$PIDFILE" ] && target=$(cat "$PIDFILE" 2>/dev/null)
[ -z "$target" ] && [ -n "$NAME" ] && target=$(pidof "$NAME" 2>/dev/null)
case "$MODE" in
  status) [ -n "$target" ] && exit 0 || exit 1;;
  stop)
    if [ -z "$target" ]; then exit 0; fi
    kill $target 2>/dev/null; sleep 1; kill -9 $target 2>/dev/null
    [ -n "$PIDFILE" ] && rm -f "$PIDFILE"
    exit 0;;
  start)
    if [ -n "$target" ] && kill -0 $target 2>/dev/null; then exit 0; fi
    if [ "$BACKGROUND" = "1" ]; then
      set -- $EXEC $ARGS
      if [ "$MAKEPID" = "1" ] && [ -n "$PIDFILE" ]; then
        setsid "$@" >/dev/null 2>&1 < /dev/null &
        echo $! > "$PIDFILE"
      else
        setsid "$@" >/dev/null 2>&1 < /dev/null &
      fi
    else
      exec "$EXEC" $ARGS
    fi
    exit 0;;
  *) echo "start-stop-daemon(shim): 缺少 --start/--stop/--status"; exit 1;;
esac
EOS
chmod 755 $R/usr/local/sbin/start-stop-daemon

echo "########## 5) fail2ban SysV 启动脚本（替换 Debian 版）##########"
if [ -f $R/etc/init.d/fail2ban ] && [ ! -f $R/etc/init.d/fail2ban.debian-orig ]; then
  cp -f $R/etc/init.d/fail2ban $R/etc/init.d/fail2ban.debian-orig
  echo "原 Debian 版已备份 -> /etc/init.d/fail2ban.debian-orig"
fi
cat > $R/etc/init.d/fail2ban <<'EOS'
#!/bin/sh
# 茉莉定制：fail2ban SysV 启动脚本（openEuler/chroot 版）
# chkconfig: 2345 90 10
# description: fail2ban 入侵防御
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BIN=/www/server/panel/pyenv/bin/fail2ban-server
CLIENT=/www/server/panel/pyenv/bin/fail2ban-client
CFG=/etc/fail2ban
PID=/www/server/panel/plugin/fail2ban/fail2ban.pid
SOCK=/www/server/panel/plugin/fail2ban/fail2ban.sock
[ -x "$BIN" ] || BIN=/usr/bin/fail2ban-server
[ -x "$CLIENT" ] || CLIENT=/usr/bin/fail2ban-client

running(){
  [ -f "$PID" ] && kill -0 "$(cat $PID 2>/dev/null)" 2>/dev/null && return 0
  pgrep -f "fail2ban-server" >/dev/null 2>&1 && return 0
  return 1
}
start(){
  mkdir -p /var/run/fail2ban /var/lib/fail2ban /var/log
  if running; then echo "fail2ban 已在运行"; return 0; fi
  "$BIN" -c "$CFG" -x || return 1
  sleep 2
  running && echo "fail2ban 启动完成" || { echo "fail2ban 启动失败"; return 1; }
}
stop(){
  if [ -x "$CLIENT" ]; then "$CLIENT" -c "$CFG" stop >/dev/null 2>&1; fi
  sleep 1
  if running; then
    p=$(cat "$PID" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null; sleep 1
    pkill -f "fail2ban-server" 2>/dev/null
  fi
  rm -f "$SOCK" "$PID"
  echo "fail2ban 已停止"
  return 0
}
case "$1" in
  start) start;;
  stop) stop;;
  restart|force-reload) stop; sleep 1; start;;
  reload) [ -x "$CLIENT" ] && "$CLIENT" -c "$CFG" reload;;
  status) if running; then echo "fail2ban 正在运行"; exit 0; else echo "fail2ban 未运行"; exit 3; fi;;
  *) echo "用法: $0 {start|stop|restart|reload|status}"; exit 1;;
esac
EOS
chmod 755 $R/etc/init.d/fail2ban

echo "########## 6) jail.local 改用 iptables（本内核无 ipset/nf_tables）##########"
J=$R/etc/fail2ban/jail.local
if [ -f "$J" ] && [ ! -f "$J.moli-orig" ]; then cp -f "$J" "$J.moli-orig"; fi
sed -i 's/^banaction *=.*/banaction = iptables-multiport/' "$J"
sed -i 's/^action *= *%(action_mwl)s/action = %(action_)s/' "$J"
grep -nE "^(banaction|action)" "$J"
echo "CFG_LAYER_END"
