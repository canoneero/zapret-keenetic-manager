#!/bin/sh
# ==========================================================================
# NFQWS Manager for Keenetic/Entware (aarch64)
# Based on nfqws/nfqws-keenetic (https://github.com/nfqws/nfqws-keenetic)
# Engine: classic bol-van/zapret (nfqws) -- 1:1 syntax with Flowseal/Zapret-Manager
# ==========================================================================
ZKM_VERSION="4.0"

GREEN="\033[1;32m"; RED="\033[1;31m"; CYAN="\033[1;36m"; YELLOW="\033[1;33m"; MAGENTA="\033[1;35m"; NC="\033[0m"; DGRAY="\033[38;5;244m"

# ---- paths -----------------------------------------------------------------
ENTWARE_ROOT="/opt"
PKG_NAME="nfqws-keenetic"
NFQWS_DIR="$ENTWARE_ROOT/etc/nfqws"
NFQWS_CONF="$NFQWS_DIR/nfqws.conf"
LIST_USER="$NFQWS_DIR/user.list"
LIST_AUTO="$NFQWS_DIR/auto.list"
LIST_EXCLUDE="$NFQWS_DIR/exclude.list"
LIST_IPSET="$NFQWS_DIR/ipset.list"
LIST_IPSET_EXCLUDE="$NFQWS_DIR/ipset_exclude.list"
FAKE_DIR="$NFQWS_DIR/fake"
INIT_SCRIPT="$ENTWARE_ROOT/etc/init.d/S51nfqws"
BINFILE="$ENTWARE_ROOT/usr/bin/nfqws"
PIDFILE="$ENTWARE_ROOT/var/run/nfqws.pid"
LOGFILE="$ENTWARE_ROOT/var/log/nfqws.log"

OPKG_FEED_FILE="$ENTWARE_ROOT/etc/opkg/nfqws-keenetic.conf"
OPKG_FEED_BASE="https://nfqws.github.io/nfqws-keenetic"
OPKG_FEED_ARCH="aarch64"   # repo универсальный (/all), но конкретная арх-фид экономит трафик при update
OPKG_FEED_URL="$OPKG_FEED_BASE/$OPKG_FEED_ARCH"

ZKM_DIR="$ENTWARE_ROOT/nfqws_manager"
BACKUP_DIR="$ENTWARE_ROOT/nfqws_backup"
STATE_FILE="$ZKM_DIR/state"

mkdir -p "$ZKM_DIR" 2>/dev/null

# ---- helpers -----------------------------------------------------------------
PAUSE() { printf '%s' "Нажмите Enter..."; read dummy; }

check_root() {
	if [ "$(id -u)" != "0" ]; then
		printf '%s\n' "${RED}Скрипт нужно запускать от root (на Keenetic — через SSH/telnet, порт 222, пользователь root).${NC}"
		exit 1
	fi
}

check_entware() {
	if [ ! -x "$ENTWARE_ROOT/bin/opkg" ]; then
		printf '%s\n' "${RED}Entware (opkg) не найден в $ENTWARE_ROOT/bin/opkg.${NC}"
		printf '%s\n' "${YELLOW}Установи Entware на Keenetic перед использованием этого скрипта.${NC}"
		exit 1
	fi
	export PATH="$ENTWARE_ROOT/bin:$ENTWARE_ROOT/sbin:$ENTWARE_ROOT/usr/bin:$ENTWARE_ROOT/usr/sbin:$PATH"
}

is_installed() { [ -f "$NFQWS_CONF" ] && [ -f "$INIT_SCRIPT" ]; }
is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }

require_installed() {
	if ! is_installed; then
		printf '%s\n' "\n${RED}nfqws-keenetic не установлен!${NC}\n"
		PAUSE
		return 1
	fi
	return 0
}

get_installed_version() {
	opkg list-installed 2>/dev/null | grep "^$PKG_NAME " | awk '{print $3}'
}

get_available_version() {
	opkg list 2>/dev/null | grep "^$PKG_NAME " | awk '{print $3}'
}

SERVICE() {
	# $1 = start|stop|restart|reload|status
	[ -x "$INIT_SCRIPT" ] && "$INIT_SCRIPT" "$1"
}

get_conf_var() {
	grep -m1 "^${1}=" "$NFQWS_CONF" 2>/dev/null | sed -E "s/^${1}=//; s/^\"//; s/\"\$//"
}

# Замена простой (однострочной) переменной вида VAR="значение"
set_conf_var_simple() {
	VAR="$1"; VAL="$2"
	if grep -q "^${VAR}=" "$NFQWS_CONF" 2>/dev/null; then
		sed -i "s|^${VAR}=.*|${VAR}=\"${VAL}\"|" "$NFQWS_CONF"
	else
		echo "${VAR}=\"${VAL}\"" >> "$NFQWS_CONF"
	fi
}

# Замена многострочной переменной вида VAR="...\n...\n..." (как NFQWS_ARGS, NFQWS_ARGS_CUSTOM)
set_conf_var_multiline() {
	VAR="$1"; BODY="$2"
	TMP="$ZKM_DIR/conf.tmp"
	awk -v var="$VAR" -v body="$BODY" '
		BEGIN { inblock=0; done=0; pat="^" var "=\"" }
		{
			if (inblock==0 && $0 ~ pat) {
				print var "=\"" body "\""
				inblock=1
				done=1
				if ($0 ~ /"[[:space:]]*$/ && length($0) > length(var "=\"")) { inblock=0 }
				next
			}
			if (inblock==1) {
				if ($0 ~ /"[[:space:]]*$/) { inblock=0 }
				next
			}
			print
		}
		END { if (done==0) print var "=\"" body "\"" }
	' "$NFQWS_CONF" > "$TMP" && mv "$TMP" "$NFQWS_CONF"
}

# ==============================================================================
# УСТАНОВКА / ОБНОВЛЕНИЕ / УДАЛЕНИЕ
# ==============================================================================

setup_feed() {
	mkdir -p "$ENTWARE_ROOT/etc/opkg"
	echo "src/gz nfqws-keenetic $OPKG_FEED_URL" > "$OPKG_FEED_FILE"
}

install_deps() {
	printf '%s\n' "${CYAN}Проверяем зависимости (ca-certificates, wget-ssl)${NC}"
	opkg update >/dev/null 2>&1
	opkg list-installed 2>/dev/null | grep -q '^ca-certificates ' || opkg install ca-certificates >/dev/null 2>&1
	opkg list-installed 2>/dev/null | grep -q '^wget-ssl ' || opkg install wget-ssl >/dev/null 2>&1
	opkg list-installed 2>/dev/null | grep -q '^wget-nossl ' && opkg remove wget-nossl >/dev/null 2>&1
}

install_nfqws() {
	check_entware
	if is_installed; then
		printf '%s\n' "\n${YELLOW}nfqws-keenetic уже установлен (версия: $(get_installed_version)).${NC}"
		printf '%s\n' "Используй пункт обновления, если хочешь поставить новую версию.\n"
		PAUSE
		return
	fi
	printf '%s\n' "\n${MAGENTA}Устанавливаем nfqws-keenetic${NC}"
	install_deps
	setup_feed
	printf '%s\n' "${CYAN}Обновляем индекс пакетов${NC}"
	opkg update >/dev/null 2>&1
	printf '%s\n' "${CYAN}Устанавливаем пакет${NC}"
	opkg install "$PKG_NAME"
	INSTALL_RC=$?
	if [ $INSTALL_RC -ne 0 ] || ! is_installed; then
		printf '%s\n' "\n${RED}Установка не завершилась успешно (код $INSTALL_RC).${NC}"
		printf '%s\n' "${YELLOW}Смотри вывод opkg выше. Частые причины: не установлен пакет 'Модули ядра подсистемы Netfilter'${NC}"
		printf '%s\n' "${YELLOW}в веб-интерфейсе Keenetic (OPKG > Kernel modules for Netfilter).${NC}\n"
		PAUSE
		return
	fi
	printf '%s\n' "\n${GREEN}nfqws-keenetic установлен и запущен.${NC}"
	printf '%s\n' "${DGRAY}ISP-интерфейс и поддержка IPv6 определены автоматически (см. $NFQWS_CONF).${NC}\n"
	PAUSE
}

