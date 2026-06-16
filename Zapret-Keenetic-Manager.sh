#!/bin/sh
# ==========================================================================
# Zapret Manager for Entware/Keenetic (aarch64)
# Based on bol-van/zapret. Inspired by Zapret-Manager by StressOzz (OpenWrt/remittor).
# ==========================================================================
ZKM_VERSION="2.0"

GREEN="\033[1;32m"; RED="\033[1;31m"; CYAN="\033[1;36m"; YELLOW="\033[1;33m"; MAGENTA="\033[1;35m"; NC="\033[0m"; DGRAY="\033[38;5;244m"; BLUE="\033[0;34m"

# ---- paths -----------------------------------------------------------------
ENTWARE_ROOT="/opt"
ZAPRET_DIR="$ENTWARE_ROOT/zapret"
ZAPRET_CONF="$ZAPRET_DIR/config"
INIT_SRC="$ZAPRET_DIR/init.d/sysv/zapret"
INIT_LINK="$ENTWARE_ROOT/etc/init.d/S52zapret"
IPSET_DIR="$ZAPRET_DIR/ipset"
FAKE_DIR="$ZAPRET_DIR/files/fake"

HOSTLIST_USER="$IPSET_DIR/zapret-hosts-user.txt"
HOSTLIST_EXCLUDE="$IPSET_DIR/zapret-hosts-user-exclude.txt"
HOSTLIST_AUTO="$IPSET_DIR/zapret-hosts-auto.txt"
HOSTLIST_GOOGLE="$IPSET_DIR/zapret-hosts-google.txt"

# Менеджер хранит свои данные отдельно от /opt/zapret, чтобы переустановка/обновление zapret их не затронула
ZKM_DIR="$ENTWARE_ROOT/zapret_manager"
ZKM_TMP="/tmp/zapret_manager_tmp"
BACKUP_DIR="$ENTWARE_ROOT/zapret_backup"
RKN_BACKUP_FILE="$ZKM_DIR/hosts_user_backup_before_rkn.txt"
RKN_HOSTLIST_URL="https://raw.githubusercontent.com/IndeecFOX/zapret4rocket/refs/heads/master/extra_strats/TCP/RKN/List.txt"
FLOWSEAL_REPO_ZIP="https://github.com/Flowseal/zapret-discord-youtube/archive/refs/heads/main.zip"
FLOWSEAL_STRATEGIES_CACHE="$ZKM_DIR/flowseal_strategies.txt"
EXCLUDE_LIST_URL="https://raw.githubusercontent.com/StressOzz/Zapret-Manager/refs/heads/main/zapret-hosts-user-exclude.txt"
ETC_HOSTS="/etc/hosts"
STATE_FILE="$ZKM_DIR/state"

REPO_OWNER="bol-van"
REPO_NAME="zapret"
REPO_URL="https://github.com/$REPO_OWNER/$REPO_NAME"
REPO_TARBALL="$REPO_URL/archive/refs/heads/master.tar.gz"
REPO_API_LATEST="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"

REQUIRED_PKGS="coreutils-sort curl grep gzip tar unzip ipset iptables ip6tables kmod-ipt-nat kmod-ipt-conntrack kmod-ip6table-nat kmod-ip6table-filter kmod-ipt-filter kmod-ipt-nfqueue kmod-nf-conntrack kmod-nf-conntrack6"

PORTS_TCP_DEFAULT="80,443"
PORTS_UDP_DEFAULT="443"
DISCORD_UDP_PORTS="19294-19344,50000-50100"
DISCORD_TCP_PORTS="2053,2083,2087,2096,8443"

mkdir -p "$ZKM_DIR" 2>/dev/null

# ---- helpers -----------------------------------------------------------------
PAUSE() { echo -ne "Нажмите Enter..."; read dummy; }

check_root() {
	if [ "$(id -u)" != "0" ]; then
		echo -e "${RED}Скрипт нужно запускать от root (на Keenetic — через SSH/telnet, порт 222, пользователь root).${NC}"
		exit 1
	fi
}

check_entware() {
	if [ ! -x "$ENTWARE_ROOT/bin/opkg" ]; then
		echo -e "${RED}Entware (opkg) не найден в $ENTWARE_ROOT/bin/opkg.${NC}"
		echo -e "${YELLOW}Установи Entware на Keenetic перед использованием этого скрипта.${NC}"
		exit 1
	fi
	export PATH="$ENTWARE_ROOT/bin:$ENTWARE_ROOT/sbin:$PATH"
}

is_installed() { [ -d "$ZAPRET_DIR" ] && [ -f "$ZAPRET_DIR/install_easy.sh" ] && [ -f "$ZAPRET_CONF" ]; }
is_running() { pgrep -f "$ZAPRET_DIR/" >/dev/null 2>&1; }

require_installed() {
	if ! is_installed; then
		echo -e "\n${RED}Zapret не установлен!${NC}\n"
		PAUSE
		return 1
	fi
	return 0
}

get_installed_version() {
	grep -m1 "^ZVER=" "$ZAPRET_DIR/init.d/sysv/zapret" 2>/dev/null | cut -d'"' -f2
}

get_latest_version() {
	curl -s --connect-timeout 5 --max-time 8 "$REPO_API_LATEST" 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/'
}

ZAPRET_RESTART() {
	[ -x "$INIT_LINK" ] && "$INIT_LINK" restart >/dev/null 2>&1
	sleep 1
}

# Достаёт текущее значение NFQWS_OPT из config (многострочное, до закрывающей кавычки)
get_nfqws_opt() {
	awk '/^NFQWS_OPT=/{flag=1} flag{print} flag && /"[[:space:]]*$/{if(NR>1 || gsub(/^NFQWS_OPT="/,"")==0) ; if($0 ~ /"[[:space:]]*$/ && flag==1 && start==1) exit; start=1}' "$ZAPRET_CONF" 2>/dev/null
}

# Замена блока NFQWS_OPT="...многострочный..." на новое значение.
# $1 = новое тело (без внешних кавычек и без переменной), многострочное
set_nfqws_opt() {
	BODY="$1"
	TMP_CONF="$ZKM_TMP/config.new"
	mkdir -p "$ZKM_TMP"
	awk -v body="$BODY" '
		BEGIN { inblock=0; done=0 }
		{
			if (inblock==0 && $0 ~ /^NFQWS_OPT="/) {
				print "NFQWS_OPT=\"" body "\""
				inblock=1
				done=1
				# если открывающая строка сама содержит закрывающую кавычку - блок однострочный
				if ($0 ~ /"[[:space:]]*$/ && length($0) > length("NFQWS_OPT=\"")) {
					inblock=0
				}
				next
			}
			if (inblock==1) {
				if ($0 ~ /"[[:space:]]*$/) { inblock=0 }
				next
			}
			print
		}
		END {
			if (done==0) print "NFQWS_OPT=\"" body "\""
		}
	' "$ZAPRET_CONF" > "$TMP_CONF" && mv "$TMP_CONF" "$ZAPRET_CONF"
}

set_conf_var() {
	# $1=VAR $2=value (без кавычек, простые значения в одну строку)
	VAR="$1"; VAL="$2"
	if grep -q "^${VAR}=" "$ZAPRET_CONF" 2>/dev/null; then
		sed -i "s|^${VAR}=.*|${VAR}=${VAL}|" "$ZAPRET_CONF"
	else
		echo "${VAR}=${VAL}" >> "$ZAPRET_CONF"
	fi
}

get_conf_var() {
	grep -m1 "^${1}=" "$ZAPRET_CONF" 2>/dev/null | cut -d'=' -f2-
}

