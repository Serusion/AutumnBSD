# azram（圧縮メモリ）の TLA+ モデル

[AutumnBSD_SPEC_MEMORY.md](../../AutumnBSD_SPEC_MEMORY.md) のフェーズ1（格納・取り出し・解放）を、実装（`sys/uvm/uvm_azram.c` と `sys/uvm/uvm_swap.c`）に沿って PlusCal で書き、TLC で検査する。モデルは2つに分けた。

- `AzramProtocol.tla`: UVM のスロットの一生（ページアウト、ページイン、anon の解放、`swapctl -d`）と、azram のフック（格納、取り出し、解放）の順序。索引の操作（登録、削除、参照）は、葉のロックを1回持つ間に起きる不可分な操作とする。
- `AzramIndex.tla`: 索引（2段の表、葉の確保と解放、ロック、表の伸長）とプール予算の並行動作。AzramProtocol が不可分とした索引の操作を、コードと同じ区切りで並行に動かし、1つずつ順に起きたのと同じに見えることを確かめる。

## ファイル

| ファイル | 内容 |
| --- | --- |
| `AzramProtocol.tla` | UVM と azram のフックのモデル。定数 `Bug` で故障を1つ注入できる |
| `MCProtocol.tla` | その検査に使う具体的な定数（anon と、その中身の種類） |
| `MCProtocol.cfg` | 正しいモデル。anon 2つ、スロット3つ、`vm.azram.enable` の切り替えあり。安全性を検査する |
| `MCProtocol_swapoff.cfg` | 正しいモデルに `swapctl -d` を入れたもの。安全性を検査する |
| `MCProtocol_live.cfg` | 同じ構成で、ページイン、ページアウト、`swapctl -d` が終わること（活性）を検査する |
| `MCProtocol_3anons.cfg` | 大きい構成（anon 3つ、スロット4つ、まとまり3ページ、プールの枠2つ）。安全性を検査する |
| `MCProtocol_bug_*.cfg` | 壊したモデル。故障を1つ注入し、狙った性質1つだけを検査する |
| `MCProtocol_reach.tla`, `MCProtocol_reach.cfg` | 到達確認。主な競合の状況まで探索が届いていることを確かめる |
| `AzramIndex.tla` | 索引とプール予算のモデル。定数 `Bug` で故障を1つ注入できる |
| `MCIndex.tla`, `MCIndex.cfg` | 正しいモデル。主体2つ、葉2枚（1枚は `swap_on` で足す）、ロック2つ。全性質を検査する |
| `MCIndex_bug_*.cfg` | 壊したモデル |
| `MCIndex_reach.tla`, `MCIndex_reach.cfg` | 到達確認 |
| `check.sh` | 上の全部を TLC にかけ、期待どおりの結果かを判定する |

## 実行方法