update_nfqws() {
	check_entware
	require_installed || return
	OLD_VER="$(get_installed_version)"
	printf '%s\n' "\n${CYAN}Текущая версия: ${NC}${OLD_VER:-неизвестна}"
	printf '%s\n' "${MAGENTA}Обновляем nfqws-keenetic${NC}"
	[ -f "$OPKG_FEED_FILE" ] || setup_feed
	opkg update >/dev/null 2>&1
	AVAIL_VER="$(get_available_version)"
	if [ -n "$AVAIL_VER" ]; then
		printf '%s\n' "${CYAN}Доступная версия: ${NC}$AVAIL_VER"
	fi
	printf '%s\n' "${CYAN}Конфиг и списки доменов сохранятся автоматически (защищены opkg как conffiles)${NC}"
	opkg upgrade "$PKG_NAME"
	UPGRADE_RC=$?
	if [ $UPGRADE_RC -ne 0 ]; then
		printf '%s\n' "\n${RED}Обновление завершилось с ошибкой (код $UPGRADE_RC).${NC}\n"
		PAUSE
		return
	fi
	printf '%s\n' "\n${GREEN}Обновление завершено: ${OLD_VER:-?} -> $(get_installed_version)${NC}\n"
	PAUSE
}

uninstall_nfqws() {
	require_installed || return
	printf '%s' "\n${RED}Удалить nfqws-keenetic полностью? (y/N): ${NC}"
	read CONFIRM
	case "$CONFIRM" in y|Y|yes|Yes) ;; *) printf '%s\n' "${YELLOW}Отменено.${NC}\n"; return ;; esac
	printf '%s' "${CYAN}Сохранить бэкап конфига и списков перед удалением? (Y/n): ${NC}"
	read DOBACKUP
	case "$DOBACKUP" in n|N|no|No) ;; *) backup_settings ;; esac
	printf '%s\n' "${MAGENTA}Удаляем nfqws-keenetic${NC}"
	opkg remove "$PKG_NAME"
	printf '%s\n' "${GREEN}nfqws-keenetic удалён.${NC}\n"
	PAUSE
}

backup_settings() {
	[ -d "$NFQWS_DIR" ] || return
	mkdir -p "$BACKUP_DIR"
	printf '%s\n' "${CYAN}Делаем резервную копию конфига, списков и fake-файлов${NC}"
	BK="$BACKUP_DIR/nfqws_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
	( cd "$NFQWS_DIR" && tar -czf "$BK" nfqws.conf user.list auto.list exclude.list ipset.list ipset_exclude.list fake 2>/dev/null )
	if [ -s "$BK" ]; then
		printf '%s\n' "${GREEN}Бэкап сохранён: $BK${NC}"
		ls -t "$BACKUP_DIR"/nfqws_backup_*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
	else
		rm -f "$BK"
	fi
}

restore_settings() {
	LATEST_BK="$(ls -t "$BACKUP_DIR"/nfqws_backup_*.tar.gz 2>/dev/null | head -n1)"
	if [ -z "$LATEST_BK" ]; then
		printf '%s\n' "\n${YELLOW}Бэкапов не найдено.${NC}\n"
		PAUSE
		return
	fi
	printf '%s\n' "\n${CYAN}Восстанавливаем из: ${NC}$LATEST_BK"
	mkdir -p "$NFQWS_DIR"
	tar -xzf "$LATEST_BK" -C "$NFQWS_DIR" 2>/dev/null
	printf '%s\n' "${GREEN}Восстановлено.${NC}"
	printf '%s' "${CYAN}Перезапустить сервис? (Y/n): ${NC}"
	read R
	case "$R" in n|N) ;; *) SERVICE restart ;; esac
	echo
	PAUSE
}

start_action() { SERVICE start; PAUSE; }
stop_action() { SERVICE stop; PAUSE; }
restart_action() { SERVICE restart; PAUSE; }
reload_action() { SERVICE reload; PAUSE; }

show_status() {
	printf '%s\n' "\n${CYAN}=== Статус nfqws-keenetic ===${NC}"
	if is_installed; then
		printf '%s\n' "Установлен: ${GREEN}да${NC}  Версия: $(get_installed_version 2>/dev/null || echo неизвестна)"
		printf '%s\n' "ISP интерфейс: $(get_conf_var ISP_INTERFACE)"
		printf '%s\n' "IPv6: $(get_conf_var IPV6_ENABLED)"
		printf '%s\n' "Режим: $(grep -m1 '^NFQWS_EXTRA_ARGS=' "$NFQWS_CONF" 2>/dev/null | grep -o 'MODE_[A-Z]*' | head -1)"
		printf '%s\n' "Policy: $(get_conf_var POLICY_NAME) (exclude=$(get_conf_var POLICY_EXCLUDE))"
	else
		printf '%s\n' "Установлен: ${RED}нет${NC}"
	fi
	if is_running; then
		printf '%s\n' "Процесс: ${GREEN}запущен${NC} (PID $(cat "$PIDFILE" 2>/dev/null))"
	else
		printf '%s\n' "Процесс: ${RED}не запущен${NC}"
	fi
	if [ -f "$NFQWS_CONF" ]; then
		printf '%s\n' "\n${DGRAY}Активные правила iptables:${NC}"
		iptables-save 2>/dev/null | grep -i nfqws | sed 's/^/  /'
	fi
	echo
	PAUSE
}

show_logs() {
	if [ ! -f "$LOGFILE" ]; then
		printf '%s\n' "\n${YELLOW}Лог-файл не найден: $LOGFILE${NC}\n"
		PAUSE
		return
	fi
	printf '%s\n' "\n${CYAN}=== Последние 40 строк лога автоопределения доменов ===${NC}\n"
	tail -n 40 "$LOGFILE"
	echo
	PAUSE
}

edit_config() {
	require_installed || return
	EDITOR_BIN="$(command -v nano || command -v vi)"
	if [ -z "$EDITOR_BIN" ]; then printf '%s\n' "${RED}Не найден nano/vi. Установи: opkg install nano${NC}"; PAUSE; return; fi
	"$EDITOR_BIN" "$NFQWS_CONF"
	printf '%s' "${CYAN}Перезапустить сервис? (Y/n): ${NC}"
	read R
	case "$R" in n|N) ;; *) SERVICE restart ;; esac
	PAUSE
}

# ==============================================================================
# РЕЖИМЫ РАБОТЫ (auto / list / all)
# ==============================================================================

set_mode() {
	# $1 = MODE_AUTO|MODE_LIST|MODE_ALL
	require_installed || return
	set_conf_var_simple_raw "NFQWS_EXTRA_ARGS" "\$$1"
	SERVICE restart
}

# для NFQWS_EXTRA_ARGS значение - это ссылка на другую переменную ($MODE_AUTO), без доп. кавычек внутри
set_conf_var_simple_raw() {
	VAR="$1"; VAL="$2"
	if grep -q "^${VAR}=" "$NFQWS_CONF" 2>/dev/null; then
		sed -i "s|^${VAR}=.*|${VAR}=\"${VAL}\"|" "$NFQWS_CONF"
	else
		echo "${VAR}=\"${VAL}\"" >> "$NFQWS_CONF"
	fi
}

mode_menu() {
	require_installed || return
	CUR="$(grep -m1 '^NFQWS_EXTRA_ARGS=' "$NFQWS_CONF" 2>/dev/null | grep -o 'MODE_[A-Z]*' | head -1)"
	clear
	printf '%s\n' "${MAGENTA}Режим обработки трафика${NC}\n"
	printf '%s\n' "Текущий режим: ${CYAN}${CUR:-неизвестен}${NC}\n"
	printf '%s\n' " ${GREEN}1${NC}) auto — автоопределение блокировок + user.list ${DGRAY}(рекомендуется)${NC}"
	printf '%s\n' " ${GREEN}2${NC}) list — только домены из user.list"
	printf '%s\n' " ${GREEN}3${NC}) all  — весь трафик кроме exclude.list ${DGRAY}(агрессивно, может что-то поломать)${NC}"
	printf '%s' " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
	read CH
	case "$CH" in
		1) set_mode "MODE_AUTO"; printf '%s\n' "\n${GREEN}Режим: auto${NC}\n"; PAUSE ;;
		2) set_mode "MODE_LIST"; printf '%s\n' "\n${GREEN}Режим: list${NC}\n"; PAUSE ;;
		3) set_mode "MODE_ALL"; printf '%s\n' "\n${GREEN}Режим: all${NC}\n"; PAUSE ;;
	esac
}

# ==============================================================================
# СПИСКИ ДОМЕНОВ (user / auto / exclude)
# ==============================================================================

list_show() {
	# $1 = путь к файлу, $2 = имя для заголовка
	clear
	printf '%s\n' "${MAGENTA}$2${NC} ${DGRAY}($1)${NC}\n"
	if [ -s "$1" ]; then
		cat -n "$1"
	else
		printf '%s\n' "${YELLOW}(пусто)${NC}"
	fi
	echo
	PAUSE
}

list_add_domain() {
	# $1 = путь к файлу, $2 = имя для заголовка
	printf '%s' "\n${CYAN}Введи домен для добавления в $2: ${NC}"
	read DOMAIN
	[ -z "$DOMAIN" ] && return
	mkdir -p "$(dirname "$1")"
	if grep -Fxq "$DOMAIN" "$1" 2>/dev/null; then
		printf '%s\n' "${YELLOW}Домен уже есть в списке.${NC}\n"
	else
		echo "$DOMAIN" >> "$1"
		printf '%s\n' "${GREEN}Добавлено: $DOMAIN${NC}\n"
	fi
	PAUSE
}