ensure_filter_mode_hostlist() {
	CUR="$(get_conf_var MODE_FILTER)"
	case "$CUR" in
		hostlist|autohostlist) ;;
		*) set_conf_var MODE_FILTER "hostlist" ;;
	esac
}

# ==============================================================================
# УСТАНОВКА / ОБНОВЛЕНИЕ / УДАЛЕНИЕ
# ==============================================================================

install_prereqs() {
	echo -e "${CYAN}Обновляем список пакетов opkg${NC}"
	opkg update >/dev/null 2>&1
	echo -e "${CYAN}Проверяем/ставим зависимости${NC}"
	for pkg in $REQUIRED_PKGS; do
		opkg list-installed 2>/dev/null | grep -q "^$pkg " && continue
		echo -e "  ${DGRAY}-> $pkg${NC}"
		opkg install "$pkg" >/dev/null 2>&1
	done
	if ! command -v git >/dev/null 2>&1; then
		opkg install git git-http >/dev/null 2>&1
	fi
}

fetch_source() {
	rm -rf "$ZKM_TMP"; mkdir -p "$ZKM_TMP"
	if command -v git >/dev/null 2>&1; then
		echo -e "${CYAN}Клонируем репозиторий через git${NC}"
		if git clone --depth=1 "$REPO_URL.git" "$ZKM_TMP/zapret" >/dev/null 2>&1; then
			SRC_DIR="$ZKM_TMP/zapret"
			return 0
		fi
		echo -e "${YELLOW}git clone не удался, пробуем скачать архив${NC}"
	fi
	echo -e "${CYAN}Скачиваем архив исходников (master)${NC}"
	if curl -sL --connect-timeout 5 --max-time 60 -o "$ZKM_TMP/zapret.tar.gz" "$REPO_TARBALL"; then
		tar -xzf "$ZKM_TMP/zapret.tar.gz" -C "$ZKM_TMP" 2>/dev/null
		SRC_DIR="$(find "$ZKM_TMP" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1)"
		[ -n "$SRC_DIR" ] && return 0
	fi
	echo -e "${RED}Не удалось скачать исходники zapret.${NC}"
	return 1
}

backup_settings() {
	[ -d "$ZAPRET_DIR" ] || return
	mkdir -p "$BACKUP_DIR"
	echo -e "${CYAN}Делаем резервную копию конфига и пользовательских списков${NC}"
	BK="$BACKUP_DIR/zapret_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
	( cd "$ZAPRET_DIR" && tar -czf "$BK" \
		config 2>/dev/null \
		init.d/sysv/custom.d 2>/dev/null \
		ipset/zapret-hosts-user.txt 2>/dev/null \
		ipset/zapret-hosts-user-exclude.txt 2>/dev/null \
		ipset/zapret-hosts-user-ipban.txt 2>/dev/null \
		ipset/zapret-hosts-auto.txt 2>/dev/null \
		ipset/zapret-hosts-google.txt 2>/dev/null ) 2>/dev/null
	if [ -s "$BK" ]; then
		echo -e "${GREEN}Бэкап сохранён: $BK${NC}"
		ls -t "$BACKUP_DIR"/zapret_backup_*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
	else
		rm -f "$BK"
	fi
}

restore_settings_into() {
	LATEST_BK="$(ls -t "$BACKUP_DIR"/zapret_backup_*.tar.gz 2>/dev/null | head -n1)"
	[ -n "$LATEST_BK" ] || return
	echo -e "${CYAN}Восстанавливаем конфиг и списки из бэкапа${NC}"
	tar -xzf "$LATEST_BK" -C "$1" 2>/dev/null
}

link_init() {
	mkdir -p "$ENTWARE_ROOT/etc/init.d"
	ln -fs "$INIT_SRC" "$INIT_LINK"
	chmod +x "$INIT_SRC" "$INIT_LINK" 2>/dev/null
}

install_zapret() {
	check_entware
	if is_installed; then
		echo -e "\n${YELLOW}zapret уже установлен (версия: $(get_installed_version)).${NC}"
		echo -e "Используй пункт обновления, если хочешь поставить новую версию.\n"
		PAUSE
		return
	fi
	echo -e "\n${MAGENTA}Устанавливаем zapret${NC}"
	install_prereqs
	fetch_source || { PAUSE; return; }
	echo -e "${CYAN}Запускаем install_easy.sh${NC}"
	chmod +x "$SRC_DIR/install_easy.sh"
	( cd "$SRC_DIR" && ZAPRET_BASE="$ZAPRET_DIR" sh ./install_easy.sh )
	INSTALL_RC=$?
	rm -rf "$ZKM_TMP"
	if [ $INSTALL_RC -ne 0 ] || [ ! -f "$ZAPRET_DIR/install_easy.sh" ]; then
		echo -e "\n${RED}Установка не завершилась успешно (код $INSTALL_RC).${NC}\n"
		PAUSE
		return
	fi
	link_init
	echo -e "${CYAN}Включаем автозапуск${NC}"
	"$INIT_LINK" start >/dev/null 2>&1
	echo -e "\n${GREEN}zapret установлен и запущен.${NC}\n"
	PAUSE
}

update_zapret() {
	check_entware
	require_installed || return
	OLD_VER="$(get_installed_version)"
	LATEST_VER="$(get_latest_version)"
	echo -e "\n${CYAN}Текущая версия: ${NC}${OLD_VER:-неизвестна}"
	[ -n "$LATEST_VER" ] && echo -e "${CYAN}Последний релиз на GitHub: ${NC}$LATEST_VER"
	echo -e "${MAGENTA}Обновляем zapret${NC}"
	backup_settings
	"$INIT_LINK" stop >/dev/null 2>&1
	for pid in $(pgrep -f "$ZAPRET_DIR/" 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
	fetch_source || { PAUSE; return; }
	chmod +x "$SRC_DIR/install_easy.sh"
	( cd "$SRC_DIR" && ZAPRET_BASE="$ZAPRET_DIR" sh ./install_easy.sh )
	INSTALL_RC=$?
	rm -rf "$ZKM_TMP"
	if [ $INSTALL_RC -ne 0 ]; then
		echo -e "\n${RED}Обновление завершилось с ошибкой. Восстанавливаем бэкап.${NC}"
		restore_settings_into "$ZAPRET_DIR"
		PAUSE
		return
	fi
	link_init
	"$INIT_LINK" start >/dev/null 2>&1
	echo -e "\n${GREEN}Обновление завершено: ${OLD_VER:-?} -> $(get_installed_version)${NC}\n"
	PAUSE
}

uninstall_zapret() {
	require_installed || return
	echo -ne "\n${RED}Удалить zapret полностью? (y/N): ${NC}"
	read CONFIRM
	case "$CONFIRM" in y|Y|yes|Yes) ;; *) echo -e "${YELLOW}Отменено.${NC}\n"; return ;; esac
	echo -ne "${CYAN}Сохранить бэкап конфига перед удалением? (Y/n): ${NC}"
	read DOBACKUP
	case "$DOBACKUP" in n|N|no|No) ;; *) backup_settings ;; esac
	echo -e "${MAGENTA}Удаляем zapret${NC}"
	[ -x "$ZAPRET_DIR/uninstall_easy.sh" ] && ( cd "$ZAPRET_DIR" && sh ./uninstall_easy.sh ) >/dev/null 2>&1
	"$INIT_LINK" stop >/dev/null 2>&1
	for pid in $(pgrep -f "$ZAPRET_DIR/" 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
	rm -f "$INIT_LINK"
	rm -rf "$ZAPRET_DIR"
	echo -e "${GREEN}zapret удалён.${NC}\n"
	PAUSE
}

