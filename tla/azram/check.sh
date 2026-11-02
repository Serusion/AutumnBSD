#!/bin/sh
# 正しいモデルと壊したモデルをすべて TLC にかけ、期待どおりの結果か確かめる。
#
#	使い方: TLA2TOOLS=/path/to/tla2tools.jar sh check.sh [-l]
#
# 1. 正しいモデル（MCIndex.cfg、MCProtocol.cfg、MCProtocol_swapoff.cfg、
#    MCProtocol_live.cfg）は「エラーなし」を期待する。-l を付けると、大きい
#    構成（MCProtocol_3anons.cfg、数十分かかる）も回す。
# 2. 壊したモデル（*_bug_*.cfg）は、それぞれ狙った性質の違反を期待する。
# 3. 到達確認（MCIndex_reach.tla、MCProtocol_reach.tla の Reach_*）は、正しい
#    モデルで違反が出る、つまりその状況まで探索が届いていることを期待する。
# ログと TLC の作業ディレクトリは $OUT（既定は ${TMPDIR:-/tmp}/azram-tlc）に置く。

set -u
cd "$(dirname "$0")" || exit 1
JAR=${TLA2TOOLS:-tla2tools.jar}
OUT=${OUT:-${TMPDIR:-/tmp}/azram-tlc}
[ -f "$JAR" ] || { echo "tla2tools.jar が見つかりません: $JAR" >&2; exit 1; }
mkdir -p "$OUT" || exit 1

large=false
[ "${1:-}" = -l ] && large=true

status=0
ok='Model checking completed. No error has been found.'

tlc() {		# tlc <ログ名> <TLC への引数...>
	name=$1
	shift
	rm -rf "$OUT/states/$name"
	java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto \
	    -metadir "$OUT/states/$name" -noGenerateSpecTE "$@" \
	    > "$OUT/$name.log" 2>&1
	rm -rf "$OUT/states/$name"
}

report() {	# report <ログ名> <ログに現れるべき行>
	if grep -qF "$2" "$OUT/$1.log"; then
		result=ok
	else
		result=NG
		status=1
	fi
	printf '%-3s %-48s %s\n' "$result" "$1" "$2"
}

check() {	# check <モジュール> <cfg> <ログに現れるべき行>
	tlc "${2%.cfg}" -config "$2" "$1.tla"
	report "${2%.cfg}" "$3"
}

reach() {	# reach <モジュール>: その Reach_* をすべて確かめる
	for w in $(sed -n 's/^\(Reach_[A-Za-z]*\) ==.*/\1/p' "$1.tla"); do
		tlc "$1-$w" -config "$1.cfg" -inv "$w" "$1.tla"
		report "$1-$w" "Invariant $w is violated."
	done
}

echo '-- 索引: 正しいモデル'
check MCIndex MCIndex.cfg					"$ok"

echo '-- 索引: 壊したモデル'
check MCIndex MCIndex_bug_NoRecheck.cfg			'Invariant IndexOK is violated.'
check MCIndex MCIndex_bug_StaleDir.cfg			'Invariant IndexOK is violated.'
check MCIndex MCIndex_bug_CountOutsideLock.cfg		'Invariant CountOK is violated.'
check MCIndex MCIndex_bug_BudgetNoCAS.cfg		'Invariant BudgetOK is violated.'
check MCIndex MCIndex_bug_NoUnlockOnMiss.cfg		'Temporal property Progress was violated.'

echo '-- 索引: 到達確認（違反が出るのが正しい）'
reach MCIndex_reach

echo '-- プロトコル: 正しいモデル'
check MCProtocol MCProtocol.cfg				"$ok"
check MCProtocol MCProtocol_swapoff.cfg			"$ok"
check MCProtocol MCProtocol_live.cfg			"$ok"
if $large; then
	check MCProtocol MCProtocol_3anons.cfg		"$ok"
fi

echo '-- プロトコル: 壊したモデル'
check MCProtocol MCProtocol_bug_FreeAfterReturn.cfg	'Invariant DataOK is violated.'
check MCProtocol MCProtocol_bug_NoFreeHook.cfg		'Invariant CleanAtEnd is violated.'
check MCProtocol MCProtocol_bug_NoFreeHook_swapoff.cfg	'Invariant SwapoffClean is violated.'
check MCProtocol MCProtocol_bug_DropOnLoad.cfg		'Invariant DataOK is violated.'
check MCProtocol MCProtocol_bug_CountAfterComplete.cfg	'Invariant DataOK is violated.'
check MCProtocol MCProtocol_bug_RunAtClusterStart.cfg	'Invariant DataOK is violated.'
check MCProtocol MCProtocol_bug_ForgetStored.cfg	'Temporal property PageoutsComplete was violated.'

echo '-- プロトコル: 到達確認（違反が出るのが正しい）'
reach MCProtocol_reach

echo "ログ: $OUT"
exit $status