list_remove_domain() {
	# $1 = путь к файлу, $2 = имя для заголовка
	printf '%s' "\n${CYAN}Введи домен для удаления из $2: ${NC}"
	read DOMAIN
	[ -z "$DOMAIN" ] && return
	if [ -f "$1" ] && grep -Fxq "$DOMAIN" "$1"; then
		sed -i "\\|^$(printf '%s' "$DOMAIN" | sed 's/[.[\*^$/]/\\&/g')\$|d" "$1"
		printf '%s\n' "${GREEN}Удалено: $DOMAIN${NC}\n"
	else
		printf '%s\n' "${YELLOW}Домен не найден в списке.${NC}\n"
	fi
	PAUSE
}

list_clear() {
	# $1 = путь к файлу, $2 = имя
	printf '%s' "\n${RED}Очистить весь список $2? (y/N): ${NC}"
	read C
	case "$C" in
		y|Y) : > "$1"; printf '%s\n' "${GREEN}Очищено.${NC}\n" ;;
		*) printf '%s\n' "${YELLOW}Отменено.${NC}\n" ;;
	esac
	PAUSE
}

generic_list_menu() {
	# $1 = путь, $2 = имя, $3 = editable(1/0)
	LPATH="$1"; LNAME="$2"; EDITABLE="$3"
	while true; do
		clear
		COUNT="$( [ -f "$LPATH" ] && grep -c . "$LPATH" 2>/dev/null || echo 0)"
		printf '%s\n' "${MAGENTA}$LNAME${NC} ${DGRAY}(доменов: $COUNT)${NC}\n"
		printf '%s\n' " ${CYAN}1${NC}) Показать список"
		if [ "$EDITABLE" = "1" ]; then
			printf '%s\n' " ${CYAN}2${NC}) Добавить домен"
			printf '%s\n' " ${CYAN}3${NC}) Удалить домен"
			printf '%s\n' " ${CYAN}4${NC}) Очистить список"
		fi
		printf '%s' " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in
			1) list_show "$LPATH" "$LNAME" ;;
			2) [ "$EDITABLE" = "1" ] && list_add_domain "$LPATH" "$LNAME" ;;
			3) [ "$EDITABLE" = "1" ] && list_remove_domain "$LPATH" "$LNAME" ;;
			4) [ "$EDITABLE" = "1" ] && list_clear "$LPATH" "$LNAME" ;;
			'') return ;;
		esac
	done
}

lists_menu() {
	require_installed || return
	while true; do
		clear
		printf '%s\n' "${MAGENTA}Списки доменов${NC}\n"
		printf '%s\n' " ${GREEN}1${NC}) user.list — домены вручную ${DGRAY}(редактируемый)${NC}"
		printf '%s\n' " ${GREEN}2${NC}) auto.list — автоопределённые блокировки ${DGRAY}(только просмотр)${NC}"
		printf '%s\n' " ${GREEN}3${NC}) exclude.list — исключения ${DGRAY}(редактируемый)${NC}"
		printf '%s\n' " ${GREEN}4${NC}) ipset.list — IP/CIDR для обработки ${DGRAY}(редактируемый)${NC}"
		printf '%s\n' " ${GREEN}5${NC}) ipset_exclude.list — IP/CIDR исключения ${DGRAY}(редактируемый)${NC}"
		printf '%s' " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in
			1) generic_list_menu "$LIST_USER" "user.list" 1 ;;
			2) generic_list_menu "$LIST_AUTO" "auto.list" 0 ;;
			3) generic_list_menu "$LIST_EXCLUDE" "exclude.list" 1 ;;
			4) generic_list_menu "$LIST_IPSET" "ipset.list" 1 ;;
			5) generic_list_menu "$LIST_IPSET_EXCLUDE" "ipset_exclude.list" 1 ;;
			'') return ;;
		esac
	done
}

# ==============================================================================
# KEENETIC POLICY (политика доступа в веб-интерфейсе)
# ==============================================================================

policy_menu() {
	require_installed || return
	clear
	CUR_NAME="$(get_conf_var POLICY_NAME)"
	CUR_EXCLUDE="$(get_conf_var POLICY_EXCLUDE)"
	printf '%s\n' "${MAGENTA}Keenetic-политика доступа${NC}\n"
	printf '%s\n' "Текущее имя политики: ${CYAN}${CUR_NAME:-не задано}${NC}"
	if [ "$CUR_EXCLUDE" = "1" ]; then
		printf '%s\n' "Режим: ${YELLOW}исключение${NC} (трафик из политики НЕ обрабатывается)"
	else
		printf '%s\n' "Режим: ${GREEN}включение${NC} (обрабатывается только трафик из политики)"
	fi
	printf '%s\n' "\n${DGRAY}Создай политику с таким именем в веб-интерфейсе Keenetic:${NC}"
	printf '%s\n' "${DGRAY}Приоритеты подключений -> Политики доступа в интернет${NC}"
	printf '%s\n' "${DGRAY}Если политика с таким именем не найдена — обрабатывается весь трафик.${NC}\n"
	printf '%s\n' " ${CYAN}1${NC}) Изменить имя политики"
	printf '%s\n' " ${CYAN}2${NC}) Переключить режим (включение/исключение)"
	printf '%s' " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
	read CH
	case "$CH" in
		1)
			printf '%s' "\n${CYAN}Новое имя политики: ${NC}"
			read NEWNAME
			[ -n "$NEWNAME" ] && { set_conf_var_simple "POLICY_NAME" "$NEWNAME"; SERVICE restart; printf '%s\n' "\n${GREEN}Готово${NC}"; }
			echo; PAUSE
			;;
		2)
			NEWVAL=1
			[ "$CUR_EXCLUDE" = "1" ] && NEWVAL=0
			sed -i "s|^POLICY_EXCLUDE=.*|POLICY_EXCLUDE=$NEWVAL|" "$NFQWS_CONF"
			SERVICE restart
			printf '%s\n' "\n${GREEN}Режим изменён${NC}\n"
			PAUSE
			;;
	esac
}

# ==============================================================================
# IPV6 / ИНТЕРФЕЙС / ПОРТЫ
# ==============================================================================

network_menu() {
	require_installed || return
	clear
	printf '%s\n' "${MAGENTA}Сетевые настройки${NC}\n"
	printf '%s\n' "ISP интерфейс: ${CYAN}$(get_conf_var ISP_INTERFACE)${NC}"
	printf '%s\n' "IPv6: ${CYAN}$(get_conf_var IPV6_ENABLED)${NC}"
	printf '%s\n' "TCP порты: ${CYAN}$(get_conf_var TCP_PORTS)${NC}"
	printf '%s\n' "UDP порты: ${CYAN}$(get_conf_var UDP_PORTS)${NC}"
	echo
	printf '%s\n' " ${CYAN}1${NC}) Переопределить ISP-интерфейс вручную"
	printf '%s\n' " ${CYAN}2${NC}) Переопределить автоматически (как при первой установке)"
	printf '%s\n' " ${CYAN}3${NC}) Включить/выключить IPv6"
	printf '%s' " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
	read CH
	case "$CH" in
		1)
			printf '%s' "\n${CYAN}Введи интерфейс(ы) через пробел (напр. eth3 или eth2.2): ${NC}"
			read IFACE
			[ -n "$IFACE" ] && { set_conf_var_simple "ISP_INTERFACE" "$IFACE"; SERVICE restart; printf '%s\n' "\n${GREEN}Готово${NC}"; }
			echo; PAUSE
			;;
		2)
			DEF_IFACE="$(route 2>/dev/null | grep '^default' | grep -o '[^ ]*$')"
			if [ -n "$DEF_IFACE" ]; then
				set_conf_var_simple "ISP_INTERFACE" "$DEF_IFACE"
				SERVICE restart
				printf '%s\n' "\n${GREEN}Определён интерфейс: $DEF_IFACE${NC}\n"
			else
				printf '%s\n' "\n${RED}Не удалось определить интерфейс автоматически.${NC}\n"
			fi
			PAUSE
			;;
		3)
			CUR_IPV6="$(get_conf_var IPV6_ENABLED)"
			NEWVAL=1
			[ "$CUR_IPV6" = "1" ] && NEWVAL=0
			sed -i "s|^IPV6_ENABLED=.*|IPV6_ENABLED=$NEWVAL|" "$NFQWS_CONF"
			SERVICE restart
			printf '%s\n' "\n${GREEN}IPv6: $NEWVAL${NC}\n"
			PAUSE
			;;
	esac
}

# ==============================================================================
# КАСТОМНЫЕ СТРАТЕГИИ (NFQWS_ARGS_CUSTOM)
# ==============================================================================