start_zapret_action() {
	if [ ! -x "$INIT_LINK" ]; then echo -e "\n${RED}Автозапуск не настроен.${NC}\n"; PAUSE; return; fi
	"$INIT_LINK" start; PAUSE
}
stop_zapret_action() {
	[ -x "$INIT_LINK" ] && "$INIT_LINK" stop
	for pid in $(pgrep -f "$ZAPRET_DIR/" 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
	PAUSE
}
restart_zapret_action() { [ -x "$INIT_LINK" ] && "$INIT_LINK" restart; PAUSE; }

fix_autostart() {
	require_installed || return
	link_init
	echo -e "\n${GREEN}Симлинк автозапуска восстановлен: $INIT_LINK -> $INIT_SRC${NC}\n"
	PAUSE
}

show_status() {
	echo -e "\n${CYAN}=== Статус zapret ===${NC}"
	if is_installed; then
		echo -e "Установлен: ${GREEN}да${NC}  Версия: $(get_installed_version 2>/dev/null || echo неизвестна)"
		echo -e "Каталог:    $ZAPRET_DIR"
		echo -e "MODE_FILTER: $(get_conf_var MODE_FILTER)"
	else
		echo -e "Установлен: ${RED}нет${NC}"
	fi
	if [ -L "$INIT_LINK" ]; then echo -e "Автозапуск: ${GREEN}настроен${NC}"; else echo -e "Автозапуск: ${RED}не настроен${NC}"; fi
	RUN_COUNT=$(pgrep -f "$ZAPRET_DIR/" 2>/dev/null | wc -l)
	if [ "$RUN_COUNT" -gt 0 ]; then
		echo -e "Процессы:   ${GREEN}запущено $RUN_COUNT${NC}"
		pgrep -af "$ZAPRET_DIR/" 2>/dev/null | sed 's/^/  /'
	else
		echo -e "Процессы:   ${RED}не запущены${NC}"
	fi
	echo
	PAUSE
}

edit_config() {
	require_installed || return
	EDITOR_BIN="$(command -v nano || command -v vi)"
	if [ -z "$EDITOR_BIN" ]; then echo -e "${RED}Не найден nano/vi. Установи: opkg install nano${NC}"; PAUSE; return; fi
	"$EDITOR_BIN" "$ZAPRET_CONF"
	echo -ne "${CYAN}Перезапустить zapret? (Y/n): ${NC}"
	read R
	case "$R" in n|N) ;; *) ZAPRET_RESTART ;; esac
	PAUSE
}

# ==============================================================================
# ГОТОВЫЕ СТРАТЕГИИ v1-v9 (универсальные параметры nfqws, без UCI-специфики)
# ==============================================================================

strategy_v1() { printf '%s\n' \
"--filter-tcp=443 --hostlist=$HOSTLIST_GOOGLE --dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-mod=host=google.com --dpi-desync-fooling=ts" \
"--new" \
"--filter-tcp=443 --hostlist-exclude=$HOSTLIST_EXCLUDE <HOSTLIST> --dpi-desync=split2 --dpi-desync-split-seqovl=681 --dpi-desync-split-seqovl-pattern=$FAKE_DIR/stun.bin"
}
strategy_v2() { printf '%s\n' \
"--filter-tcp=443 --hostlist=$HOSTLIST_GOOGLE --dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-mod=host=google.com --dpi-desync-fooling=ts" \
"--new" \
"--filter-tcp=443 --hostlist-exclude=$HOSTLIST_EXCLUDE <HOSTLIST> --dpi-desync=fake,multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-fooling=ts --dpi-desync-repeats=8 --dpi-desync-split-seqovl-pattern=$FAKE_DIR/stun.bin --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"
}
strategy_v3() { printf '%s\n' \
"--filter-tcp=443 --hostlist=$HOSTLIST_GOOGLE --dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-mod=host=google.com --dpi-desync-fooling=ts" \
"--new" \
"--filter-tcp=443 --hostlist-exclude=$HOSTLIST_EXCLUDE <HOSTLIST> --dpi-desync=fake,fakeddisorder --dpi-desync-split-pos=10,midsld --dpi-desync-fake-tls=$FAKE_DIR/tls_clienthello_www_google_com.bin --dpi-desync-fake-tls-mod=rnd,dupsid --dpi-desync-split-seqovl=336 --dpi-desync-fooling=badseq,badsum --dpi-desync-badseq-increment=0" \
"--new" \
"--filter-udp=443 --hostlist-exclude=$HOSTLIST_EXCLUDE <HOSTLIST> --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic=$FAKE_DIR/quic_initial_www_google_com.bin"
}
strategy_v4() { printf '%s\n' \
"--filter-tcp=443 --hostlist=$HOSTLIST_GOOGLE --dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-mod=host=google.com --dpi-desync-fooling=ts" \
"--new" \
"--filter-tcp=443 --hostlist-exclude=$HOSTLIST_EXCLUDE <HOSTLIST> --dpi-desync=multisplit --dpi-desync-split-seqovl=582 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern=$FAKE_DIR/stun.bin" \
"--new" \
"--filter-udp=443 --hostlist-exclude=$HOSTLIST_EXCLUDE <HOSTLIST> --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic=$FAKE_DIR/quic_initial_www_google_com.bin"
}
strategy_v5() { printf '%s\n' \
"--filter-tcp=443 --hostlist=$HOSTLIST_GOOGLE --dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-mod=host=google.com --dpi-desync-fooling=ts" \
"--new" \
"--filter-tcp=443 --hostlist-exclude=$HOSTLIST_EXCLUDE <HOSTLIST> --dpi-desync=fake,fakeddisorder --dpi-desync-split-pos=1 --dpi-desync-fake-tls=$FAKE_DIR/stun.bin --dpi-desync-fake-tls-mod=none --dpi-desync-fooling=badseq,badsum --dpi-desync-badseq-increment=0" \
"--new" \
"--filter-udp=443 --hostlist-exclude=$HOSTLIST_EXCLUDE <HOSTLIST> --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic=$FAKE_DIR/quic_initial_www_google_com.bin"
}
strategy_v6() { printf '%s\n' \
"--filter-tcp=443 --hostlist=$HOSTLIST_GOOGLE --dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-mod=host=google.com --dpi-desync-fooling=ts" \
"--new" \
"--filter-tcp=443 --hostlist-exclude=$HOSTLIST_EXCLUDE <HOSTLIST> --dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-mod=host=i2.photo.2gis.com --dpi-desync-split-seqovl=726 --dpi-desync-fooling=badsum,badseq --dpi-desync-badseq-increment=0"
}
strategy_v7() { printf '%s\n' \
"--filter-tcp=443 --hostlist=$HOSTLIST_GOOGLE --dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-mod=host=google.com --dpi-desync-fooling=ts" \
"--new" \
"--filter-tcp=443 --hostlist-exclude=$HOSTLIST_EXCLUDE <HOSTLIST> --dpi-desync=fake,multisplit --dpi-desync-split-seqovl=654 --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq,badsum --dpi-desync-repeats=8 --dpi-desync-split-seqovl-pattern=$FAKE_DIR/stun.bin --dpi-desync-fake-tls=$FAKE_DIR/stun.bin --dpi-desync-badseq-increment=0"
}
strategy_v8() { printf '%s\n' \
"--filter-tcp=443 --hostlist=$HOSTLIST_GOOGLE --dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-mod=host=google.com --dpi-desync-fooling=ts" \
"--new" \
"--filter-tcp=443 --hostlist-exclude=$HOSTLIST_EXCLUDE <HOSTLIST> --dpi-desync=fake --dpi-desync-fooling=ts --dpi-desync-fake-tls-mod=none"
}
strategy_v9() { printf '%s\n' \
"--filter-tcp=443 --hostlist=$HOSTLIST_GOOGLE --dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-mod=host=google.com --dpi-desync-fooling=ts" \
"--new" \
"--filter-tcp=443 --hostlist-exclude=$HOSTLIST_EXCLUDE <HOSTLIST> --dpi-desync=hostfakesplit --dpi-desync-fooling=badseq,badsum --dpi-desync-hostfakesplit-mod=host=mapgl.2gis.com --dpi-desync-badseq-increment=0"
}