[TLA+ の v1.8.0 リリース](https://github.com/tlaplus/tlaplus/releases/tag/v1.8.0)の tla2tools.jar と、Java 11 以上を使う。

```sh
TLA2TOOLS=/path/to/tla2tools.jar sh check.sh
```

`-l` を付けると、大きい構成（`MCProtocol_3anons.cfg`）も回す。1つだけ回すとき:

```sh
java -cp /path/to/tla2tools.jar tlc2.TLC -workers auto -config MCProtocol.cfg MCProtocol.tla
```

PlusCal の翻訳（`\* BEGIN TRANSLATION` から `\* END TRANSLATION` まで）はファイルに入れてある。アルゴリズムを変えたら翻訳し直す（`pcal.trans` が残す `.old` は消してよい）。

```sh
java -cp /path/to/tla2tools.jar pcal.trans -nocfg AzramProtocol.tla
```

## AzramProtocol の範囲

| 主体 | 実装 |
| --- | --- |
| `P(a)` | anon `a` を使うプロセス。ページに書き込み、追い出されたページでフォールトする（`uvmfault_anonget`、`uvm_swap_get`） |
| `X(a)` | anon `a` の解放（`uvm_anfree`）。ページが busy なら `PG_RELEASED` にして任せる |
| `pd` | ページデーモン（`uvmpd_scan_queue`、`uvmpd_dropswap`、`swapcluster_*`、`uvm_swap_put`、`uvm_swap_put_azram`） |
| `io` | 非同期のスワップ書き込みの完了（`uvm_aio_aiodone`、`uvm_aio_aiodone_pages`） |
| `adm` | `vm.azram.enable` を無効にして、また有効にする（定数 `Toggle` が真のとき） |
| `so` | `swapctl -d`（`swap_off`、`amap_swap_off`、`uvm_anon_pagein`、`azram_swapoff`。定数 `Swapoff` が真のとき） |

anon は2つ（大きい構成では3つ）で、それぞれページ1枚を持つ。ページの中身は `<<anon, 版>>` で表し、書き込むたびに版が1つ増える（各 anon 1回まで）。中身に anon を含めるので、ほかの anon の中身を読んだことも分かる。版ごとに中身の種類を決めておく。

| anon | 版0 | 版1 |
| --- | --- | --- |
| a1 | 全バイト同じ値 | 圧縮できる |
| a2 | 圧縮できる | 圧縮できない |
| a3（大きい構成だけ） | 圧縮できる | 全バイト同じ値 |

- スロットは3つ（大きい構成では4つ）。ページデーモンは連続する1〜2個（3個）のスロットを取り、汚れたページを足して書き出す。使わなかったスロットは返す。
- 圧縮したページが使うプールの枠は1つ（大きい構成では2つ）。全バイト同じ値のページは枠を使わない。
- メモリが取れずに断ることは、どのページにも起きてよい。圧縮後の大きさ、プールのチャンク、見切りのしきい値は扱わず、「圧縮できない」版は必ず断られるものとする。
- 書き込みは任意の順に完了する。
- 扱わないもの: I/O エラー（`uvm_swap_markbad`）、スワップの暗号化、aobj（tmpfs や SysV 共有メモリ。スロットの解放は `uao_dropswap` から同じ `uvm_swap_free` を通る）、`vm.azram.measure`、統計、圧縮と展開そのもの、書き戻し（フェーズ2）。

### 1つの動作にまとめたもの

状態の数を減らすため、コードでは何段階かに分かれる処理を1つの動作にした。どれも、途中の状態をほかの主体が見られないか、見ても結果が変わらない。分けて書いた最初のモデルは、同じ定数で5,000万状態を超えても終わらなかった。

1. **anon のロックを持つ区間**。ロックを持ったまま眠る区間はない（ページインの読み込みと書き出しは、ページを busy にしてロックを離して行う）。そのため anon のロックは変数にせず、区間ごとに1つの動作にした。
2. **`uvm_swap_free`**（`azram_free` で語を外し、`azram_drop` で数を減らしてプールに返し、`blist_free` でスロットを返す）。返す前のスロットはほかの主体が使えない。数が実際より多い間は、`azram_empty()` の近道で索引を引かずにすむ場合が減るだけで、結果は変わらない。故障 `FreeAfterReturn` だけは順序そのものが問題なので、エントリを捨てるのを別の主体 `lt` に遅らせる。
3. **ページインの始まりと読み込み**（ページを busy で確保し、`azram_load` かディスクで読む）。読み込みの間、そのスロットの中身を変える主体はない。ページアウトはページが busy なので始まらず、解放は `PG_RELEASED` にして読み終えるのを待ち、そのスロットへの書き込みも残っていない（書き出しのスロットを返すのは完了の後）。`azram_empty()` が見る数のほうは、近道で読み飛ばしてはいけないときに0でないこと（`CountCovers`）を、どの状態でも検査している。
4. **`azram_store` にまとまりの全ページを渡すこと**。コードも `vm.azram.enable` をこの呼び出しで1回だけ読む。登録してから数を足すまでの間、ページは busy なので、そのスロットを引く主体も解放する主体もない。断ったページの塊の書き込みも、この動作で始める。コードでは前の塊を完了させてから次の塊を書くが、塊どうしは別のページとスロットなので、順序は結果に効かない。格納されるページの組は「予算に収まり、圧縮できないページを含まない組」のどれでもよい、と書いた。メモリが取れずに断ることはどのページにも起きてよいので、ページごとに順に判定するコードと、起こりうる組は同じになる。
5. **書き込みの完了**（ディスクへの書き込みと `uvm_aio_aiodone_pages`）。その間ページは busy で、そのスロットを読む主体はない。1回の I/O の全ページを1つの動作で完了させる。格納したページの完了も、まとまりの全ページで1つの動作にした。完了はページごとに anon のロックを取るだけで、ほかのページとは独立である。

### 仕様の記述と動作の対応

| 仕様の記述 | 動作 |
| --- | --- |
| 格納: 同値チェック、圧縮、見切り、領域の確保（予算、メモリ）、登録 | `D3`（`Accept`、`Stored`） |
| 格納: 応答は `uvm_aio_aiodone_pages` をその場で呼んで行う | `D4`（`complete`） |
| 格納: 断ったページのうちスロットが連続するものを1つの I/O にまとめて書く | `D3`（`Runs`、`RunSlot`）、`I0` |
| 取り出し: エントリがあれば展開して返し、なければ HDD から読む | `PC`、`S1`（`load`、`Read`） |
| 取り出し: ページインしてもエントリは残す | `load`、`P1` |
| 解放: スロットを返す経路のフックで、ブロックリストへ返す前にエントリを捨てる | `swapfree`（`P1`、`X0`、`D1`、`complete`、`S1`、`S2` から） |
| 解放: `swapctl -d` は azram からも読み戻し、読み戻したスロットを解放する。外す直前に残りがないか確かめる | `S0`〜`S3` |
| `vm.azram.enable` を無効にしても、持っているページは取り出せる | `M0`、`M1` |

## AzramIndex の範囲

主体 `T(t)` は、連続した空きスロットを1〜2個取り（`uvm_swap_alloc`）、1つずつ格納し（`azram_store1` のうちプールの確保と `azram_insert`）、そのうち1つを引くことがあり（`azram_load`）、まとめて解放する（`azram_free`）、をくり返す。UVM と同じく、スロットは取った主体だけが使う。主体 `G` は2つ目のスワップデバイスを足す（`swap_on` の `azram_swapon`）。

- 葉1枚は2スロット。最初のデバイスは葉1枚で、`swap_on` で葉をもう1枚足す。ロックは2つで、葉ごとに別のロックになる。
- `azram_free` は1回のロックで語を1つずつ外す（`AZRAM_FREEBATCH` は32だが、2スロットの葉で分割が起きるよう1にした）。
- ロックを持つ区間は1つの動作にした。同じロックの区間どうしは互いに排他なので、区間の中の順序は外から見えない。異なるロックの区間は別々の葉を触る。ディレクトリの配列（`azram_dir`）は、どのロックの下でも読まれ、全部のロックの下でしか書かれない。
- 葉のメモリ（`pool_get`、`PR_NOWAIT`）とチャンクのメモリは、取れないことが非決定に起きてよい。チャンクは予算から取った後で、メモリが取れずに予算を戻すこともある。
- 圧縮したページはプールのチャンクを1つ使う（1チャンク1エントリ）。
- `azram_chunk_alloc` の compare-and-swap のループは、成功した1回の読み・比較・書きを1つの動作にした。読みと書きを分けて書くと、TLC は「ほかの主体がチャンクを取っては返すのをくり返し、ある主体の compare-and-swap が失敗し続ける」反例を出す。このループが回り続けるのは、ほかの主体が予算を変え続け、その主体の一巡が進んでいるときだけである（lock-free だが wait-free ではない）。実際には問題にならないので、各主体の進行を見るためにこの形にした。
- 語の中身は、どの主体がどの種類（同値か圧縮）のページを置いたかで表す。主体ごとに別のスロットを使うので、取り違えれば値が合わなくなる。
- 各操作の完了時点での正しい中身を、抽象の表 `amap` として持ち、索引から読める中身（`Concrete`）と比べる。

## 検査する性質

AzramProtocol:

| ID | 性質 | 定義 |
| --- | --- | --- |
| S1 | プロセスが見るページの中身は、最後に書いた値 | `DataOK` |
| S2 | ページがないかきれいな anon はスロットを持ち、ページインすれば最後に書いた値を読める（索引にあればそれ、なければディスク） | `SlotOK` |
| S3 | 返されたスロットにエントリは残っていない | `FreeNotIndexed` |
| S4 | 登録しようとしたスロットに古いエントリはない（`azram_insert` の KASSERT） | `NoStaleInsert` |
| S5 | ページインしうるページのエントリは、`azram_empty()` の近道から見える | `CountCovers` |
| S6 | プール予算を超えない | `BudgetOK` |
| S7 | エントリはどれも、そのスロットを持つ anon のもの | `Owned` |
| S8 | 全部が解放されて静止したら、azram には何も残らず、スロットも全部空く | `CleanAtEnd` |
| S9 | `swapctl -d` が通ったら、azram にそのデバイスのものは残っていない | `SwapoffClean` |
| L1 | 始まったページインは終わる | `PageinsComplete` |
| L2 | 始まったページアウトは終わる（azram が格納したページも） | `PageoutsComplete` |
| L3 | 始まった `swapctl -d` は終わる（通るか、EBUSY で終わる） | `SwapoffEnds` |

AzramIndex:

| ID | 性質 | 定義 |
| --- | --- | --- |
| S1 | 索引は抽象の表と同じ中身を持つ（どの操作も1回のロック区間で起きたように見える） | `IndexOK` |
| S2 | 引いた値はいつも抽象の表と同じ | `LoadOK` |
| S3 | 書こうとした語は0（UVM は解放したスロットにしか書かない） | `NoStaleInsert` |
| S4 | 葉の語の数（`ad_count`）は正しく、葉があるのは語があるときだけ | `CountOK` |
| S5 | 確保した葉は、索引にあるか主体が手元に持っている（漏れない） | `LeavesOK` |
| S6 | 使われているチャンクはプール予算を超えない | `BudgetOK` |
| S7 | 予算の数（`azram_pool_pages`）は、使われているチャンクの数に等しい | `ChunksOK` |
| S8 | 使われるスロットは、ディレクトリが覆う葉にある | `Covered` |
| L1 | どの主体も、始めた一巡（取る、格納、引く、解放）を終える | `Progress` |

どちらのモデルにも型の検査 `TypeOK` がある。

## 公平性の仮定

AzramProtocol（`FullSpec`）:

| 動作 | 公平性 | 意味 |
| --- | --- | --- |
| 書き込みとフォールトの始まり（`PC`）、anon の解放（`X0`）、ページデーモンが仕事を始めること（`D0`）、`M0`、`M1`、`swapctl -d` を始めること（`S0`） | なし | 起きないこともある |
| `P(a)` のページインの終わり（`P1`） | WF | 読み込みはいずれ終わり、プロセスはロックを取り直す |
| `pd` の書き出し（`D1`〜`D5`） | WF | 始めた書き出しは進む |
| `io` | WF | 書き込みはいずれ完了する |
| `so` の読み戻し（`S1`〜`S3`） | SF | 下を参照 |
| `lt`（故障 `FreeAfterReturn` のときだけ） | WF | |

`swapctl -d` が読み戻したいページは、ページアウト中やページイン中なら busy で、終わるのを待つ（`uvmfault_anonget` が眠り、busy が外れると起こされる）。モデルでは、プロセスのフォールトでページがまたページインされ、きれいになったページをページデーモンがまた解放する、とくり返すと、読み戻しの動作は「ときどき実行可能」にしかならない（ページイン中は busy なので実行できない）。WF ではこれを待つだけの振る舞いが許され、L3 が崩れる（下の表）。実際には、起こされた `swapctl -d` がロックを取る前にページがまた busy になることが永遠に続きはしないので、SF を仮定した。

どの公平性も必要: 1つずつ外して（SF は WF に弱めても）活性を検査すると、次のとおり崩れる（✗ が違反。`MCProtocol_live.cfg` の定数で、`Toggle` を偽にして確認）。

| 外した公平性 | L1 | L2 | L3 |
| --- | --- | --- | --- |
| `P(a)` の WF | ✗ | ✓ | ✗ |
| `pd` の WF | ✓ | ✗ | ✗ |
| `io` の WF | ✓ | ✗ | ✗ |
| `so` の SF を WF に弱める | ✓ | ✓ | ✗ |
| `so` の SF | ✗ | ✓ | ✗ |

`so` の公平性を外すと L1 も崩れるのは、`swapctl -d` が始めたページインを終える動作（`S2`）も `so` のものだからである。

AzramIndex（`Spec`）: 主体 `T(t)` は、スロットを取って一巡を始めること（`A0`）以外の動作に WF、`G` は2つ目のデバイスのスロットを使えるようにすること（`G2`）に WF を付けた。一巡を始めることと、`swap_on` が来ること（`G1`）には付けない。

## 壊したモデル

各 cfg は狙った性質1つだけを検査し、`CHECK_DEADLOCK FALSE` にしてある。デッドロックやほかの性質で先に止まらないようにするためで、活性の違反は「行き詰まった状態での無限の足踏み（Stuttering）」として報告される。反例の細部は、ワーカー数や実行のたびに変わりうる。cfg の `Bug` を `"none"` に変えて同じコマンドを回すと、違反は消える。

AzramProtocol:

| 性質 | cfg | `Bug` | 壊したこと | 期待する出力 | 反例の筋書き |
| --- | --- | --- | --- | --- | --- |
| S1 | `MCProtocol_bug_FreeAfterReturn.cfg` | `FreeAfterReturn` | `uvm_swap_free` がスロットを blist に返してからエントリを捨てる | `Invariant DataOK is violated.` | ページデーモンがスロット1を取り、使わずに返す（エントリを捨てるのは後）→ またスロット1を取って a1 を格納し、完了させる → 遅れた `azram_free` が a1 の新しいエントリを捨てる → a1 のページインが書かれていないディスクを読む |
| S8 | `MCProtocol_bug_NoFreeHook.cfg` | `NoFreeHook` | `uvm_swap_free` が `azram_free` を呼ばない | `Invariant CleanAtEnd is violated.` | a1 を格納 → a1、a2 を解放 → a1 のエントリが残ったまま静止する |
| S9 | `MCProtocol_bug_NoFreeHook_swapoff.cfg` | `NoFreeHook` | 同上 | `Invariant SwapoffClean is violated.` | a2 を格納 → a2 を解放（エントリが残る）→ `swapctl -d` が通り、残りが見つかる |
| S1 | `MCProtocol_bug_DropOnLoad.cfg` | `DropOnLoad` | ページインしたらエントリを捨てる | `Invariant DataOK is violated.` | a1 を格納 → ページインでエントリを捨てる → きれいなページは書かずに解放される → 次のページインが書かれていないディスクを読む |
| S1 | `MCProtocol_bug_CountAfterComplete.cfg` | `CountAfterComplete` | エントリの数をページアウトの完了後に足す | `Invariant DataOK is violated.` | a1 を格納（数は0のまま）→ 完了 → ページインが `azram_empty()` の近道でディスクを読む |
| S1 | `MCProtocol_bug_RunAtClusterStart.cfg` | `RunAtClusterStart` | 断ったページの塊を、まとまりの先頭のスロットから書く | `Invariant DataOK is violated.` | a1、a2 を1つのまとまりにする → a1 は格納、a2 は断られる → a2 が a1 のスロットに書かれる → a2 のページインが自分のスロットを読む |
| L2 | `MCProtocol_bug_ForgetStored.cfg` | `ForgetStored` | 格納したページを完了させない | `Temporal property PageoutsComplete was violated.` | a1 を格納 → 完了させない → a1 のページは busy のまま残る |

AzramIndex:

| 性質 | cfg | `Bug` | 壊したこと | 期待する出力 | 反例の筋書き |
| --- | --- | --- | --- | --- | --- |
| S1 | `MCIndex_bug_NoRecheck.cfg` | `NoRecheck` | 葉を確保してロックを取り直した後、確かめずに自分の葉を入れる | `Invariant IndexOK is violated.` | t1、t2 が同じ葉の別のスロットに格納しようとし、どちらも葉がないのを見て確保に行く → t1 が葉を入れて語を書く → t2 が自分の葉で上書きし、t1 の語が消える |
| S1 | `MCIndex_bug_StaleDir.cfg` | `StaleDir` | ロックを離す前に読んだ `azram_dir` の要素に書く | `Invariant IndexOK is violated.` | t1 が葉がないのを見てロックを離す → `swap_on` がディレクトリを替える → t1 が古い配列に葉と語を書き、どちらも失われる |
| S4 | `MCIndex_bug_CountOutsideLock.cfg` | `CountOutsideLock` | `azram_free` が葉の語の数をロックの下で読み、離してから書く | `Invariant CountOK is violated.` | t1 が自分の語を外し、数（1）を読んでロックを離す → t2 が同じ葉に格納する（数2）→ t1 が0を書いて葉を外す。t2 の語が残っている |
| S6 | `MCIndex_bug_BudgetNoCAS.cfg` | `BudgetNoCAS` | 予算を compare-and-swap でなく、読んだ値に1を足して書く | `Invariant BudgetOK is violated.` | t1、t2 が予算0を読む → どちらも1を書く（2チャンクを1と数える）→ t2 がもう1つ取る → 3チャンクで予算2を超える |
| L1 | `MCIndex_bug_NoUnlockOnMiss.cfg` | `NoUnlockOnMiss` | `azram_load` が見つからなかったときにロックを離さない | `Temporal property Progress was violated.` | t1 の格納が2つとも断られる → t1 が引いて見つからず、ロックを持ったまま戻る → t1 の解放が同じロックを待ち続ける |

## 実装の決まりと、それを確かめた壊したモデル

次の決まりは、どれも逆にした壊したモデルで性質が崩れることを確かめている（括弧内）。

1. `uvm_swap_free` は、スロットを blist に返す前に `azram_free` を呼ぶ（`FreeAfterReturn`）。
2. スロットを返す経路（anon の解放、`uvmpd_dropswap`、まとまりの余り、完了時の `uvm_anon_release`、`swapctl -d` の読み戻し）は、すべて `uvm_swap_free` を通ってエントリを捨てる（`NoFreeHook`）。
3. ページインしてもエントリは残し、捨てるのはスロットを返すときだけにする。UVM はきれいなページを書かずに解放する（`DropOnLoad`）。
4. エントリの数（`azram_nentries`、`azram_nsame`）は、`azram_store1` の中で、ページアウトを完了させる前に足す。`azram_load` と `azram_free` は、数が0なら索引を引かない（`CountAfterComplete`）。
5. 断ったページの塊は、`swslot + i` から書く（`RunAtClusterStart`）。
6. 格納したページは、`uvm_aio_aiodone_pages` を呼んで完了させる（`ForgetStored`）。
7. `azram_insert` は、葉を確保してロックを取り直したら、ほかの主体が葉を入れていないか確かめ直す（`NoRecheck`）。
8. そのとき `azram_dir` を読み直す。その間に `azram_swapon` が配列を替えているかもしれない（`StaleDir`）。
9. 葉の語の数（`ad_count`）は、語を書き換えるのと同じロックの区間で更新する（`CountOutsideLock`）。
10. プール予算は compare-and-swap で取る（`BudgetNoCAS`）。
11. `azram_load` は、見つからなかったときもロックを離す（`NoUnlockOnMiss`）。

## 到達確認

正しいモデルの検査が空振りしていないことを確かめるため、「この状況には到達しない」という式を並べ、正しいモデルで1つずつ `-inv` で検査している。すべて違反になる、つまり探索がその状況まで届いている。

- `MCProtocol_reach.tla`（20個、`swapctl -d` と切り替えあり）: azram からの読み込み、ディスクからの読み込み、`azram_empty()` の近道、同値と圧縮のエントリの共存、ページイン後もエントリが残ってきれいなページが書かずに解放されること、書き込みで古くなったエントリ、格納したページの後ろの断ったページの塊、予算がいっぱいで断ること、圧縮できないページの書き込み、無効の間の azram からの読み込み、格納・書き込み・読み込みのそれぞれの途中での anon の解放、古いスロットを返してからの再書き出し、`swapctl -d` の azram からの読み戻しとページアウト待ちと読み戻し中の解放、EBUSY、azram から読み戻したうえで通ること、azram がページを持った後の静止。
- `MCIndex_reach.tla`（10個）: 同じ葉の確保の競合と、その間の別のスロットへの格納、葉の確保中の `swap_on`、空になった葉の取り外しと、その間の別の葉の挿入、`AZRAM_FREEBATCH` での分割、予算がいっぱいのとき、チャンクを取った後のメモリ不足の分かれ目、2つ目のデバイスへの格納、見つかる参照と見つからない参照。

最後の2つの到達確認のため、AzramProtocol には検査用の変数 `seenStore`（azram がページを持ったことがある）と `seenSoAzram`（`swapctl -d` が azram から読んだことがある）を置いた。

## 検査結果

TLC 2026.10.30.154139（tla2tools.jar v1.8.0）、12ワーカー。

| cfg | 状態数 | 深さ | 時間 | 結果 |
| --- | --- | --- | --- | --- |
| `MCIndex.cfg` | 661,665 | 52 | 47秒 | エラーなし |
| `MCProtocol.cfg` | 201,651 | 35 | 3秒 | エラーなし |
| `MCProtocol_swapoff.cfg` | 2,328,294 | 46 | 28秒 | エラーなし |
| `MCProtocol_live.cfg` | 2,328,294 | 46 | 6分2秒 | エラーなし |
| `MCProtocol_3anons.cfg` | 26,144,718 | 48 | 5分18秒 | エラーなし |

`check.sh -l` 全体（正しいモデル5、壊したモデル12、到達確認30）は約13分半で、すべて期待どおりだった。`-l` なしなら約8分。

anon、中身の種類、スロットの数、まとまりの大きさ、プールの枠は `MCProtocol.tla` と各 cfg で、索引の葉の大きさ、ロックの数、`AZRAM_FREEBATCH` は `MCIndex.cfg` で変えられる。