custom_strategy_menu() {
	require_installed || return
	clear
	CUR="$(get_conf_var NFQWS_ARGS_CUSTOM)"
	printf '%s\n' "${MAGENTA}Кастомная стратегия (NFQWS_ARGS_CUSTOM)${NC}\n"
	if [ -n "$CUR" ]; then
		printf '%s\n' "${CYAN}Текущее значение:${NC}\n$CUR\n"
	else
		printf '%s\n' "${DGRAY}Не задано${NC}\n"
	fi
	printf '%s\n' "${DGRAY}Пример: --filter-tcp=80 --dpi-desync=fakedsplit --new --filter-tcp=443 --dpi-desync=fake${NC}"
	printf '%s\n' "${DGRAY}Несколько блоков разделяются через --new${NC}\n"
	printf '%s\n' " ${CYAN}1${NC}) Задать новое значение"
	printf '%s\n' " ${CYAN}2${NC}) Очистить"
	printf '%s' " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
	read CH
	case "$CH" in
		1)
			printf '%s' "\n${CYAN}Введи аргументы: ${NC}"
			read -r NEWARGS
			set_conf_var_simple "NFQWS_ARGS_CUSTOM" "$NEWARGS"
			SERVICE restart
			printf '%s\n' "\n${GREEN}Применено${NC}\n"
			PAUSE
			;;
		2)
			set_conf_var_simple "NFQWS_ARGS_CUSTOM" ""
			SERVICE restart
			printf '%s\n' "\n${GREEN}Очищено${NC}\n"
			PAUSE
			;;
	esac
}

# ==============================================================================
# FAKE-BLOB ФАЙЛЫ (tls_clienthello_*.bin, quic_initial_*.bin, stun.bin, ...)
# Стандартная поставка nfqws-keenetic несёт только quic_initial.bin/tls_clienthello.bin.
# Стратегии v1-v9/Discord/Flowseal используют доп. blob-файлы из репозитория Flowseal.
# ==============================================================================

FLOWSEAL_BIN_RAW="https://github.com/Flowseal/zapret-discord-youtube/raw/refs/heads/main/bin"

# Карта: локальное_имя_файла|оригинальное_имя_в_Flowseal_bin
FAKE_FILE_MAP="
4pda.bin|tls_clienthello_4pda_to.bin
quic_initial_dbankcloud_ru.bin|quic_initial_dbankcloud_ru.bin
quic_initial_www_google_com.bin|quic_initial_www_google_com.bin
stun.bin|stun.bin
tls_clienthello_www_google_com.bin|tls_clienthello_www_google_com.bin
tls_clienthello_www_onetrust_com.bin|tls_clienthello_max_ru.bin
"
# Известно отсутствующие в Flowseal/bin и в репозитории StressOzz файлы (нужны только strategy_v3):
FAKE_FILES_MISSING="t2.bin tls_clienthello_vk_com.bin tls_clienthello_gosuslugi_ru.bin"

fake_file_path() { echo "$FAKE_DIR/$1"; }

is_fake_file_missing() {
	for m in $FAKE_FILES_MISSING; do [ "$m" = "$1" ] && return 0; done
	return 1
}

ensure_fake_file() {
	# $1 = локальное имя файла, нужное стратегии
	LOCALNAME="$1"
	DEST="$(fake_file_path "$LOCALNAME")"
	[ -s "$DEST" ] && return 0
	if is_fake_file_missing "$LOCALNAME"; then
		return 1
	fi
	REMOTENAME="$(echo "$FAKE_FILE_MAP" | awk -F'|' -v n="$LOCALNAME" '$1==n{print $2}')"
	[ -z "$REMOTENAME" ] && REMOTENAME="$LOCALNAME"
	mkdir -p "$FAKE_DIR"
	curl -fsSL "$FLOWSEAL_BIN_RAW/$REMOTENAME" -o "$DEST" 2>/dev/null
	if [ -s "$DEST" ]; then
		return 0
	else
		rm -f "$DEST"
		return 1
	fi
}

# Скачивает все fake-файлы, упоминающиеся в тексте стратегии (по путям $FAKE_DIR/имя.bin)
ensure_fake_files_for_strategy() {
	BLOCK="$1"
	MISSING=""
	for FNAME in $(printf '%s' "$BLOCK" | grep -oE "$(printf '%s' "$FAKE_DIR" | sed 's/[.[\*^$/]/\\&/g')/[A-Za-z0-9_.]+\.bin" | sed "s#.*/##" | sort -u); do
		if ! ensure_fake_file "$FNAME"; then
			MISSING="$MISSING $FNAME"
		fi
	done
	[ -n "$MISSING" ] && { printf '%s\n' "${RED}Не удалось получить файлы:${NC}$MISSING"; return 1; }
	return 0
}

# ==============================================================================
# СТАТИЧНЫЕ СТРАТЕГИИ v1-v9 (перенесены из оригинального Zapret-Manager)
# Пути /opt/zapret/files/fake/* переотображены на $FAKE_DIR
# Пути /opt/zapret/ipset/zapret-hosts-*.txt переотображены на списки nfqws-keenetic
# ==============================================================================

strategy_v1() { printf '%s\n' \
"--filter-tcp=443" "--hostlist=$LIST_USER" "--dpi-desync=hostfakesplit" "--dpi-desync-hostfakesplit-mod=host=google.com" "--dpi-desync-fooling=ts" \
"--new" "--filter-tcp=443" "--hostlist-exclude=$LIST_EXCLUDE" "--dpi-desync=split2" "--dpi-desync-split-seqovl=681" "--dpi-desync-split-seqovl-pattern=$(fake_file_path stun.bin)"
}
strategy_v2() { printf '%s\n' \
"--filter-tcp=443" "--hostlist=$LIST_USER" "--dpi-desync=hostfakesplit" "--dpi-desync-hostfakesplit-mod=host=google.com" "--dpi-desync-fooling=ts" \
"--new" "--filter-tcp=443" "--hostlist-exclude=$LIST_EXCLUDE" "--dpi-desync=fake,multisplit" "--dpi-desync-split-seqovl=681" "--dpi-desync-split-pos=1" "--dpi-desync-fooling=ts" "--dpi-desync-repeats=8" "--dpi-desync-split-seqovl-pattern=$(fake_file_path stun.bin)" "--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"
}
strategy_v3() { printf '%s\n' \
"--filter-tcp=443" "--hostlist=$LIST_USER" "--dpi-desync=hostfakesplit" "--dpi-desync-hostfakesplit-mod=host=google.com" "--dpi-desync-fooling=ts" \
"--new" "--filter-tcp=443" "--hostlist-exclude=$LIST_EXCLUDE" "--dpi-desync=fake,fakeddisorder" "--dpi-desync-split-pos=10,midsld" "--dpi-desync-fake-tls=$(fake_file_path t2.bin)" \
"--dpi-desync-fake-tls-mod=rnd,dupsid,sni=m.ok.ru" "--dpi-desync-fake-tls=0x0F0F0F0F" "--dpi-desync-fake-tls-mod=none" "--dpi-desync-fakedsplit-pattern=$(fake_file_path tls_clienthello_vk_com.bin)" \
"--dpi-desync-split-seqovl=336" "--dpi-desync-split-seqovl-pattern=$(fake_file_path tls_clienthello_gosuslugi_ru.bin)" "--dpi-desync-fooling=badseq,badsum" "--dpi-desync-badseq-increment=0" \
"--new" "--filter-udp=443" "--hostlist-exclude=$LIST_EXCLUDE" "--dpi-desync=fake" "--dpi-desync-repeats=6" "--dpi-desync-fake-quic=$(fake_file_path quic_initial_www_google_com.bin)"
}
strategy_v4() { printf '%s\n' \
"--filter-tcp=443" "--hostlist=$LIST_USER" "--dpi-desync=hostfakesplit" "--dpi-desync-hostfakesplit-mod=host=google.com" "--dpi-desync-fooling=ts" \
"--new" "--filter-tcp=443" "--hostlist-exclude=$LIST_EXCLUDE" "--dpi-desync=multisplit" "--dpi-desync-split-seqovl=582" "--dpi-desync-split-pos=1" "--dpi-desync-split-seqovl-pattern=$(fake_file_path stun.bin)" \
"--new" "--filter-udp=443" "--hostlist-exclude=$LIST_EXCLUDE" "--dpi-desync=fake" "--dpi-desync-repeats=6" "--dpi-desync-fake-quic=$(fake_file_path quic_initial_www_google_com.bin)"
}
strategy_v5() { printf '%s\n' \
"--filter-tcp=443" "--hostlist=$LIST_USER" "--dpi-desync=hostfakesplit" "--dpi-desync-hostfakesplit-mod=host=google.com" "--dpi-desync-fooling=ts" \
"--new" "--filter-tcp=443" "--hostlist-exclude=$LIST_EXCLUDE" "--dpi-desync=fake,fakeddisorder" "--dpi-desync-split-pos=1" "--dpi-desync-fake-tls=$(fake_file_path stun.bin)" "--dpi-desync-fake-tls-mod=none" "--dpi-desync-fakedsplit-pattern=$(fake_file_path tls_clienthello_www_google_com.bin)" "--dpi-desync-fooling=badseq,badsum" "--dpi-desync-badseq-increment=0" \
"--new" "--filter-udp=443" "--hostlist-exclude=$LIST_EXCLUDE" "--dpi-desync=fake" "--dpi-desync-repeats=6" "--dpi-desync-fake-quic=$(fake_file_path quic_initial_www_google_com.bin)"
}
strategy_v6() { printf '%s\n' \
"--filter-tcp=443" "--hostlist=$LIST_USER" "--dpi-desync=hostfakesplit" "--dpi-desync-hostfakesplit-mod=host=google.com" "--dpi-desync-fooling=ts" \
"--new" "--filter-tcp=443" "--hostlist-exclude=$LIST_EXCLUDE" "--dpi-desync=hostfakesplit" "--dpi-desync-hostfakesplit-mod=host=i2.photo.2gis.com" "--dpi-desync-hostfakesplit-midhost=host-2" "--dpi-desync-split-seqovl=726" "--dpi-desync-fooling=badsum,badseq" "--dpi-desync-badseq-increment=0"
}
strategy_v7() { printf '%s\n' \
"--filter-tcp=443" "--hostlist=$LIST_USER" "--dpi-desync=hostfakesplit" "--dpi-desync-hostfakesplit-mod=host=google.com" "--dpi-desync-fooling=ts" \
"--new" "--filter-tcp=443" "--hostlist-exclude=$LIST_EXCLUDE" "--dpi-desync=fake,multisplit" "--dpi-desync-split-seqovl=654" "--dpi-desync-split-pos=1" "--dpi-desync-fooling=badseq,badsum" "--dpi-desync-repeats=8" "--dpi-desync-split-seqovl-pattern=$(fake_file_path stun.bin)" "--dpi-desync-fake-tls=$(fake_file_path stun.bin)" "--dpi-desync-badseq-increment=0"
}
strategy_v8() { printf '%s\n' \
"--filter-tcp=443" "--hostlist=$LIST_USER" "--dpi-desync=hostfakesplit" "--dpi-desync-hostfakesplit-mod=host=google.com" "--dpi-desync-fooling=ts" \
"--new" "--filter-tcp=443" "--hostlist-exclude=$LIST_EXCLUDE" "--dpi-desync=fake" "--dpi-desync-fooling=ts" "--dpi-desync-fake-tls=$(fake_file_path 4pda.bin)" "--dpi-desync-fake-tls-mod=none"
}
strategy_v9() { printf '%s\n' \
"--filter-tcp=443" "--hostlist=$LIST_USER" "--dpi-desync=hostfakesplit" "--dpi-desync-hostfakesplit-mod=host=google.com" "--dpi-desync-fooling=ts" \
"--new" "--filter-tcp=443" "--hostlist-exclude=$LIST_EXCLUDE" "--dpi-desync=hostfakesplit" "--dpi-desync-fooling=badseq,badsum" "--dpi-desync-hostfakesplit-mod=host=mapgl.2gis.com" "--dpi-desync-badseq-increment=0"
}