base_tcp80() {
	printf '%s\n' "--filter-tcp=80 <HOSTLIST> --dpi-desync=fake,split2 --dpi-desync-autottl=2 --dpi-desync-fooling=md5sig"
}

assemble_strategy() {
	# $1 = имя версии (v1..v9), формирует полный NFQWS_OPT: http(80) + переданная стратегия для 443
	VER="$1"
	{
		base_tcp80
		echo "--new"
		"strategy_$VER"
	}
}

install_strategy() {
	VER="$1"; NO_PAUSE="${2:-0}"
	require_installed || return
	[ "$NO_PAUSE" != "1" ] && echo -e "\n${MAGENTA}Устанавливаем стратегию ${VER}${NC}"
	echo -e "${CYAN}Останавливаем zapret${NC}"
	"$INIT_LINK" stop >/dev/null 2>&1
	ensure_filter_mode_hostlist
	set_conf_var NFQWS_PORTS_TCP "$PORTS_TCP_DEFAULT"
	set_conf_var NFQWS_PORTS_UDP "$PORTS_UDP_DEFAULT"
	BODY="$(assemble_strategy "$VER")"
	set_nfqws_opt "$BODY"
	echo "$VER" > "$STATE_FILE.strategy"
	echo -e "${CYAN}Применяем стратегию${NC}"
	ZAPRET_RESTART
	echo -e "${GREEN}Стратегия ${NC}${VER}${GREEN} установлена!${NC}"
	[ "$NO_PAUSE" != "1" ] && { echo; PAUSE; }
}

strategy_choose_builtin() {
	require_installed || return
	echo -ne "\n${YELLOW}Введите версию стратегии (${NC}1-9${YELLOW}):${NC} "
	read CH
	case "$CH" in
		[1-9]) install_strategy "v$CH" ;;
		*) echo -e "${RED}Некорректный выбор${NC}\n"; PAUSE ;;
	esac
}

show_current_strategy() {
	CUR="$(cat "$STATE_FILE.strategy" 2>/dev/null)"
	[ -n "$CUR" ] && echo -e "${YELLOW}Текущая встроенная стратегия:${NC} ${CYAN}$CUR${NC}"
}

# ==============================================================================
# СТРАТЕГИИ FLOWSEAL (zapret-discord-youtube)
# ==============================================================================

download_flowseal_strategies() {
	NO_PAUSE="$1"
	[ "$NO_PAUSE" != "1" ] && echo -e "\n${MAGENTA}Скачиваем и формируем стратегии Flowseal${NC}"
	mkdir -p "$ZKM_TMP"
	ZIP="$ZKM_TMP/flowseal.zip"
	curl -fsSL -A "Mozilla/5.0" -o "$ZIP" "$FLOWSEAL_REPO_ZIP" || { echo -e "\n${RED}Не удалось скачать архив Flowseal${NC}\n"; PAUSE; return 1; }
	mkdir -p "$FAKE_DIR"
	curl -fsSL -A "Mozilla/5.0" -o "$FAKE_DIR/quic_initial_dbankcloud_ru.bin" \
		"https://github.com/Flowseal/zapret-discord-youtube/raw/refs/heads/main/bin/quic_initial_dbankcloud_ru.bin" 2>/dev/null
	unzip -oq "$ZIP" -d "$ZKM_TMP" || { echo -e "\n${RED}Не удалось распаковать архив${NC}\n"; PAUSE; return 1; }
	BASE="$ZKM_TMP/zapret-discord-youtube-main"
	: > "$FLOWSEAL_STRATEGIES_CACHE"
	find "$BASE" -maxdepth 1 -type f -name 'general*.bat' ! -name 'general (ALT5).bat' | sort | while IFS= read -r F; do
		NAME="$(basename "$F" .bat)"
		LINE="$(grep -v '^[[:space:]]*::' "$F" | grep -v '^@echo' | grep 'filter-' | head -1)"
		[ -z "$LINE" ] && continue
		# Извлекаем полную команду winws (она разбита символом ^ на строки в .bat)
		FULL="$(awk '/winws.exe/{flag=1} flag{gsub(/\^[[:space:]]*$/,""); printf "%s ", $0} /pause|exit|^$/{if(flag)exit}' "$F")"
		[ -z "$FULL" ] && continue
		{
			echo "#$NAME"
			echo "$FULL" | sed 's/.*winws\.exe"//' \
				| sed 's/--wf-tcp=[^ ]*//' \
				| sed 's/--wf-udp=[^ ]*//' \
				| sed 's/--/\n--/g' \
				| sed '/^[[:space:]]*$/d' \
				| sed 's/[[:space:]]*$//'
			echo
		} >> "$FLOWSEAL_STRATEGIES_CACHE"
	done
	# Подменяем windows-плейсхолдеры на entware-пути
	sed -i \
		-e "s|\"%LISTS%list-general.txt\"|<HOSTLIST>|g" \
		-e "/\"%LISTS%list-general-user.txt\"/d" \
		-e "/\"%LISTS%list-exclude-user.txt\"/d" \
		-e "/\"%LISTS%ipset-exclude-user.txt\"/d" \
		-e "s|\"%LISTS%list-exclude.txt\"|$HOSTLIST_EXCLUDE|g" \
		-e "s|--ipset-exclude=\"%LISTS%ipset-exclude.txt\"||g" \
		-e "s|\"%LISTS%list-google.txt\"|\"$HOSTLIST_GOOGLE\"|g" \
		-e "s|\"%BIN%quic_initial_dbankcloud_ru.bin\"|\"$FAKE_DIR/quic_initial_dbankcloud_ru.bin\"|g" \
		-e "s|\"%BIN%quic_initial_www_google_com.bin\"|\"$FAKE_DIR/quic_initial_www_google_com.bin\"|g" \
		-e "s|\"%BIN%stun.bin\"|\"$FAKE_DIR/stun.bin\"|g" \
		-e "s|\"%BIN%tls_clienthello_www_google_com.bin\"|\"$FAKE_DIR/tls_clienthello_www_google_com.bin\"|g" \
		"$FLOWSEAL_STRATEGIES_CACHE" 2>/dev/null
	# чистим пустые строки и одиночные висячие --new, образовавшиеся после удаления опций
	sed -i '/^[[:space:]]*$/d' "$FLOWSEAL_STRATEGIES_CACHE" 2>/dev/null
	rm -rf "$ZKM_TMP/zapret-discord-youtube-main" "$ZIP"
	[ "$NO_PAUSE" != "1" ] && { echo -e "${GREEN}Стратегии сформированы!${NC}\n"; PAUSE; }
	return 0
}

