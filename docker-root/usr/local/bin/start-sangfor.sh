#!/bin/bash
eval "$(vpn-config.sh)"
fake-hwaddr-run() { "$@" ; }
if [ -n "$FAKE_HWADDR" ]; then
	fake-hwaddr-run() { LD_PRELOAD=/usr/local/lib/fake-hwaddr.so "$@" ; }
fi

# ============================================================================
# ECAgent 就绪等待
#   用 qemu-user 模拟 x86_64 的 EasyConnect 时（armhf 等 32 位设备），ECAgent
#   要几秒到几十秒才能把 54530 上的 webserver 拉起来；这期间 easyconn 发过去
#   的请求会超时，在 easyconn.log 里被记成 "ECAgent is down"（它那句话是超时
#   的意思，不代表 ECAgent 真的没起来，实测有 ECAgent 正在推 rclist 时被记成
#   down 的情况）。
#   上游的循环不等它就登录，登录失败后 killall 重启，于是「越失败越杀、越杀
#   越起不来」，最坏时一分钟失败一次。
#   这里在跑 vpn_ui 之前，先等 ECAgent 自己的日志说出 "webserver started"
#   （ECAgent.log），并确认 54530 确实在监听。
#   环境变量：ECAGENT_WAIT —— 最长等待秒数，默认 180；0 表示不等待
# ============================================================================
wait_ecagent() {
	local timeout="${ECAGENT_WAIT:-180}" waited=0 mark=0 lines=0
	local elog="$VPN_RESOURCES/logs/ECAgent.log"

	[ "$_VPN_TYPE" = "ATRUST" ] && return 0
	[ "$timeout" = "0" ] && return 0

	# 只认本轮新增的 "webserver started"，免得上一轮的残留让人以为已经就绪
	[ -f "$elog" ] && mark=$(wc -l < "$elog" 2>/dev/null || echo 0)

	while [ "$waited" -lt "$timeout" ]; do
		if ss -lnt 2>/dev/null | grep -q '127.0.0.1:54530'; then
			if [ ! -f "$elog" ]; then
				# 没有 ECAgent.log 可看，就只能以端口为准
				printf '[等待] ECAgent 已监听 54530（%ss）\n' "$waited"
				return 0
			fi
			lines=$(wc -l < "$elog" 2>/dev/null || echo 0)
			[ "$lines" -lt "$mark" ] && mark=0	# 日志被轮转过
			if tail -n +$((mark + 1)) "$elog" 2>/dev/null | grep -q 'webserver started'; then
				printf '[等待] ECAgent 已就绪（%ss）\n' "$waited"
				return 0
			fi
		fi
		sleep 2
		waited=$((waited + 2))
	done
	printf '[等待] ECAgent 在 %ss 内未就绪，仍继续（用 ECAGENT_WAIT 可调整）\n' "$timeout"
	return 1
}

# ============================================================================
# 登录成功判定
#   服务端接受认证时，easyconn.log 本轮新增的行里会有 <Auth><Result>1</Result>
#   （失败是 <Result>0</Result>）。用来给下面的退避判断「本轮到底成没成」。
# ============================================================================
round_authenticated() {
	local mark="${1:-0}"
	[ -f "$_LOG" ] || return 1
	tail -n +$((mark + 1)) "$_LOG" 2>/dev/null | grep -q '<Result>1</Result>'
}

# ============================================================================
# 登录失败退避
#   服务端对同一个出口 IP 的连续失败登录很敏感：2026-10-03 实测，23 分钟里约
#   20 次失败登录就被判定成暴力破解，此后登录强制图形验证码、CLI 无法通过。
#   原来每轮固定 sleep 4，是踩到这个阈值的直接原因。
#   这里在认证没通过时把重试间隔翻倍，通过则恢复成基础间隔。
#   环境变量：
#     RETRY_DELAY       基础重试间隔，默认 15 秒
#     RETRY_BACKOFF_MAX 退避上限，默认 1800 秒；0 表示不退避（固定间隔）
#   想完全回到上游行为：RETRY_DELAY=4 RETRY_BACKOFF_MAX=0
# ============================================================================
_LOG=""
_retry_delay="${RETRY_DELAY:-15}"
_backoff_max="${RETRY_BACKOFF_MAX:-1800}"