STRATEGY_V_DESC_1="hostfakesplit(google.com) + split2/seqovl(stun)"
STRATEGY_V_DESC_2="hostfakesplit(google.com) + fake,multisplit/seqovl681"
STRATEGY_V_DESC_3="hostfakesplit + fake,fakeddisorder (требует t2/vk/gosuslugi.bin)"
STRATEGY_V_DESC_4="hostfakesplit + multisplit/seqovl582 + QUIC fake"
STRATEGY_V_DESC_5="hostfakesplit + fake,fakeddisorder + QUIC fake"
STRATEGY_V_DESC_6="hostfakesplit(2gis) badsum,badseq"
STRATEGY_V_DESC_7="hostfakesplit + fake,multisplit/seqovl654 badseq,badsum"
STRATEGY_V_DESC_8="hostfakesplit + fake/4pda.bin"
STRATEGY_V_DESC_9="hostfakesplit(mapgl.2gis.com) badseq,badsum"

# ==============================================================================
# DISCORD-СТРАТЕГИИ Dv1-Dv16 (порты 2053,2083,2087,2096,8443, hostlist-domains=discord.media)
# ==============================================================================

DISCORD_PORTS="2053,2083,2087,2096,8443"

strategy_Dv1()  { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=multisplit" "--dpi-desync-split-seqovl=652" "--dpi-desync-split-pos=2" "--dpi-desync-split-seqovl-pattern=$(fake_file_path tls_clienthello_www_google_com.bin)"; }
strategy_Dv2()  { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=fake,multisplit" "--dpi-desync-split-seqovl=681" "--dpi-desync-split-pos=1" "--dpi-desync-fooling=ts" "--dpi-desync-repeats=8" "--dpi-desync-split-seqovl-pattern=$(fake_file_path tls_clienthello_www_google_com.bin)" "--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"; }
strategy_Dv3()  { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=fake" "--dpi-desync-repeats=6" "--dpi-desync-fooling=ts" "--dpi-desync-fake-tls=$(fake_file_path tls_clienthello_www_google_com.bin)" "--dpi-desync-fake-tls-mod=none"; }
strategy_Dv4()  { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=multisplit" "--dpi-desync-split-seqovl=652" "--dpi-desync-split-pos=2" "--dpi-desync-split-seqovl-pattern=$(fake_file_path tls_clienthello_www_google_com.bin)"; }
strategy_Dv5()  { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=fake,multisplit" "--dpi-desync-repeats=6" "--dpi-desync-fooling=badseq" "--dpi-desync-badseq-increment=1000" "--dpi-desync-fake-tls=$(fake_file_path tls_clienthello_www_google_com.bin)"; }
strategy_Dv6()  { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=multisplit" "--dpi-desync-split-seqovl=681" "--dpi-desync-split-pos=1" "--dpi-desync-split-seqovl-pattern=$(fake_file_path tls_clienthello_www_google_com.bin)"; }
strategy_Dv7()  { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=multisplit" "--dpi-desync-split-pos=2,sniext+1" "--dpi-desync-split-seqovl=679" "--dpi-desync-split-seqovl-pattern=$(fake_file_path tls_clienthello_www_google_com.bin)"; }
strategy_Dv8()  { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=fake" "--dpi-desync-fake-tls-mod=none" "--dpi-desync-repeats=6" "--dpi-desync-fooling=badseq" "--dpi-desync-badseq-increment=2"; }
strategy_Dv9()  { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=fake,fakedsplit" "--dpi-desync-split-pos=1" "--dpi-desync-fooling=badseq" "--dpi-desync-badseq-increment=2" "--dpi-desync-repeats=8" "--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"; }
strategy_Dv10() { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=fake,multisplit" "--dpi-desync-split-seqovl=681" "--dpi-desync-split-pos=1" "--dpi-desync-fooling=badseq" "--dpi-desync-badseq-increment=10000000" "--dpi-desync-repeats=8" "--dpi-desync-split-seqovl-pattern=$(fake_file_path tls_clienthello_www_google_com.bin)" "--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"; }
strategy_Dv11() { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=fake,multisplit" "--dpi-desync-split-seqovl=681" "--dpi-desync-split-pos=1" "--dpi-desync-fooling=ts" "--dpi-desync-repeats=8" "--dpi-desync-split-seqovl-pattern=$(fake_file_path tls_clienthello_www_google_com.bin)" "--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"; }
strategy_Dv12() { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=fake" "--dpi-desync-repeats=6" "--dpi-desync-fooling=badseq" "--dpi-desync-badseq-increment=2" "--dpi-desync-fake-tls=$(fake_file_path tls_clienthello_www_google_com.bin)"; }
strategy_Dv13() { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=fake" "--dpi-desync-repeats=6" "--dpi-desync-fooling=ts" "--dpi-desync-fake-tls=$(fake_file_path tls_clienthello_www_google_com.bin)"; }
strategy_Dv14() { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=fake,fakedsplit" "--dpi-desync-repeats=6" "--dpi-desync-fooling=ts" "--dpi-desync-fakedsplit-pattern=0x00" "--dpi-desync-fake-tls=$(fake_file_path tls_clienthello_www_google_com.bin)"; }
strategy_Dv15() { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=fake,multidisorder" "--dpi-desync-split-pos=1,midsld" "--dpi-desync-repeats=11" "--dpi-desync-fooling=badseq" "--dpi-desync-fake-tls=0x00000000" "--dpi-desync-fake-tls=$(fake_file_path tls_clienthello_www_google_com.bin)" "--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"; }
strategy_Dv16() { printf '%s\n' "--filter-tcp=$DISCORD_PORTS" "--hostlist-domains=discord.media" "--dpi-desync=fake,hostfakesplit" "--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com" "--dpi-desync-hostfakesplit-mod=host=www.google.com,altorder=1" "--dpi-desync-fooling=ts"; }

# ==============================================================================
# ВЫБОР И ПРИМЕНЕНИЕ СТРАТЕГИИ (v1-v9 / Dv1-Dv16) -> NFQWS_ARGS_CUSTOM
# ==============================================================================

apply_strategy_block() {
	# $1 = текст стратегии (многострочный, через --new), $2 = краткое имя для лога
	BLOCK="$1"; LABEL="$2"
	ensure_fake_files_for_strategy "$BLOCK" || printf '%s\n' "${YELLOW}Стратегия применена, но часть fake-файлов недоступна — может не работать как ожидается.${NC}"
	ONELINE="$(printf '%s' "$BLOCK" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
	set_conf_var_simple "NFQWS_ARGS_CUSTOM" "$ONELINE"
	SERVICE restart
	printf '%s\n' "\n${GREEN}Применена стратегия: $LABEL${NC}\n"
	PAUSE
}

strategy_v_menu() {
	require_installed || return
	while true; do
		clear
		printf '%s\n' "${MAGENTA}Статичные стратегии v1-v9 (Zapret-Manager)${NC}\n"
		printf '%s\n' "${DGRAY}Используют hostlist=user.list для google.com + общую часть с hostlist-exclude=exclude.list${NC}\n"
		for N in 1 2 3 4 5 6 7 8 9; do
			D="STRATEGY_V_DESC_$N"
			eval "DESC=\$$D"
			printf '%s\n' " ${CYAN}$N${NC}) v$N — ${DGRAY}$DESC${NC}"
		done
		printf '%s' " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in
			1|2|3|4|5|6|7|8|9)
				BLOCK="$(strategy_v$CH)"
				apply_strategy_block "$BLOCK" "v$CH"
				;;
			'') return ;;
		esac
	done
}

strategy_discord_menu() {
	require_installed || return
	while true; do
		clear
		printf '%s\n' "${MAGENTA}Discord-стратегии Dv1-Dv16${NC}\n"
		printf '%s\n' "${DGRAY}Порты $DISCORD_PORTS, hostlist-domains=discord.media${NC}\n"
		printf '%s\n' " ${CYAN}1-16${NC}) выбрать вариант Dv1..Dv16"
		printf '%s' " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in
			1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16)
				BLOCK="$(strategy_Dv$CH)"
				apply_strategy_block "$BLOCK" "Dv$CH"
				;;
			'') return ;;
		esac
	done
}

# ==============================================================================
# FLOWSEAL: ЗАГРУЗКА И ПАРСИНГ general*.bat ИЗ zapret-discord-youtube
# ==============================================================================

FLOWSEAL_ZIP_URL="https://github.com/Flowseal/zapret-discord-youtube/archive/refs/heads/main.zip"
FLOWSEAL_TMP="$ZKM_DIR/flowseal_tmp"
FLOWSEAL_OUT="$ZKM_DIR/flowseal_strategies.txt"

download_flowseal_strategies() {
	printf '%s\n' "${CYAN}Скачиваем репозиторий Flowseal/zapret-discord-youtube${NC}"
	rm -rf "$FLOWSEAL_TMP"; mkdir -p "$FLOWSEAL_TMP"
	curl -fsSL "$FLOWSEAL_ZIP_URL" -o "$FLOWSEAL_TMP/repo.zip" 2>/dev/null
	if [ ! -s "$FLOWSEAL_TMP/repo.zip" ]; then
		printf '%s\n' "${RED}Не удалось скачать репозиторий.${NC}"
		return 1
	fi
	( cd "$FLOWSEAL_TMP" && unzip -oq repo.zip ) 2>/dev/null
	REPO_DIR="$(find "$FLOWSEAL_TMP" -maxdepth 1 -type d -name 'zapret-discord-youtube-*' | head -n1)"
	if [ -z "$REPO_DIR" ]; then
		printf '%s\n' "${RED}Не удалось распаковать репозиторий.${NC}"
		return 1
	fi
	: > "$FLOWSEAL_OUT"
	for BAT in "$REPO_DIR"/general*.bat; do
		[ -f "$BAT" ] || continue
		NAME="$(basename "$BAT" .bat)"
		echo "#$NAME" >> "$FLOWSEAL_OUT"
		# Извлекаем все --filter-...--new...-цепочки из строки winws.exe, убираем ^ и кавычки путей
		grep -oE '\-\-[a-zA-Z0-9_=,:.%"/-]+' "$BAT" \
			| grep -v '^--wf-' \
			| sed -E 's/^"|"$//g' \
			> "$ZKM_DIR/bat_args.tmp"
		# Подставляем реальные пути вместо %BIN%.../%LISTS%...
		sed -E \
			-e "s#%BIN%quic_initial_dbankcloud_ru\.bin#$(fake_file_path quic_initial_dbankcloud_ru.bin)#g" \
			-e "s#%BIN%quic_initial_www_google_com\.bin#$(fake_file_path quic_initial_www_google_com.bin)#g" \
			-e "s#%BIN%stun\.bin#$(fake_file_path stun.bin)#g" \
			-e "s#%BIN%tls_clienthello_4pda_to\.bin#$(fake_file_path 4pda.bin)#g" \
			-e "s#%BIN%tls_clienthello_max_ru\.bin#$(fake_file_path tls_clienthello_www_onetrust_com.bin)#g" \
			-e "s#%BIN%tls_clienthello_www_google_com\.bin#$(fake_file_path tls_clienthello_www_google_com.bin)#g" \
			-e "s#%LISTS%list-general\.txt#$LIST_USER#g" \
			-e "s#%LISTS%list-general-user\.txt#$LIST_USER#g" \
			-e "s#%LISTS%list-google\.txt#$LIST_USER#g" \
			-e "s#%LISTS%list-exclude\.txt#$LIST_EXCLUDE#g" \
			-e "s#%LISTS%list-exclude-user\.txt#$LIST_EXCLUDE#g" \
			-e 's#%GameFilter%#1024-65535#g' \
			-e 's/"//g' \
			"$ZKM_DIR/bat_args.tmp" >> "$FLOWSEAL_OUT"
		echo >> "$FLOWSEAL_OUT"
	done
	rm -f "$ZKM_DIR/bat_args.tmp"
	rm -rf "$FLOWSEAL_TMP"
	[ -s "$FLOWSEAL_OUT" ]
}

strategy_flowseal_menu() {
	require_installed || return
	if [ ! -s "$FLOWSEAL_OUT" ]; then
		clear
		printf '%s\n' "${MAGENTA}Стратегии Flowseal${NC}\n"
		download_flowseal_strategies || { printf '%s\n' "\n${RED}Не удалось получить стратегии Flowseal.${NC}\n"; PAUSE; return; }
	fi
	while true; do
		clear
		NAMES="$(grep '^#' "$FLOWSEAL_OUT" | sed 's/^#//')"
		printf '%s\n' "${MAGENTA}Стратегии Flowseal (zapret-discord-youtube)${NC}\n"
		N=0
		for NM in $NAMES; do
			N=$((N+1))
			printf '%s\n' " ${CYAN}$N${NC}) $NM"
		done
		printf '%s\n' "\n ${CYAN}u${NC}) Обновить список стратегий (повторное скачивание)"
		printf '%s' " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in
			u|U) download_flowseal_strategies; continue ;;
			'') return ;;
			*)
				LINES="$(grep -n '^#' "$FLOWSEAL_OUT" | cut -d: -f1)"
				START="$(echo "$LINES" | sed -n "${CH}p")"
				[ -z "$START" ] && continue
				NEXT="$(echo "$LINES" | awk -v s="$START" '$1>s{print;exit}')"
				if [ -z "$NEXT" ]; then
					BLOCK="$(sed -n "$((START+1)),\$p" "$FLOWSEAL_OUT")"
				else
					BLOCK="$(sed -n "$((START+1)),$((NEXT-1))p" "$FLOWSEAL_OUT")"
				fi
				LABEL="$(sed -n "${START}p" "$FLOWSEAL_OUT" | sed 's/^#//')"
				apply_strategy_block "$BLOCK" "Flowseal: $LABEL"
				;;
		esac
	done
}

# ==============================================================================
# МЕНЮ "СТРАТЕГИИ" (объединяет v1-v9, Discord, Flowseal)
# ==============================================================================

strategies_menu() {
	require_installed || return
	while true; do
		clear
		printf '%s\n' "${MAGENTA}Стратегии${NC}\n"
		printf '%s\n' "${DGRAY}Применение стратегии перезапишет NFQWS_ARGS_CUSTOM и перезапустит сервис.${NC}\n"
		printf '%s\n' " ${CYAN}1${NC}) v1-v9 — статичные стратегии Zapret-Manager"
		printf '%s\n' " ${CYAN}2${NC}) Dv1-Dv16 — Discord-стратегии"
		printf '%s\n' " ${CYAN}3${NC}) Flowseal — скачать и выбрать из general*.bat"
		printf '%s\n' " ${CYAN}4${NC}) Тестирование стратегий по доменам"
		printf '%s\n' " ${CYAN}5${NC}) Бэнчмарк: прогнать все стратегии разом"
		printf '%s' " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in
			1) strategy_v_menu ;;
			2) strategy_discord_menu ;;
			3) strategy_flowseal_menu ;;
			4) strategy_domain_test_menu ;;
			5) strategy_full_benchmark ;;
			'') return ;;
		esac
	done
}

# ==============================================================================
# БЕНЧМАРК / ТЕСТИРОВАНИЕ ДОСТУПНОСТИ ДОМЕНОВ
# ==============================================================================

TEST_DOMAINS="youtube.com discord.com discordapp.com instagram.com twitter.com x.com telegram.org chatgpt.com claude.ai gosuslugi.ru"

check_url_one() {
	DOMAIN="$1"
	if curl -sL --connect-timeout 4 --max-time 6 -o /dev/null -A "Mozilla/5.0" "https://$DOMAIN"; then
		printf '%s\n' "${GREEN}[ OK ]${NC} $DOMAIN" >> "$STRAT_TEST_LOG"
		echo 1 >> "$STRAT_TEST_OK"
	else
		printf '%s\n' "${RED}[FAIL]${NC} $DOMAIN" >> "$STRAT_TEST_LOG"
	fi
}

# ==============================================================================
# ТЕСТИРОВАНИЕ СТРАТЕГИЙ ПО ДОМЕНАМ / ПОЛНЫЙ БЭНЧМАРК ВСЕХ СТРАТЕГИЙ
# Идея перенесена из оригинального Zapret-Manager (run_test_by_domain / run_all_tests):
# по очереди подставляем каждую стратегию в NFQWS_ARGS_CUSTOM, перезапускаем сервис,
# проверяем список доменов параллельно, откатываем NFQWS_ARGS_CUSTOM в конце.
# ==============================================================================

STRAT_TEST_LOG="$ZKM_DIR/strategy_test_log.txt"
STRAT_TEST_OK="$ZKM_DIR/strategy_test_ok.txt"
STRAT_TEST_RESULTS="$ZKM_DIR/strategy_test_results.txt"
STRAT_PARALLEL=6

run_domains_against_current() {
	# $1 = список доменов через пробел; пишет результат (OK/TOTAL) в stdout
	DOMAINS="$1"
	: > "$STRAT_TEST_LOG"; : > "$STRAT_TEST_OK"
	RUN=0
	for D in $DOMAINS; do
		check_url_one "$D" &
		RUN=$((RUN+1))
		if [ "$RUN" -ge "$STRAT_PARALLEL" ]; then wait; RUN=0; fi
	done
	wait
	OK="$(wc -l < "$STRAT_TEST_OK" 2>/dev/null | tr -d ' ')"
	[ -z "$OK" ] && OK=0
	echo "$OK"
}

collect_all_named_strategies() {
	# Печатает в stdout пары "ИМЯ" затем блок-аргументы (как в $FLOWSEAL_OUT), разделённые "#ИМЯ" заголовками
	for N in 1 2 3 4 5 6 7 8 9; do echo "#v$N"; strategy_v$N; done
	for N in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do echo "#Dv$N"; strategy_Dv$N; done
	[ -s "$FLOWSEAL_OUT" ] && cat "$FLOWSEAL_OUT"
}

strategy_domain_test_menu() {
	require_installed || return
	clear
	printf '%s\n' "${MAGENTA}Тестирование стратегий по доменам${NC}\n"
	printf '%s' "${CYAN}Введи один или несколько доменов через пробел (например: x.com vk.com): ${NC}"
	read -r INPUT
	INPUT="$(printf '%s' "$INPUT" | tr -s ' ')"
	[ -z "$INPUT" ] && return
	ORIG_CUSTOM="$(get_conf_var NFQWS_ARGS_CUSTOM)"
	ALL_STR="$ZKM_DIR/all_strategies.txt"
	collect_all_named_strategies > "$ALL_STR"
	TOTAL_STR="$(grep -c '^#' "$ALL_STR")"
	printf '%s\n' "\n${CYAN}Найдено стратегий:${NC} $TOTAL_STR"
	printf '%s\n' "${CYAN}Доменов для теста:${NC} $(echo "$INPUT" | wc -w)\n"
	: > "$STRAT_TEST_RESULTS"
	printf '%s\n' "${YELLOW}Контрольный тест: текущая стратегия выключена (NFQWS_ARGS_CUSTOM пуст)${NC}"
	set_conf_var_simple "NFQWS_ARGS_CUSTOM" ""
	SERVICE restart >/dev/null 2>&1
	OK="$(run_domains_against_current "$INPUT")"
	TOTAL="$(echo "$INPUT" | wc -w)"
	echo "Контрольный тест (без стратегии) -> $OK/$TOTAL" >> "$STRAT_TEST_RESULTS"
	printf '%s\n' "${CYAN}Результат:${NC} $OK/$TOTAL\n"
	LINES="$(grep -n '^#' "$ALL_STR" | cut -d: -f1)"
	CUR=0
	echo "$LINES" | while read -r START; do
		CUR=$((CUR+1))
		NEXT="$(echo "$LINES" | awk -v s="$START" '$1>s{print;exit}')"
		if [ -z "$NEXT" ]; then
			BLOCK="$(sed -n "$((START+1)),\$p" "$ALL_STR")"
		else
			BLOCK="$(sed -n "$((START+1)),$((NEXT-1))p" "$ALL_STR")"
		fi
		NAME="$(sed -n "${START}p" "$ALL_STR" | sed 's/^#//')"
		ensure_fake_files_for_strategy "$BLOCK" >/dev/null 2>&1
		ONELINE="$(printf '%s' "$BLOCK" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
		set_conf_var_simple "NFQWS_ARGS_CUSTOM" "$ONELINE"
		SERVICE restart >/dev/null 2>&1
		printf '%s\n' "${CYAN}Тестируем ($CUR/$TOTAL_STR):${NC} ${YELLOW}$NAME${NC}"
		OK="$(run_domains_against_current "$INPUT")"
		printf '%s\n' "  -> $OK/$TOTAL"
		echo "$NAME -> $OK/$TOTAL" >> "$STRAT_TEST_RESULTS"
	done
	set_conf_var_simple "NFQWS_ARGS_CUSTOM" "$ORIG_CUSTOM"
	SERVICE restart >/dev/null 2>&1
	printf '%s\n' "\n${GREEN}Тест завершён, исходная стратегия восстановлена.${NC}"
	show_strategy_test_results
}

show_strategy_test_results() {
	[ ! -s "$STRAT_TEST_RESULTS" ] && { printf '%s\n' "\n${YELLOW}Результатов нет.${NC}\n"; PAUSE; return; }
	printf '%s\n' "\n${MAGENTA}Итоги (сортировка по числу успешных доменов):${NC}\n"
	TOTAL="$(head -n1 "$STRAT_TEST_RESULTS" | sed -E 's#.*-> [0-9]+/##')"
	awk -F'-> ' '{split($2,a,"/"); print a[1], $0}' "$STRAT_TEST_RESULTS" | sort -nr -k1,1 | cut -d' ' -f2- | while read -r LINE; do
		CNT="$(echo "$LINE" | sed -E 's#.*-> ([0-9]+)/.*#\1#')"
		if echo "$LINE" | grep -q "Контрольный"; then COLOR="$CYAN"
		elif [ "$CNT" -eq "$TOTAL" ] 2>/dev/null; then COLOR="$GREEN"
		elif [ "$CNT" -gt $((TOTAL/2)) ] 2>/dev/null; then COLOR="$YELLOW"
		else COLOR="$RED"
		fi
		printf '%s\n' "${COLOR}${LINE}${NC}"
	done
	echo
	PAUSE
}

strategy_full_benchmark() {
	require_installed || return
	clear
	printf '%s\n' "${MAGENTA}Бэнчмарк: прогнать все стратегии (v1-v9, Dv1-Dv16, Flowseal)${NC}\n"
	printf '%s\n' "${DGRAY}Используется фиксированный список доменов: $TEST_DOMAINS${NC}\n"
	if [ ! -s "$FLOWSEAL_OUT" ]; then
		printf '%s' "${CYAN}Скачать стратегии Flowseal перед тестом? (Y/n): ${NC}"
		read FDL
		case "$FDL" in n|N) ;; *) download_flowseal_strategies ;; esac
	fi
	printf '%s' "\n${RED}Это перезапустит сервис много раз и может занять несколько минут. Продолжить? (y/N): ${NC}"
	read CONFIRM
	case "$CONFIRM" in y|Y) ;; *) printf '%s\n' "${YELLOW}Отменено.${NC}\n"; PAUSE; return ;; esac
	ORIG_CUSTOM="$(get_conf_var NFQWS_ARGS_CUSTOM)"
	ALL_STR="$ZKM_DIR/all_strategies.txt"
	collect_all_named_strategies > "$ALL_STR"
	TOTAL_STR="$(grep -c '^#' "$ALL_STR")"
	TOTAL="$(echo "$TEST_DOMAINS" | wc -w)"
	printf '%s\n' "\n${CYAN}Найдено стратегий:${NC} $TOTAL_STR  ${CYAN}Доменов:${NC} $TOTAL\n"
	: > "$STRAT_TEST_RESULTS"
	printf '%s\n' "${YELLOW}Контрольный тест: без стратегии${NC}"
	set_conf_var_simple "NFQWS_ARGS_CUSTOM" ""
	SERVICE restart >/dev/null 2>&1
	OK="$(run_domains_against_current "$TEST_DOMAINS")"
	echo "Контрольный тест (без стратегии) -> $OK/$TOTAL" >> "$STRAT_TEST_RESULTS"
	printf '%s\n' "${CYAN}Результат:${NC} $OK/$TOTAL\n"
	LINES="$(grep -n '^#' "$ALL_STR" | cut -d: -f1)"
	CUR=0
	echo "$LINES" | while read -r START; do
		CUR=$((CUR+1))
		NEXT="$(echo "$LINES" | awk -v s="$START" '$1>s{print;exit}')"
		if [ -z "$NEXT" ]; then
			BLOCK="$(sed -n "$((START+1)),\$p" "$ALL_STR")"
		else
			BLOCK="$(sed -n "$((START+1)),$((NEXT-1))p" "$ALL_STR")"
		fi
		NAME="$(sed -n "${START}p" "$ALL_STR" | sed 's/^#//')"
		ensure_fake_files_for_strategy "$BLOCK" >/dev/null 2>&1
		ONELINE="$(printf '%s' "$BLOCK" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
		set_conf_var_simple "NFQWS_ARGS_CUSTOM" "$ONELINE"
		SERVICE restart >/dev/null 2>&1
		printf '%s\n' "${CYAN}Тестируем ($CUR/$TOTAL_STR):${NC} ${YELLOW}$NAME${NC}"
		OK="$(run_domains_against_current "$TEST_DOMAINS")"
		printf '%s\n' "  -> $OK/$TOTAL"
		echo "$NAME -> $OK/$TOTAL" >> "$STRAT_TEST_RESULTS"
	done
	set_conf_var_simple "NFQWS_ARGS_CUSTOM" "$ORIG_CUSTOM"
	SERVICE restart >/dev/null 2>&1
	printf '%s\n' "\n${GREEN}Бэнчмарк завершён, исходная стратегия восстановлена.${NC}"
	show_strategy_test_results
}