flowseal_menu() {
	require_installed || return
	[ ! -s "$FLOWSEAL_STRATEGIES_CACHE" ] && download_flowseal_strategies 1
	while true; do
		STRATEGIES="$(grep '^#' "$FLOWSEAL_STRATEGIES_CACHE" 2>/dev/null | sed 's/^#//')"
		[ -z "$STRATEGIES" ] && { echo -e "\n${RED}Список стратегий пуст. Проверь подключение к интернету.${NC}\n"; PAUSE; return; }
		clear
		echo -e "${YELLOW}Стратегии от Flowseal (zapret-discord-youtube)${NC}\n"
		i=1
		echo "$STRATEGIES" | while IFS= read -r line; do echo -e " ${CYAN}$i) ${NC}$line"; i=$((i+1)); done
		echo -ne "\n${CYAN} 0) ${GREEN}Обновить список стратегий${NC}\n${CYAN}Enter) ${GREEN}Назад${NC}\n\n${YELLOW}Выбор: ${NC}"
		read CH
		[ -z "$CH" ] && return
		case "$CH" in
			0) download_flowseal_strategies; continue ;;
			''|*[!0-9]*) continue ;;
		esac
		SEL_NAME="$(echo "$STRATEGIES" | sed -n "${CH}p")"
		[ -z "$SEL_NAME" ] && continue
		BLOCK="$(awk -v name="$SEL_NAME" '$0=="#"name{flag=1;next} /^#/&&flag{exit} flag{print}' "$FLOWSEAL_STRATEGIES_CACHE")"
		echo -e "\n${MAGENTA}Устанавливаем стратегию: ${NC}$SEL_NAME"
		"$INIT_LINK" stop >/dev/null 2>&1
		ensure_filter_mode_hostlist
		set_conf_var NFQWS_PORTS_TCP "$PORTS_TCP_DEFAULT,$DISCORD_TCP_PORTS"
		set_conf_var NFQWS_PORTS_UDP "$PORTS_UDP_DEFAULT,$DISCORD_UDP_PORTS"
		set_nfqws_opt "$BLOCK"
		echo "Flowseal:$SEL_NAME" > "$STATE_FILE.strategy"
		echo -e "${CYAN}Обновляем список исключений${NC}"
		curl -fsSL -o "$HOSTLIST_EXCLUDE" "$EXCLUDE_LIST_URL" 2>/dev/null
		ZAPRET_RESTART
		echo -e "${GREEN}Стратегия установлена!${NC}\n"
		PAUSE
		return
	done
}

# ==============================================================================
# DISCORD-СТРАТЕГИИ (отдельные пресеты для discord.media, поверх текущей основной стратегии)
# ==============================================================================

discord_block_base() {
	printf '%s\n' \
"--filter-udp=$DISCORD_UDP_PORTS --filter-l7=discord,stun --dpi-desync=fake --dpi-desync-fake-discord=$FAKE_DIR/stun.bin --dpi-desync-fake-stun=$FAKE_DIR/stun.bin --dpi-desync-repeats=6"
}

discord_strategy_1() { printf '%s\n' "--filter-tcp=$DISCORD_TCP_PORTS --hostlist-domains=discord.media --dpi-desync=multisplit --dpi-desync-split-seqovl=652 --dpi-desync-split-pos=2 --dpi-desync-split-seqovl-pattern=$FAKE_DIR/tls_clienthello_www_google_com.bin"; }
discord_strategy_2() { printf '%s\n' "--filter-tcp=$DISCORD_TCP_PORTS --hostlist-domains=discord.media --dpi-desync=fake,multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-fooling=ts --dpi-desync-repeats=8 --dpi-desync-split-seqovl-pattern=$FAKE_DIR/tls_clienthello_www_google_com.bin --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"; }
discord_strategy_3() { printf '%s\n' "--filter-tcp=$DISCORD_TCP_PORTS --hostlist-domains=discord.media --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fake-tls=$FAKE_DIR/tls_clienthello_www_google_com.bin --dpi-desync-fake-tls-mod=none"; }
discord_strategy_4() { printf '%s\n' "--filter-tcp=$DISCORD_TCP_PORTS --hostlist-domains=discord.media --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls=$FAKE_DIR/tls_clienthello_www_google_com.bin"; }
discord_strategy_5() { printf '%s\n' "--filter-tcp=$DISCORD_TCP_PORTS --hostlist-domains=discord.media --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=$FAKE_DIR/tls_clienthello_www_google_com.bin --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"; }

# Удаляет блок(и) discord/stun из NFQWS_OPT и убирает повисший разделитель --new в конце
strip_discord_block() {
	echo "$1" | awk '
		/--filter-l7=discord,stun|hostlist-domains=discord\.media/ { skip=1 }
		/^--new$/ { if (skip) { skip=0; next } }
		{ if (!skip) { if (pend) print pend; pend=$0 } }
		END { if (pend && pend != "--new") print pend }
	'
}

discord_menu() {
	require_installed || return
	while true; do
		clear
		echo -e "${MAGENTA}Меню стратегий для Discord (discord.media)${NC}\n"
		echo -e "${YELLOW}Добавляет отдельный блок --new в текущую стратегию специально для discord.media.${NC}\n"
		echo -e " ${CYAN}1-5${NC}) Выбрать вариант стратегии для discord.media"
		echo -e " ${CYAN}0${NC}) Удалить discord-блок из текущей стратегии"
		echo -ne " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		[ -z "$CH" ] && return
		case "$CH" in
			0)
				CUR="$(get_nfqws_opt)"
				NEW="$(strip_discord_block "$CUR")"
				set_nfqws_opt "$NEW"
				ZAPRET_RESTART
				echo -e "\n${GREEN}Discord-блок удалён${NC}\n"; PAUSE
				;;
			1|2|3|4|5)
				CUR="$(get_nfqws_opt)"
				CUR_CLEAN="$(strip_discord_block "$CUR")"
				DBLOCK="$(discord_block_base; echo "--new"; discord_strategy_$CH)"
				NEW="$(printf '%s\n--new\n%s' "$CUR_CLEAN" "$DBLOCK")"
				set_conf_var NFQWS_PORTS_UDP "$(get_conf_var NFQWS_PORTS_UDP),$DISCORD_UDP_PORTS"
				set_conf_var NFQWS_PORTS_TCP "$(get_conf_var NFQWS_PORTS_TCP),$DISCORD_TCP_PORTS"
				set_nfqws_opt "$NEW"
				ZAPRET_RESTART
				echo -e "\n${GREEN}Discord-стратегия Dv$CH применена${NC}\n"; PAUSE
				;;
		esac
	done
}

# ==============================================================================
# RKN-СПИСОК (автозагрузка хостлиста заблокированных доменов)
# ==============================================================================

rkn_enabled() {
	[ -s "$HOSTLIST_USER" ] && [ "$(wc -c < "$HOSTLIST_USER" 2>/dev/null || echo 0)" -gt 500000 ]
}

rkn_enable() {
	require_installed || return
	echo -e "\n${MAGENTA}Включаем список РКН${NC}"
	[ -f "$HOSTLIST_USER" ] && cp "$HOSTLIST_USER" "$RKN_BACKUP_FILE"
	mkdir -p "$IPSET_DIR" "$ZKM_TMP"
	if curl -fsSL -o "$ZKM_TMP/rkn.txt" "$RKN_HOSTLIST_URL"; then
		cp "$ZKM_TMP/rkn.txt" "$HOSTLIST_USER"
	else
		echo -e "\n${RED}Не удалось скачать список РКН${NC}\n"; PAUSE; return
	fi
	ensure_filter_mode_hostlist
	ZAPRET_RESTART
	echo -e "${GREEN}Список РКН включен (доменов: $(wc -l < "$HOSTLIST_USER" 2>/dev/null))${NC}\n"
	PAUSE
}