# ============================================================================
# 风控退避 (brute-force backoff)
#   服务端一旦判定该出口 IP 在暴力破解，就会对登录强制图形验证码；
#   CLI 客户端无法通过验证码，此时若仍继续重试，只会不断加重风控。
#   本补丁只检查「本次登录尝试新增的日志行」，命中该提示则进入长退避。
#   环境变量:
#     BRUTE_FORCE_BACKOFF   退避秒数，默认 1800 (30 分钟)；设为 0 可关闭本补丁
#   提前恢复: docker exec <容器名> rm -f /tmp/BRUTE_LOCK
# ============================================================================
brute_force_guard() {
	local mark="${1:-0}"
	local log="$VPN_RESOURCES/logs/easyconn.log"
	local backoff="${BRUTE_FORCE_BACKOFF:-1800}"

	[ "$backoff" = "0" ] && return 0
	[ -f "$log" ] || return 0

	# 只看本轮尝试之后新增的行，避免历史记录让退避永不解除
	tail -n +$((mark + 1)) "$log" 2>/dev/null | grep -q 'brute-force login' || return 0

	printf '\n[风控退避] 服务端要求图形验证码（brute-force 风控判定），暂停 %s 秒。\n' "$backoff"
	printf '[风控退避] 提前恢复：docker exec %s rm -f /tmp/BRUTE_LOCK\n\n' "$HOSTNAME"

	touch /tmp/BRUTE_LOCK
	local elapsed=0
	while [ -e /tmp/BRUTE_LOCK ] && [ "$elapsed" -lt "$backoff" ]; do
		sleep 5
		elapsed=$((elapsed + 5))
	done
	rm -f /tmp/BRUTE_LOCK
	printf '[风控退避] 退避结束（%s 秒），继续尝试登录。\n\n' "$elapsed"
	return 0
}

while true
do
	# 记录本轮开始前的日志行数，供 round_authenticated / brute_force_guard 判断新增内容
	_LOG="$VPN_RESOURCES/logs/easyconn.log"
	_LOG_MARK=0
	[ -f "$_LOG" ] && _LOG_MARK=$(wc -l < "$_LOG" 2>/dev/null || echo 0)

	vpn_daemon
	wait_ecagent
	vpn_ui

	brute_force_guard "$_LOG_MARK"

	# 本轮没通过认证就指数退避，别把出口 IP 送进风控
	if [ "$_backoff_max" -gt 0 ]; then
		if round_authenticated "$_LOG_MARK"; then
			_retry_delay="${RETRY_DELAY:-15}"
		else
			_retry_delay=$(( _retry_delay * 2 ))
			[ "$_retry_delay" -gt "$_backoff_max" ] && _retry_delay="$_backoff_max"
			printf '[退避] 本轮未通过认证，%s 秒后重试\n' "$_retry_delay"
		fi
	fi

	[ -n "$MAX_RETRY" ] && ((MAX_RETRY--))

	LOCK_FILE="/tmp/EXIT_LOCK"

	# 等待后端服务结束
	[ -n "$EXIT_LOCK" ] && touch "$LOCK_FILE" && {
		printf "\n\n\n当前前端服务已退出, 由于EXIT_LOCK设置, 暂不执行重启. 执行重启请执行:\n\ndocker exec -it %s rm -f %s\n\n" "$HOSTNAME" "$LOCK_FILE"
		echo "等待中"
		while :
		do
			sleep 1
			echo -e '\e[1A\e[K等待中.'
			sleep 1
			echo -e '\e[1A\e[K等待中..'
			sleep 1
			echo -e '\e[1A\e[K等待中...'
			[ ! -e "$LOCK_FILE" ] && break
		done
	}

	# 自动重连
	((MAX_RETRY<0)) && exit

	# 清除的残余进程，它们可能会妨碍下次的启动。
	killall $VPN_PROCS 2> /dev/null
	sleep "$_retry_delay"

	# 只要杀不死，就往死里杀
	killall -9 $VPN_PROCS 2> /dev/null
done