run_benchmark() {
	require_installed || return
	clear
	printf '%s\n' "${MAGENTA}Проверка доступности доменов${NC}\n"
	is_running || printf '%s\n' "${YELLOW}Внимание: сервис не запущен.${NC}\n"
	: > "$STRAT_TEST_LOG"; : > "$STRAT_TEST_OK"
	for d in $TEST_DOMAINS; do check_url_one "$d" & done
	wait
	sort "$STRAT_TEST_LOG"
	echo
	PAUSE
}

run_benchmark_custom() {
	require_installed || return
	clear
	printf '%s\n' "${MAGENTA}Проверка своих доменов${NC}\n"
	printf '%s' "${YELLOW}Введи домены через пробел: ${NC}"
	read -r INPUT
	[ -z "$INPUT" ] && return
	echo
	: > "$STRAT_TEST_LOG"; : > "$STRAT_TEST_OK"
	for d in $INPUT; do check_url_one "$d" & done
	wait
	sort "$STRAT_TEST_LOG"
	echo
	PAUSE
}

benchmark_menu() {
	while true; do
		clear
		printf '%s\n' "${MAGENTA}Бэнчмарк${NC}\n"
		printf '%s\n' " ${CYAN}1${NC}) Проверить фиксированный список доменов"
		printf '%s\n' " ${CYAN}2${NC}) Проверить свои домены"
		printf '%s' " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in
			1) run_benchmark ;;
			2) run_benchmark_custom ;;
			'') return ;;
		esac
	done
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ
# ==============================================================================