rkn_disable() {
	require_installed || return
	echo -e "\n${MAGENTA}Выключаем список РКН${NC}"
	if [ -s "$RKN_BACKUP_FILE" ]; then
		cp "$RKN_BACKUP_FILE" "$HOSTLIST_USER"
	else
		: > "$HOSTLIST_USER"
	fi
	rm -f "$RKN_BACKUP_FILE"
	ZAPRET_RESTART
	echo -e "${GREEN}Список РКН выключен${NC}\n"
	PAUSE
}

rkn_menu() {
	require_installed || return
	clear
	echo -e "${MAGENTA}Список РКН (zapret-hosts-user.txt)${NC}\n"
	if rkn_enabled; then
		echo -e "Статус: ${GREEN}включен${NC} (доменов: $(wc -l < "$HOSTLIST_USER" 2>/dev/null))"
		echo -ne "\n${CYAN}1${NC}) Выключить\n${CYAN}2${NC}) Обновить список заново\n${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in 1) rkn_disable ;; 2) rkn_enable ;; esac
	else
		echo -e "Статус: ${RED}выключен${NC}"
		echo -ne "\n${CYAN}1${NC}) Включить\n${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in 1) rkn_enable ;; esac
	fi
}

# ==============================================================================
# HOSTS-БЛОКИ (Instagram/Telegram/AI-сервисы и т.п. через /etc/hosts)
# ==============================================================================

INSTAGRAM_HOSTS="#Instagram&Facebook
57.144.222.34 instagram.com www.instagram.com
157.240.9.174 instagram.com www.instagram.com
157.240.245.174 instagram.com www.instagram.com b.i.instagram.com help.instagram.com
157.240.205.174 instagram.com www.instagram.com
57.144.244.192 static.cdninstagram.com graph.instagram.com i.instagram.com api.instagram.com
31.13.66.63 scontent.cdninstagram.com
57.144.244.1 facebook.com www.facebook.com fb.com fbsbx.com
57.144.244.128 static.xx.fbcdn.net scontent.xx.fbcdn.net"

TELEGRAM_WEB_HOSTS="#TelegramWeb
149.154.167.220 core.telegram.org api.telegram.org web.telegram.org telegram.org t.me telegram.me"

TWITCH_HOSTS="#Twitch
45.155.204.190 usher.ttvnw.net gql.twitch.tv"

AI_HOSTS="#Gemini
45.155.204.190 gemini.google.com
#Grok
45.155.204.190 grok.com accounts.x.ai assets.grok.com
#OpenAI
45.155.204.190 chatgpt.com ab.chatgpt.com auth.openai.com auth0.openai.com platform.openai.com api.openai.com
#Claude
45.155.204.190 claude.ai console.anthropic.com api.anthropic.com
#NotebookLM
45.155.204.190 notebooklm.google notebooklm.google.com"

SPOTIFY_HOSTS="#Spotify
45.155.204.190 api.spotify.com login5.spotify.com open.spotify.com accounts.spotify.com"

GITHUB_RAW_HOSTS="#githubusercontent.com
185.199.109.133 raw.githubusercontent.com release-assets.githubusercontent.com
185.199.108.133 private-user-images.githubusercontent.com gist.githubusercontent.com"

hosts_block_add() {
	BLOCK="$1"
	printf '%s\n' "$BLOCK" | while IFS= read -r line; do
		[ -z "$line" ] && continue
		grep -Fxq "$line" "$ETC_HOSTS" 2>/dev/null || echo "$line" >> "$ETC_HOSTS"
	done
	restart_dns
}

hosts_block_remove() {
	BLOCK="$1"
	printf '%s\n' "$BLOCK" | while IFS= read -r line; do
		[ -z "$line" ] && continue
		sed -i "\\|^$(printf '%s' "$line" | sed 's/[.[\*^$/]/\\&/g')$|d" "$ETC_HOSTS" 2>/dev/null
	done
	restart_dns
}

hosts_block_status() {
	BLOCK="$1"
	FIRST_LINE="$(printf '%s\n' "$BLOCK" | sed -n '2p')"
	[ -z "$FIRST_LINE" ] && return 1
	grep -Fxq "$FIRST_LINE" "$ETC_HOSTS" 2>/dev/null
}

restart_dns() {
	# На Keenetic основной DNS обслуживается прошивкой (ndm), не initd dnsmasq. Перезапуск службы тут не требуется -
	# /etc/hosts читается резолвером сразу. На некоторых сборках может потребоваться restart ndsd, но это меняет
	# системные настройки роутера и тут намеренно не трогается.
	:
}

hosts_menu_item() {
	NAME="$1"; BLOCK="$2"
	if hosts_block_status "$BLOCK"; then
		echo -e "${GREEN}[✓]${NC} $NAME ${DGRAY}(добавлен, выбери чтобы удалить)${NC}"
	else
		echo -e "${RED}[ ]${NC} $NAME ${DGRAY}(не добавлен, выбери чтобы добавить)${NC}"
	fi
}

hosts_menu_toggle() {
	BLOCK="$1"
	if hosts_block_status "$BLOCK"; then
		hosts_block_remove "$BLOCK"
		echo -e "\n${GREEN}Блок удалён из /etc/hosts${NC}\n"
	else
		hosts_block_add "$BLOCK"
		echo -e "\n${GREEN}Блок добавлен в /etc/hosts${NC}\n"
	fi
	PAUSE
}

hosts_menu() {
	while true; do
		clear
		echo -e "${MAGENTA}Hosts-блоки (прямые IP для соцсетей/AI-сервисов через /etc/hosts)${NC}\n"
		echo -e "${YELLOW}Внимание: этот метод не зависит от zapret и не требует DPI-обхода, но IP-адреса${NC}"
		echo -e "${YELLOW}могут устаревать. На Keenetic влияет на DNS-резолвинг через /etc/hosts.${NC}\n"
		echo -e " ${CYAN}1) $(hosts_menu_item "Instagram/Facebook" "$INSTAGRAM_HOSTS")"
		echo -e " ${CYAN}2) $(hosts_menu_item "Telegram Web" "$TELEGRAM_WEB_HOSTS")"
		echo -e " ${CYAN}3) $(hosts_menu_item "Twitch" "$TWITCH_HOSTS")"
		echo -e " ${CYAN}4) $(hosts_menu_item "AI-сервисы (OpenAI/Claude/Gemini/Grok)" "$AI_HOSTS")"
		echo -e " ${CYAN}5) $(hosts_menu_item "Spotify" "$SPOTIFY_HOSTS")"
		echo -e " ${CYAN}6) $(hosts_menu_item "raw.githubusercontent.com" "$GITHUB_RAW_HOSTS")"
		echo -e " ${CYAN}9) ${RED}Сбросить /etc/hosts к дефолту${NC}"
		echo -ne " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in
			1) hosts_menu_toggle "$INSTAGRAM_HOSTS" ;;
			2) hosts_menu_toggle "$TELEGRAM_WEB_HOSTS" ;;
			3) hosts_menu_toggle "$TWITCH_HOSTS" ;;
			4) hosts_menu_toggle "$AI_HOSTS" ;;
			5) hosts_menu_toggle "$SPOTIFY_HOSTS" ;;
			6) hosts_menu_toggle "$GITHUB_RAW_HOSTS" ;;
			9)
				echo -ne "\n${RED}Точно сбросить /etc/hosts? (y/N): ${NC}"; read C2
				case "$C2" in
					y|Y)
						printf '127.0.0.1\tlocalhost\n\n::1\tlocalhost ip6-localhost ip6-loopback\n' > "$ETC_HOSTS"
						restart_dns
						echo -e "\n${GREEN}hosts сброшен${NC}\n"
						;;
				esac
				PAUSE
				;;
			'') return ;;
		esac
	done
}