management_menu() {
	while true; do
		clear
		printf '%s\n' "${MAGENTA}Установка / обслуживание${NC}\n"
		if is_installed; then
			V="$(get_installed_version)"
			is_running && printf '%s\n' "Статус: ${GREEN}установлен, запущен${NC} (v${V:-?})" || printf '%s\n' "Статус: ${YELLOW}установлен, не запущен${NC} (v${V:-?})"
		else
			printf '%s\n' "Статус: ${RED}не установлен${NC}"
		fi
		echo
		printf '%s\n' " ${GREEN}1${NC}) Установить"
		printf '%s\n' " ${GREEN}2${NC}) Обновить"
		printf '%s\n' " ${GREEN}3${NC}) Удалить"
		printf '%s\n' " ${GREEN}4${NC}) Запустить"
		printf '%s\n' " ${GREEN}5${NC}) Остановить"
		printf '%s\n' " ${GREEN}6${NC}) Перезапустить"
		printf '%s\n' " ${GREEN}7${NC}) Reload (применить списки без рестарта правил)"
		printf '%s\n' " ${GREEN}8${NC}) Статус / процессы / iptables-правила"
		printf '%s\n' " ${GREEN}9${NC}) Редактировать конфиг"
		printf '%s\n' " ${GREEN}10${NC}) Бэкап настроек"
		printf '%s\n' " ${GREEN}11${NC}) Восстановить из бэкапа"
		printf '%s\n' " ${GREEN}12${NC}) Лог автоопределения блокировок"
		printf '%s' " ${CYAN}Enter${NC}) Назад\n\n${YELLOW}Выбор: ${NC}"
		read CH
		case "$CH" in
			1) install_nfqws ;; 2) update_nfqws ;; 3) uninstall_nfqws ;;
			4) start_action ;; 5) stop_action ;; 6) restart_action ;; 7) reload_action ;;
			8) show_status ;; 9) edit_config ;; 10) backup_settings; PAUSE ;;
			11) restore_settings ;; 12) show_logs ;;
			'') return ;;
		esac
	done
}

show_main_menu() {
	clear
	printf '%s\n' "${CYAN}==========================================${NC}"
	printf '%s\n' "${CYAN} NFQWS Manager for Keenetic/Entware${NC}"
	printf '%s\n' "${CYAN} v$ZKM_VERSION  |  based on nfqws/nfqws-keenetic${NC}"
	printf '%s\n' "${CYAN}==========================================${NC}"
	if is_installed; then
		V="$(get_installed_version)"
		is_running && printf '%s\n' " Статус: ${GREEN}установлен, запущен${NC} ${DGRAY}(v${V:-?})${NC}" || printf '%s\n' " Статус: ${YELLOW}установлен, не запущен${NC} ${DGRAY}(v${V:-?})${NC}"
	else
		printf '%s\n' " Статус: ${RED}не установлен${NC}"
	fi
	echo
	printf '%s\n' " ${GREEN}1${NC}) Установка / обслуживание"
	printf '%s\n' " ${GREEN}2${NC}) Режим работы (auto / list / all)"
	printf '%s\n' " ${GREEN}3${NC}) Списки доменов (user/auto/exclude/ipset)"
	printf '%s\n' " ${GREEN}4${NC}) Кастомная стратегия (NFQWS_ARGS_CUSTOM)"
	printf '%s\n' " ${GREEN}5${NC}) Стратегии (v1-v9 / Discord / Flowseal / тесты)"
	printf '%s\n' " ${GREEN}6${NC}) Keenetic-политика доступа"
	printf '%s\n' " ${GREEN}7${NC}) Сетевые настройки (интерфейс/IPv6/порты)"
	printf '%s\n' " ${GREEN}8${NC}) Бэнчмарк / проверка доменов"
	printf '%s\n' " ${GREEN}0${NC}) Выход"
	echo
	printf '%s' "Выбор: "
}

check_root
while true; do
	show_main_menu
	read CHOICE
	case "$CHOICE" in
		1) management_menu ;;
		2) mode_menu ;;
		3) lists_menu ;;
		4) custom_strategy_menu ;;
		5) strategies_menu ;;
		6) policy_menu ;;
		7) network_menu ;;
		8) benchmark_menu ;;
		0) exit 0 ;;
		*) ;;
	esac
done