# ==============================================================================
# TG-WS-PROXY (Telegram WebSocket Proxy, Go-сборка spatiumstas/tg-ws-proxy-go)
# ==============================================================================

TG_WS_BIN="$ENTWARE_ROOT/bin/tg-ws-proxy-go"
TG_WS_INIT="$ENTWARE_ROOT/etc/init.d/S53tgwsproxy"
TG_WS_CONF="$ZKM_DIR/tg-ws-proxy.conf"
TG_WS_REPO="spatiumstas/tg-ws-proxy-go"

get_tg_ws_arch() {
	case "$(uname -m)" in
		aarch64|arm64) echo "linux-arm64" ;;
		x86_64) echo "linux-amd64" ;;
		armv7*|armv6*) echo "linux-arm" ;;
		*) echo "" ;;
	esac
}

tg_ws_install() {
	require_installed_optional=1
	echo -e "\n${MAGENTA}Устанавливаем TG-WS-Proxy (Go)${NC}"
	ARCH_TAG="$(get_tg_ws_arch)"
	if [ -z "$ARCH_TAG" ]; then echo -e "${RED}Архитектура не поддерживается: $(uname -m)${NC}\n"; PAUSE; return; fi
	LATEST_URL="https://api.github.com/repos/$TG_WS_REPO/releases/latest"
	DL_URL="$(curl -s "$LATEST_URL" 2>/dev/null | grep "browser_download_url" | grep "$ARCH_TAG" | head -1 | sed -E 's/.*"(https[^"]+)".*/\1/')"
	if [ -z "$DL_URL" ]; then echo -e "${RED}Не удалось найти релиз под архитектуру $ARCH_TAG${NC}\n"; PAUSE; return; fi
	mkdir -p "$ZKM_TMP"
	echo -e "${CYAN}Скачиваем: ${NC}$DL_URL"
	curl -fsSL -o "$ZKM_TMP/tgws.bin" "$DL_URL" || { echo -e "\n${RED}Ошибка загрузки${NC}\n"; PAUSE; return; }
	cp "$ZKM_TMP/tgws.bin" "$TG_WS_BIN"
	chmod +x "$TG_WS_BIN"
	SECRET="$(head -c16 /dev/urandom | hexdump -e '16/1 "%02x"' 2>/dev/null)"
	[ -z "$SECRET" ] && SECRET="$(date +%s%N | md5sum | cut -c1-32)"
	cat > "$TG_WS_CONF" <<EOF
PORT=8443
SECRET=$SECRET
EOF
	cat > "$TG_WS_INIT" <<'INITEOF'
#!/bin/sh
ENABLED=yes
PROCS=tg-ws-proxy-go
ARGS=""
PREARGS=""
DESC=$PROCS
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /opt/etc/init.d/rc.func
INITEOF
	chmod +x "$TG_WS_INIT"
	"$TG_WS_INIT" start >/dev/null 2>&1
	echo -e "${GREEN}TG-WS-Proxy установлен и запущен.${NC}"
	echo -e "${YELLOW}Секрет/порт сохранены в $TG_WS_CONF${NC}\n"
	cat "$TG_WS_CONF"
	echo
	PAUSE
}

tg_ws_remove() {
	echo -e "\n${MAGENTA}Удаляем TG-WS-Proxy${NC}"
	[ -x "$TG_WS_INIT" ] && "$TG_WS_INIT" stop >/dev/null 2>&1
	rm -f "$TG_WS_INIT" "$TG_WS_BIN" "$TG_WS_CONF"
	echo -e "${GREEN}Удалён${NC}\n"
	PAUSE
}

tg_ws_menu() {
	while true; do
		clear
		echo -e "${MAGENTA}TG-WS-Proxy (Telegram WebSocket прокси)${NC}\n"
		if [ -x "$TG_WS_BIN" ]; then
			echo -e "Статус: ${GREEN}установлен${NC}"
			pgrep -f "$TG_WS_BIN" >/dev/null 2>&1 && echo -e "Процесс: ${GREEN}запущен${NC}" || echo -e "Процесс: ${RED}не запущен${NC}"
			[ -f "$TG_WS_CONF" ] && { echo; cat "$TG_WS_CONF"; }
			echo -ne "\n${CYAN}1${NC}) Перезапустить\n${CYAN}2${NC}) Остановить\n${CYAN}3${NC}) Удалить\n${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
			read CH
			case "$CH" in
				1) "$TG_WS_INIT" restart >/dev/null 2>&1; PAUSE ;;
				2) "$TG_WS_INIT" stop >/dev/null 2>&1; PAUSE ;;
				3) tg_ws_remove ;;
				'') return ;;
			esac
		else
			echo -e "Статус: ${RED}не установлен${NC}"
			echo -ne "\n${CYAN}1${NC}) Установить\n${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
			read CH
			case "$CH" in 1) tg_ws_install ;; '') return ;; esac
		fi
	done
}

# ==============================================================================
# БЕНЧМАРК / ТЕСТИРОВАНИЕ СТРАТЕГИЙ (проверка доступности сайтов)
# ==============================================================================

TEST_DOMAINS="youtube.com discord.com discordapp.com instagram.com twitter.com x.com telegram.org chatgpt.com claude.ai gosuslugi.ru"

check_url_one() {
	DOMAIN="$1"
	if curl -sL --connect-timeout 4 --max-time 6 -o /dev/null -A "Mozilla/5.0" "https://$DOMAIN"; then
		echo -e "${GREEN}[ OK ]${NC} $DOMAIN"
	else
		echo -e "${RED}[FAIL]${NC} $DOMAIN"
	fi
}

run_benchmark_current() {
	require_installed || return
	clear
	echo -e "${MAGENTA}Тестирование текущей стратегии${NC}\n"
	show_current_strategy
	echo
	if ! is_running; then
		echo -e "${YELLOW}Внимание: zapret не запущен, тест покажет реальный уровень блокировок без обхода.${NC}\n"
	fi
	for d in $TEST_DOMAINS; do
		check_url_one "$d" &
	done
	wait
	echo
	PAUSE
}

run_benchmark_compare() {
	require_installed || return
	clear
	echo -e "${MAGENTA}Сравнение: с zapret и без${NC}\n"
	echo -e "${CYAN}--- С zapret (текущее состояние) ---${NC}"
	WAS_RUNNING=0
	is_running && WAS_RUNNING=1
	[ "$WAS_RUNNING" -eq 0 ] && "$INIT_LINK" start >/dev/null 2>&1 && sleep 1
	for d in $TEST_DOMAINS; do check_url_one "$d"; done
	echo -e "\n${CYAN}--- Без zapret (контрольный тест) ---${NC}"
	"$INIT_LINK" stop >/dev/null 2>&1
	sleep 1
	for d in $TEST_DOMAINS; do check_url_one "$d"; done
	echo
	"$INIT_LINK" start >/dev/null 2>&1
	echo -e "${GREEN}zapret снова запущен.${NC}\n"
	PAUSE
}

run_benchmark_custom_domains() {
	require_installed || return
	clear
	echo -e "${MAGENTA}Тестирование по своим доменам${NC}\n"
	echo -ne "${YELLOW}Введите домены через пробел: ${NC}"
	read -r INPUT
	[ -z "$INPUT" ] && return
	echo
	for d in $INPUT; do check_url_one "$d" & done
	wait
	echo
	PAUSE
}

benchmark_menu() {
	while true; do
		clear
		echo -e "${MAGENTA}Бэнчмарк / тестирование стратегий${NC}\n"
		echo -e " ${CYAN}1${NC}) Проверить текущую стратегию (фикс. список доменов)"
		echo -e " ${CYAN}2${NC}) Проверить свои домены"
		echo -e " ${CYAN}3${NC}) Сравнить: с zapret / без zapret"
		echo -ne " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in
			1) run_benchmark_current ;;
			2) run_benchmark_custom_domains ;;
			3) run_benchmark_compare ;;
			'') return ;;
		esac
	done
}

# ==============================================================================
# ВЕБ-ДОСТУП К СКРИПТУ (ttyd через Entware)
# ==============================================================================

TTYD_BIN="$ENTWARE_ROOT/bin/ttyd"
TTYD_INIT="$ENTWARE_ROOT/etc/init.d/S54ttyd"
TTYD_PORT=7681
SCRIPT_SELF_PATH=""

web_access_is_enabled() {
	[ -x "$TTYD_INIT" ] && pgrep -f "ttyd.*-p $TTYD_PORT" >/dev/null 2>&1
}

web_access_install() {
	echo -e "\n${MAGENTA}Включаем веб-доступ к скрипту (ttyd)${NC}"
	if ! opkg list-installed 2>/dev/null | grep -q '^ttyd '; then
		echo -e "${CYAN}Устанавливаем ttyd${NC}"
		opkg update >/dev/null 2>&1
		opkg install ttyd >/dev/null 2>&1 || { echo -e "\n${RED}Не удалось установить ttyd через opkg. Возможно, пакет недоступен для этой архитектуры.${NC}\n"; PAUSE; return; }
	fi
	SELF="$(readlink -f "$0" 2>/dev/null)"
	[ -z "$SELF" ] && SELF="$0"
	cat > "$TTYD_INIT" <<INITEOF
#!/bin/sh
ENABLED=yes
PROCS=ttyd
ARGS="-p $TTYD_PORT -W sh $SELF"
PREARGS=""
DESC=\$PROCS
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /opt/etc/init.d/rc.func
INITEOF
	chmod +x "$TTYD_INIT"
	"$TTYD_INIT" start >/dev/null 2>&1
	IP="$(ip addr show br0 2>/dev/null | grep -m1 'inet ' | awk '{print $2}' | cut -d/ -f1)"
	[ -z "$IP" ] && IP="<IP роутера>"
	echo -e "${GREEN}Веб-доступ включен.${NC} Открой ${CYAN}http://$IP:$TTYD_PORT${NC} в браузере."
	echo -e "${YELLOW}Доступ без пароля в локальной сети — не открывай порт $TTYD_PORT в интернет.${NC}\n"
	PAUSE
}

web_access_remove() {
	echo -e "\n${MAGENTA}Отключаем веб-доступ${NC}"
	[ -x "$TTYD_INIT" ] && "$TTYD_INIT" stop >/dev/null 2>&1
	rm -f "$TTYD_INIT"
	echo -e "${GREEN}Отключено.${NC}\n"
	PAUSE
}

web_access_menu() {
	clear
	echo -e "${MAGENTA}Веб-доступ к скрипту${NC}\n"
	if web_access_is_enabled; then
		echo -e "Статус: ${GREEN}включен${NC} (порт $TTYD_PORT)"
		echo -ne "\n${CYAN}1${NC}) Отключить\n${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in 1) web_access_remove ;; esac
	else
		echo -e "Статус: ${RED}выключен${NC}"
		echo -ne "\n${CYAN}1${NC}) Включить\n${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in 1) web_access_install ;; esac
	fi
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ
# ==============================================================================

zapret_management_menu() {
	while true; do
		clear
		echo -e "${MAGENTA}Установка / обслуживание zapret${NC}\n"
		if is_installed; then
			V="$(get_installed_version)"
			is_running && echo -e "Статус: ${GREEN}установлен, запущен${NC} (v${V:-?})" || echo -e "Статус: ${YELLOW}установлен, не запущен${NC} (v${V:-?})"
		else
			echo -e "Статус: ${RED}не установлен${NC}"
		fi
		echo
		echo -e " ${GREEN}1${NC}) Установить"
		echo -e " ${GREEN}2${NC}) Обновить"
		echo -e " ${GREEN}3${NC}) Удалить"
		echo -e " ${GREEN}4${NC}) Запустить"
		echo -e " ${GREEN}5${NC}) Остановить"
		echo -e " ${GREEN}6${NC}) Перезапустить"
		echo -e " ${GREEN}7${NC}) Восстановить автозапуск"
		echo -e " ${GREEN}8${NC}) Статус / процессы"
		echo -e " ${GREEN}9${NC}) Редактировать конфиг"
		echo -ne " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in
			1) install_zapret ;; 2) update_zapret ;; 3) uninstall_zapret ;;
			4) start_zapret_action ;; 5) stop_zapret_action ;; 6) restart_zapret_action ;;
			7) fix_autostart ;; 8) show_status ;; 9) edit_config ;;
			'') return ;;
		esac
	done
}

strategies_menu() {
	while true; do
		require_installed || return
		clear
		echo -e "${MAGENTA}Меню стратегий обхода${NC}\n"
		show_current_strategy
		rkn_enabled && echo -e "${YELLOW}Список РКН:${NC} ${GREEN}включен${NC}"
		echo
		echo -e " ${CYAN}1${NC}) Готовые стратегии v1-v9"
		echo -e " ${CYAN}2${NC}) Стратегии Flowseal (discord/youtube)"
		echo -e " ${CYAN}3${NC}) Discord-стратегии (discord.media)"
		echo -e " ${CYAN}4${NC}) Список РКН (включить/выключить)"
		echo -ne " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in
			1) strategy_choose_builtin ;;
			2) flowseal_menu ;;
			3) discord_menu ;;
			4) rkn_menu ;;
			'') return ;;
		esac
	done
}

show_main_menu() {
	clear
	echo -e "${CYAN}==========================================${NC}"
	echo -e "${CYAN} Zapret Manager for Entware/Keenetic${NC}"
	echo -e "${CYAN} v$ZKM_VERSION  |  based on github.com/$REPO_OWNER/$REPO_NAME${NC}"
	echo -e "${CYAN}==========================================${NC}"
	if is_installed; then
		V="$(get_installed_version)"
		is_running && echo -e " Статус: ${GREEN}установлен, запущен${NC} ${DGRAY}(v${V:-?})${NC}" || echo -e " Статус: ${YELLOW}установлен, не запущен${NC} ${DGRAY}(v${V:-?})${NC}"
	else
		echo -e " Статус: ${RED}не установлен${NC}"
	fi
	echo
	echo -e " ${GREEN}1${NC}) Установка / обслуживание zapret"
	echo -e " ${GREEN}2${NC}) Стратегии обхода"
	echo -e " ${GREEN}3${NC}) Список РКН"
	echo -e " ${GREEN}4${NC}) Hosts-блоки (Instagram/Telegram/AI и др.)"
	echo -e " ${GREEN}5${NC}) TG-WS-Proxy (Telegram прокси)"
	echo -e " ${GREEN}6${NC}) Бэнчмарк / тестирование стратегий"
	echo -e " ${GREEN}7${NC}) Веб-доступ к скрипту"
	echo -e " ${GREEN}0${NC}) Выход"
	echo
	echo -ne "Выбор: "
}

check_root
while true; do
	show_main_menu
	read CHOICE
	case "$CHOICE" in
		1) zapret_management_menu ;;
		2) strategies_menu ;;
		3) rkn_menu ;;
		4) hosts_menu ;;
		5) tg_ws_menu ;;
		6) benchmark_menu ;;
		7) web_access_menu ;;
		0) exit 0 ;;
		*) ;;
	esac
done
