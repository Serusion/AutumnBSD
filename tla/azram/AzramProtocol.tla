--------------------------- MODULE AzramProtocol ---------------------------
\* AutumnBSD_SPEC_MEMORY.md のフェーズ1（格納・取り出し・解放）と、UVM の
\* スロットの一生を合わせた並行動作のモデル。コードは sys/uvm/uvm_azram.c と
\* sys/uvm/uvm_swap.c の、azram のフックがある関数に沿っている。
\*
\* 主体（PlusCal のプロセス）:
\*   P(a)   anon a のページに書き込み、追い出されたページでフォールトする
\*   X(a)   anon a を解放する（プロセスの終了や munmap、uvm_anfree）
\*   pd     ページデーモン（uvmpd_scan_queue、swapcluster_*、uvm_swap_put と
\*          uvm_swap_put_azram）
\*   io     非同期のスワップ書き込みの完了（uvm_aio_aiodone）
\*   adm    vm.azram.enable を無効にして、また有効にする。Toggle のときだけ
\*   so     swapctl -d（swap_off、amap_swap_off）。Swapoff のときだけ
\*   lt     故障 FreeAfterReturn で、遅れてエントリを捨てる。その故障のときだけ
\*
\* 抽象化:
\*   - 索引への登録、索引からの削除、索引の参照は、葉のロックを1回持つ間に
\*     起きる不可分な操作として書く。それが不可分に見えることは、索引の
\*     中身を並行に動かす AzramIndex.tla で別に検査する。
\*   - ページの中身は <<anon, 版>> で表す。版は書き込むたびに1つ増える。
\*     anon を含めるので、ほかの anon の中身を読んでも分かる。版ごとに、全バイト
\*     同じ値か、圧縮できるか、圧縮できないかを KindOf で決めておく。
\*   - 圧縮後の大きさ、プールのチャンク、メモリの空きは扱わない。圧縮した
\*     ページが使うプールの枠を PoolMax 個までとし、メモリが足りなくて断る
\*     ことは、どのページにも非決定に起きてよい。
\*   - スワップの暗号化、I/O エラー（uvm_swap_markbad）、aobj は扱わない。
\*   - ページへの書き込みは anon のロックの下で行う。ページデーモンは追い出す
\*     前に pmap_page_protect で全マッピングを外すので、その後の書き込みは
\*     フォールトして anon のロックを取る。
\*
\* 1つの動作にまとめたもの（どれも、まとめる前の途中の状態をほかの主体が
\* 見られないか、見ても結果が変わらない。README.md に理由を書いた）:
\*   - anon のロックを持つ区間。ロックを持ったまま眠ることはない（ページ
\*     インの読み込みと書き出しは、ページを busy にしてロックを離して行う）
\*     ので、ロックは変数にしない。
\*   - uvm_swap_free（azram_free、azram_drop、blist_free）。
\*   - ページインの始まり（ページを busy で確保する）と読み込み。
\*   - azram_store にまとまりの全ページを渡すことと、断ったページの塊の
\*     書き込みを始めること。
\*   - 書き込みの完了（ディスクへの書き込みと uvm_aio_aiodone_pages）。
\*     格納したページの完了も、まとまりの全ページで1つにする。
\*
\* 定数 Bug で故障を1つ注入できる。"none" が正しいモデル。

EXTENDS Integers, FiniteSets, Sequences, TLC

CONSTANTS
    Anons,      \* anon の集合。それぞれページ1枚を持つ
    NSlots,     \* スワップのスロット数（スロットは 1..NSlots）
    MaxVer,     \* 各 anon に書き込める回数（ページの中身は版 0..MaxVer）
    KindOf,     \* [Anons -> [0..MaxVer -> {"same", "comp", "incomp"}]]
    PoolMax,    \* 圧縮エントリを置ける数（vm.azram.pool_max）
    ClusterMax, \* ページアウトで一度に書くページの最大数
    Toggle,     \* TRUE なら vm.azram.enable が切り替わりうる
    Swapoff,    \* TRUE なら swapctl -d が1回来うる
    Bug         \* 注入する故障（BugNames のどれか）

BugNames ==
    { "none",
      "FreeAfterReturn",    \* スロットを blist に返してからエントリを捨てる
      "NoFreeHook",         \* uvm_swap_free がエントリを捨てない
      "DropOnLoad",         \* ページインしたらエントリを捨てる
      "CountAfterComplete", \* エントリの数を、ページアウトの完了後に足す
      "RunAtClusterStart",  \* 断ったページの塊を、まとまりの先頭のスロットから書く
      "ForgetStored" }      \* 格納したページを完了させない（busy のまま）

ASSUME
    /\ NSlots \in Nat \ {0}
    /\ MaxVer \in Nat
    /\ KindOf \in [Anons -> [0..MaxVer -> {"same", "comp", "incomp"}]]
    /\ PoolMax \in Nat
    /\ ClusterMax \in 1..NSlots
    /\ Toggle \in BOOLEAN
    /\ Swapoff \in BOOLEAN
    /\ Bug \in BugNames

Slots   == 1..NSlots
Garbage == <<"none", -1>>                       \* 一度も書いていないディスク
Vals    == Anons \X (0..MaxVer)                  \* ページの中身 <<anon, 版>>
None    == "none"
Empty   == [k |-> "none", v |-> Garbage]        \* 索引の語 0
Word(k, v) == [k |-> k, v |-> v]
Range(q) == {q[j] : j \in DOMAIN q}
XIds    == {"x" \o a : a \in Anons}             \* anon を解放する主体
Owner(x) == CHOOSE a \in Anons : "x" \o a = x
ADMs    == IF Toggle THEN {"adm"} ELSE {}
SOs     == IF Swapoff THEN {"so"} ELSE {}
LTs     == IF Bug = "FreeAfterReturn" THEN {"lt"} ELSE {}

(* --algorithm AzramProtocol
variables
    \* UVM
    val = [a \in Anons |-> 0],          \* anon の中身（正しい値）
    alive = [a \in Anons |-> TRUE],
    pg = [a \in Anons |-> "dirty"],     \* none / clean / dirty / in（ページイン中）/ out（ページアウト中）
    pdata = [a \in Anons |-> <<a, 0>>], \* 物理ページの中身
    rel = [a \in Anons |-> FALSE],      \* PG_RELEASED: busy の間に anon が解放された
    slot = [a \in Anons |-> 0],         \* an_swslot（0 はなし）
    free = Slots,                       \* 空きスロット（blist）
    devOn = TRUE,                       \* SWF_ENABLE
    disk = [s \in Slots |-> Garbage],
    pending = {},                       \* 実行中の書き込み <<ページの列, 先頭のスロット>>
    \* azram
    en = TRUE,                          \* vm.azram.enable
    idx = [s \in Slots |-> Empty],      \* 索引
    nent = 0,                           \* azram_nentries + azram_nsame
    items = 0,                          \* 圧縮エントリが使うプールの枠
    \* 故障と検査用
    late = {},                          \* FreeAfterReturn: 返したがエントリを捨てていないスロット
    staleIns = FALSE,                   \* 登録先に古いエントリがあった（KASSERT）
    soDone = FALSE,
    leftover = {},
    seenStore = FALSE,                  \* azram がページを持ったことがある（到達確認用）
    seenSoAzram = FALSE;                \* swapctl -d が azram から読んだことがある（同）

define
    \* ページの中身の種類。ディスクのごみ（読み違えたとき）は圧縮できない
    \* ものとする
    Kind(a) == IF pdata[a] = Garbage THEN "incomp" ELSE KindOf[pdata[a][1]][pdata[a][2]]

    \* uvm_swap_get が読む値: azram_load で引き（azram_empty() なら引かない）、
    \* なければディスク
    Read(s) == IF nent # 0 /\ idx[s] # Empty THEN idx[s].v ELSE disk[s]

    \* azram_store が格納しうるページ（q の添字）の組: 有効で、圧縮後が
    \* reject_size 以下で、プールの枠に収まる。メモリが取れずに断ることは
    \* どのページにも起きてよいので、枠に収まる組はどれも起こりうる
    Accept(q) ==
        {A \in SUBSET (1..Len(q)) :
            /\ \A j \in A : en /\ Kind(q[j]) # "incomp"
            /\ items + Cardinality({j \in A : Kind(q[j]) = "comp"}) <= PoolMax}

    \* 格納した後の索引。古い語があれば置き換わる（azram_insert）
    Stored(c, q, A) ==
        [u \in Slots |->
            IF \E j \in A : c[j] = u
            THEN Word(Kind(q[CHOOSE j \in A : c[j] = u]),
                      pdata[q[CHOOSE j \in A : c[j] = u]])
            ELSE idx[u]]

    \* 断ったページの連続する塊 <<最初, 最後>>（uvm_swap_put_azram の i, j-1）
    Runs(q, A) ==
        {r \in (1..Len(q)) \X (1..Len(q)) :
            /\ r[1] <= r[2]
            /\ \A j \in r[1]..r[2] : j \notin A
            /\ r[1] = 1 \/ r[1] - 1 \in A
            /\ r[2] = Len(q) \/ r[2] + 1 \in A}

    \* 塊の書き込み先（uvm_swap_io の swslot + i）
    RunSlot(c, b) == IF Bug = "RunAtClusterStart" THEN c[1] ELSE c[b]
end define;

\* uvm_swap_free: azram_free でエントリを捨て（azram_empty() なら何もしない）、
\* 数を減らしてプールに返し、それからスロットを blist に返す
macro swapfree(fs) begin
    if Bug = "FreeAfterReturn" then
        late := late \cup fs;           \* 捨てるのは返した後（lt）
    elsif Bug # "NoFreeHook" /\ nent # 0 then
        nent := nent - Cardinality({u \in fs : idx[u] # Empty});
        items := items - Cardinality({u \in fs : idx[u].k = "comp"});
        idx := [u \in Slots |-> IF u \in fs THEN Empty ELSE idx[u]];
    end if;
    free := free \cup fs;
end macro;

\* uvm_swap_get: ページ a にスロット s の中身を読む
macro load(a, s) begin
    pdata[a] := Read(s);
    if Bug = "DropOnLoad" /\ nent # 0 /\ idx[s] # Empty then
        nent := nent - 1;
        items := items - (IF idx[s].k = "comp" THEN 1 ELSE 0);
        idx[s] := Empty;
    end if;
end macro;

\* uvm_aio_aiodone_pages: ページアウトを終えたページを解放する（PG_PAGEOUT
\* のページは PG_RELEASED にされる）。busy の間に anon が解放されていたら、
\* anon とスロットも解放する（uvm_anon_release）
macro complete(as) begin
    pg := [x \in Anons |-> IF x \in as THEN "none" ELSE pg[x]];
    swapfree({slot[x] : x \in {y \in as : rel[y]}});
    slot := [x \in Anons |-> IF x \in as /\ rel[x] THEN 0 ELSE slot[x]];
end macro;

\* anon a のページを使うプロセス: 書き込みと、追い出されたページでのフォールト
fair process P \in Anons
begin
PC:-
    either
        \* 書き込み（ページはメモリにあって busy でない）
        await alive[self] /\ pg[self] \in {"clean", "dirty"} /\ val[self] < MaxVer;
        pdata[self] := <<self, val[self] + 1>>;
        val[self] := val[self] + 1;
        pg[self] := "dirty";
        goto PC;
    or
        \* フォールト（uvmfault_anonget）: ページを busy で確保し、ロックを
        \* 離して読む
        await alive[self] /\ pg[self] = "none";
        pg[self] := "in";
        load(self, slot[self]);
    end either;
P1:
    \* 読み終えてロックを取り直す。スロットはそのまま持つ
    if rel[self] then
        \* 読んでいる間に anon が解放された: uvm_anon_release
        pg[self] := "none";
        swapfree({slot[self]});
        slot[self] := 0;
    else
        pg[self] := "clean";
    end if;
    goto PC;
end process;

\* anon a の解放（uvm_anfree）。ページが busy なら PG_RELEASED にして任せる
fair process X \in XIds
begin
X0:-
    with a = Owner(self) do
        await alive[a];
        alive[a] := FALSE;
        if pg[a] \in {"in", "out"} then
            rel[a] := TRUE;
        else
            pg[a] := "none";
            if slot[a] # 0 then
                swapfree({slot[a]});    \* uvm_anon_dropswap
                slot[a] := 0;
            end if;
        end if;
    end with;
end process;

\* ページデーモン
fair process PD = "pd"
variables cl = <<>>, cpg = <<>>, st = {};
begin
D0:-
    either
        \* きれいなページは書かずに解放する。中身はスロットにある
        with a \in {x \in Anons : alive[x] /\ pg[x] = "clean"} do
            pg[a] := "none";
        end with;
        goto D0;
    or
        \* 汚れたページを見つけたら、まとまりのスロットを取る
        \* （swapcluster_allocslots）
        await devOn /\ \E x \in Anons : alive[x] /\ pg[x] = "dirty";
        with k \in 1..ClusterMax, s0 \in Slots do
            await s0 + k - 1 <= NSlots /\ (s0..(s0 + k - 1)) \subseteq free;
            cl := [j \in 1..k |-> s0 + j - 1];
            free := free \ (s0..(s0 + k - 1));
        end with;
    end either;
D1:
    either
        \* 汚れたページをまとまりに足す。古いスロットは中身が古いので
        \* 解放する（uvmpd_dropswap、swapcluster_add）
        await Len(cpg) < Len(cl);
        with a \in {x \in Anons : alive[x] /\ pg[x] = "dirty"} do
            if slot[a] # 0 then
                swapfree({slot[a]});
            end if;
            slot[a] := cl[Len(cpg) + 1];
            pg[a] := "out";
            cpg := Append(cpg, a);
        end with;
        goto D1;
    or
        \* swapcluster_flush: 使わなかったスロットを返す
        swapfree({cl[j] : j \in (Len(cpg) + 1)..Len(cl)});
        if cpg = <<>> then
            cl := <<>>;
            goto D0;
        end if;
    end either;
D3:
    \* uvm_swap_put_azram: 全ページを azram_store に渡し、断ったページは
    \* 連続する塊ごとに非同期で書き始める
    with A \in Accept(cpg) do
        st := A;
        seenStore := seenStore \/ A # {};
        staleIns := staleIns \/ \E j \in A : idx[cl[j]] # Empty;
        nent := nent - Cardinality({j \in A : idx[cl[j]] # Empty})
                + (IF Bug = "CountAfterComplete" THEN 0 ELSE Cardinality(A));
        items := items - Cardinality({j \in A : idx[cl[j]].k = "comp"})
                 + Cardinality({j \in A : Kind(cpg[j]) = "comp"});
        idx := Stored(cl, cpg, A);
        pending := pending \cup
            {<<SubSeq(cpg, r[1], r[2]), RunSlot(cl, r[1])>> : r \in Runs(cpg, A)};
    end with;
D4:
    \* 格納したページは、書き込みが終わったときと同じに完了させる
    if Bug # "ForgetStored" then
        complete({cpg[j] : j \in st});
    end if;
    if Bug = "CountAfterComplete" then
        goto D5;
    else
        cl := <<>>;
        cpg := <<>>;
        st := {};
        goto D0;
    end if;
D5:
    nent := nent + Cardinality(st);
    cl := <<>>;
    cpg := <<>>;
    st := {};
    goto D0;
end process;

\* 非同期のスワップ書き込みの完了（biodone から uvm_aio_aiodone）
fair process IO = "io"
begin
I0:
    with w \in pending do
        disk := [u \in Slots |-> IF u \in w[2]..(w[2] + Len(w[1]) - 1)
                                 THEN pdata[w[1][u - w[2] + 1]]
                                 ELSE disk[u]];
        pending := pending \ {w};
        complete(Range(w[1]));
    end with;
    goto I0;
end process;

\* vm.azram.enable を無効にして、また有効にする（どちらも起きなくてよい）。
\* 無効にしても、持っているページは取り出せる
fair process ADM \in ADMs
begin
M0:-
    en := FALSE;
M1:-
    en := TRUE;
end process;

\* swapctl -d（swap_off）。新しい割り当てを止め、スロットを持つページを
\* すべて読み戻してスロットを解放し、最後に azram に何も残っていないか見る。
\* busy のページは、終わるのを待ってから読む（uvmfault_anonget が眠り、
\* 起こされる）。その待ちを表すため強い公平性を付ける
fair+ process SO \in SOs
variables sa = None;
begin
S0:-
    devOn := FALSE;
S1:
    if \A x \in Anons : slot[x] = 0 then
        goto S3;
    else
        with a \in {x \in Anons : slot[x] # 0 /\ pg[x] \notin {"in", "out"}} do
            if pg[a] = "none" then
                \* amap_swap_off -> uvm_anon_pagein -> uvmfault_anonget
                pg[a] := "in";
                seenSoAzram := seenSoAzram \/ (nent # 0 /\ idx[slot[a]] # Empty);
                load(a, slot[a]);
                sa := a;
            else
                \* ページはある: スロットを返して、汚れたことにする
                swapfree({slot[a]});
                slot[a] := 0;
                pg[a] := "dirty";
                goto S1;
            end if;
        end with;
    end if;
S2:
    \* 読み終えてロックを取り直す。解放されていたら uvm_anon_release、
    \* そうでなければ uvm_anon_pagein がスロットを返して汚れたことにする
    pg[sa] := IF rel[sa] THEN "none" ELSE "dirty";
    swapfree({slot[sa]});
    slot[sa] := 0;
    sa := None;
    goto S1;
S3:
    if free = Slots then
        leftover := {u \in Slots : idx[u] # Empty};    \* azram_swapoff
        soDone := TRUE;
    else
        devOn := TRUE;                  \* 使用中のスロットが残っている: EBUSY
    end if;
end process;

\* 故障 FreeAfterReturn: 返したスロットのエントリを、後で捨てる
fair process LT \in LTs
begin
L0:
    with u \in late do
        if nent # 0 /\ idx[u] # Empty then
            nent := nent - 1;
            items := items - (IF idx[u].k = "comp" THEN 1 ELSE 0);
            idx[u] := Empty;
        end if;
        late := late \ {u};
    end with;
    goto L0;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
VARIABLES pc, val, alive, pg, pdata, rel, slot, free, devOn, disk, pending,
          en, idx, nent, items, late, staleIns, soDone, leftover, seenStore,
          seenSoAzram

(* define statement *)
Kind(a) == IF pdata[a] = Garbage THEN "incomp" ELSE KindOf[pdata[a][1]][pdata[a][2]]



Read(s) == IF nent # 0 /\ idx[s] # Empty THEN idx[s].v ELSE disk[s]




Accept(q) ==
    {A \in SUBSET (1..Len(q)) :
        /\ \A j \in A : en /\ Kind(q[j]) # "incomp"
        /\ items + Cardinality({j \in A : Kind(q[j]) = "comp"}) <= PoolMax}


Stored(c, q, A) ==
    [u \in Slots |->
        IF \E j \in A : c[j] = u
        THEN Word(Kind(q[CHOOSE j \in A : c[j] = u]),
                  pdata[q[CHOOSE j \in A : c[j] = u]])
        ELSE idx[u]]


Runs(q, A) ==
    {r \in (1..Len(q)) \X (1..Len(q)) :
        /\ r[1] <= r[2]
        /\ \A j \in r[1]..r[2] : j \notin A
        /\ r[1] = 1 \/ r[1] - 1 \in A
        /\ r[2] = Len(q) \/ r[2] + 1 \in A}


RunSlot(c, b) == IF Bug = "RunAtClusterStart" THEN c[1] ELSE c[b]

VARIABLES cl, cpg, st, sa

vars == << pc, val, alive, pg, pdata, rel, slot, free, devOn, disk, pending,
           en, idx, nent, items, late, staleIns, soDone, leftover, seenStore,
           seenSoAzram, cl, cpg, st, sa >>

ProcSet == (Anons) \cup (XIds) \cup {"pd"} \cup {"io"} \cup (ADMs) \cup (SOs) \cup (LTs)

Init == (* Global variables *)
        /\ val = [a \in Anons |-> 0]
        /\ alive = [a \in Anons |-> TRUE]
        /\ pg = [a \in Anons |-> "dirty"]
        /\ pdata = [a \in Anons |-> <<a, 0>>]
        /\ rel = [a \in Anons |-> FALSE]
        /\ slot = [a \in Anons |-> 0]
        /\ free = Slots
        /\ devOn = TRUE
        /\ disk = [s \in Slots |-> Garbage]
        /\ pending = {}
        /\ en = TRUE
        /\ idx = [s \in Slots |-> Empty]
        /\ nent = 0
        /\ items = 0
        /\ late = {}
        /\ staleIns = FALSE
        /\ soDone = FALSE
        /\ leftover = {}
        /\ seenStore = FALSE
        /\ seenSoAzram = FALSE
        (* Process PD *)
        /\ cl = <<>>
        /\ cpg = <<>>
        /\ st = {}
        (* Process SO *)
        /\ sa = [self \in SOs |-> None]
        /\ pc = [self \in ProcSet |-> CASE self \in Anons -> "PC"
                                        [] self \in XIds -> "X0"
                                        [] self = "pd" -> "D0"
                                        [] self = "io" -> "I0"
                                        [] self \in ADMs -> "M0"
                                        [] self \in SOs -> "S0"
                                        [] self \in LTs -> "L0"]

PC(self) == /\ pc[self] = "PC"
            /\ \/ /\ alive[self] /\ pg[self] \in {"clean", "dirty"} /\ val[self] < MaxVer
                  /\ pdata' = [pdata EXCEPT ![self] = <<self, val[self] + 1>>]
                  /\ val' = [val EXCEPT ![self] = val[self] + 1]
                  /\ pg' = [pg EXCEPT ![self] = "dirty"]
                  /\ pc' = [pc EXCEPT ![self] = "PC"]
                  /\ UNCHANGED <<idx, nent, items>>
               \/ /\ alive[self] /\ pg[self] = "none"
                  /\ pg' = [pg EXCEPT ![self] = "in"]
                  /\ pdata' = [pdata EXCEPT ![self] = Read((slot[self]))]
                  /\ IF Bug = "DropOnLoad" /\ nent # 0 /\ idx[(slot[self])] # Empty
                        THEN /\ nent' = nent - 1
                             /\ items' = items - (IF idx[(slot[self])].k = "comp" THEN 1 ELSE 0)
                             /\ idx' = [idx EXCEPT ![(slot[self])] = Empty]
                        ELSE /\ TRUE
                             /\ UNCHANGED << idx, nent, items >>
                  /\ pc' = [pc EXCEPT ![self] = "P1"]
                  /\ val' = val
            /\ UNCHANGED << alive, rel, slot, free, devOn, disk, pending, en,
                            late, staleIns, soDone, leftover, seenStore,
                            seenSoAzram, cl, cpg, st, sa >>

P1(self) == /\ pc[self] = "P1"
            /\ IF rel[self]
                  THEN /\ pg' = [pg EXCEPT ![self] = "none"]
                       /\ IF Bug = "FreeAfterReturn"
                             THEN /\ late' = (late \cup ({slot[self]}))
                                  /\ UNCHANGED << idx, nent, items >>
                             ELSE /\ IF Bug # "NoFreeHook" /\ nent # 0
                                        THEN /\ nent' = nent - Cardinality({u \in ({slot[self]}) : idx[u] # Empty})
                                             /\ items' = items - Cardinality({u \in ({slot[self]}) : idx[u].k = "comp"})
                                             /\ idx' = [u \in Slots |-> IF u \in ({slot[self]}) THEN Empty ELSE idx[u]]
                                        ELSE /\ TRUE
                                             /\ UNCHANGED << idx, nent, items >>
                                  /\ late' = late
                       /\ free' = (free \cup ({slot[self]}))
                       /\ slot' = [slot EXCEPT ![self] = 0]
                  ELSE /\ pg' = [pg EXCEPT ![self] = "clean"]
                       /\ UNCHANGED << slot, free, idx, nent, items, late >>
            /\ pc' = [pc EXCEPT ![self] = "PC"]
            /\ UNCHANGED << val, alive, pdata, rel, devOn, disk, pending, en,
                            staleIns, soDone, leftover, seenStore, seenSoAzram,
                            cl, cpg, st, sa >>

P(self) == PC(self) \/ P1(self)

X0(self) == /\ pc[self] = "X0"
            /\ LET a == Owner(self) IN
                 /\ alive[a]
                 /\ alive' = [alive EXCEPT ![a] = FALSE]
                 /\ IF pg[a] \in {"in", "out"}
                       THEN /\ rel' = [rel EXCEPT ![a] = TRUE]
                            /\ UNCHANGED << pg, slot, free, idx, nent, items,
                                            late >>
                       ELSE /\ pg' = [pg EXCEPT ![a] = "none"]
                            /\ IF slot[a] # 0
                                  THEN /\ IF Bug = "FreeAfterReturn"
                                             THEN /\ late' = (late \cup ({slot[a]}))
                                                  /\ UNCHANGED << idx, nent,
                                                                  items >>
                                             ELSE /\ IF Bug # "NoFreeHook" /\ nent # 0
                                                        THEN /\ nent' = nent - Cardinality({u \in ({slot[a]}) : idx[u] # Empty})
                                                             /\ items' = items - Cardinality({u \in ({slot[a]}) : idx[u].k = "comp"})
                                                             /\ idx' = [u \in Slots |-> IF u \in ({slot[a]}) THEN Empty ELSE idx[u]]
                                                        ELSE /\ TRUE
                                                             /\ UNCHANGED << idx,
                                                                             nent,
                                                                             items >>
                                                  /\ late' = late
                                       /\ free' = (free \cup ({slot[a]}))
                                       /\ slot' = [slot EXCEPT ![a] = 0]
                                  ELSE /\ TRUE
                                       /\ UNCHANGED << slot, free, idx, nent,
                                                       items, late >>
                            /\ rel' = rel
            /\ pc' = [pc EXCEPT ![self] = "Done"]
            /\ UNCHANGED << val, pdata, devOn, disk, pending, en, staleIns,
                            soDone, leftover, seenStore, seenSoAzram, cl, cpg,
                            st, sa >>

X(self) == X0(self)

D0 == /\ pc["pd"] = "D0"
      /\ \/ /\ \E a \in {x \in Anons : alive[x] /\ pg[x] = "clean"}:
                 pg' = [pg EXCEPT ![a] = "none"]
            /\ pc' = [pc EXCEPT !["pd"] = "D0"]
            /\ UNCHANGED <<free, cl>>
         \/ /\ devOn /\ \E x \in Anons : alive[x] /\ pg[x] = "dirty"
            /\ \E k \in 1..ClusterMax:
                 \E s0 \in Slots:
                   /\ s0 + k - 1 <= NSlots /\ (s0..(s0 + k - 1)) \subseteq free
                   /\ cl' = [j \in 1..k |-> s0 + j - 1]
                   /\ free' = free \ (s0..(s0 + k - 1))
            /\ pc' = [pc EXCEPT !["pd"] = "D1"]
            /\ pg' = pg
      /\ UNCHANGED << val, alive, pdata, rel, slot, devOn, disk, pending, en,
                      idx, nent, items, late, staleIns, soDone, leftover,
                      seenStore, seenSoAzram, cpg, st, sa >>

D1 == /\ pc["pd"] = "D1"
      /\ \/ /\ Len(cpg) < Len(cl)
            /\ \E a \in {x \in Anons : alive[x] /\ pg[x] = "dirty"}:
                 /\ IF slot[a] # 0
                       THEN /\ IF Bug = "FreeAfterReturn"
                                  THEN /\ late' = (late \cup ({slot[a]}))
                                       /\ UNCHANGED << idx, nent, items >>
                                  ELSE /\ IF Bug # "NoFreeHook" /\ nent # 0
                                             THEN /\ nent' = nent - Cardinality({u \in ({slot[a]}) : idx[u] # Empty})
                                                  /\ items' = items - Cardinality({u \in ({slot[a]}) : idx[u].k = "comp"})
                                                  /\ idx' = [u \in Slots |-> IF u \in ({slot[a]}) THEN Empty ELSE idx[u]]
                                             ELSE /\ TRUE
                                                  /\ UNCHANGED << idx, nent,
                                                                  items >>
                                       /\ late' = late
                            /\ free' = (free \cup ({slot[a]}))
                       ELSE /\ TRUE
                            /\ UNCHANGED << free, idx, nent, items, late >>
                 /\ slot' = [slot EXCEPT ![a] = cl[Len(cpg) + 1]]
                 /\ pg' = [pg EXCEPT ![a] = "out"]
                 /\ cpg' = Append(cpg, a)
            /\ pc' = [pc EXCEPT !["pd"] = "D1"]
            /\ cl' = cl
         \/ /\ IF Bug = "FreeAfterReturn"
                  THEN /\ late' = (late \cup ({cl[j] : j \in (Len(cpg) + 1)..Len(cl)}))
                       /\ UNCHANGED << idx, nent, items >>
                  ELSE /\ IF Bug # "NoFreeHook" /\ nent # 0
                             THEN /\ nent' = nent - Cardinality({u \in ({cl[j] : j \in (Len(cpg) + 1)..Len(cl)}) : idx[u] # Empty})
                                  /\ items' = items - Cardinality({u \in ({cl[j] : j \in (Len(cpg) + 1)..Len(cl)}) : idx[u].k = "comp"})
                                  /\ idx' = [u \in Slots |-> IF u \in ({cl[j] : j \in (Len(cpg) + 1)..Len(cl)}) THEN Empty ELSE idx[u]]
                             ELSE /\ TRUE
                                  /\ UNCHANGED << idx, nent, items >>
                       /\ late' = late
            /\ free' = (free \cup ({cl[j] : j \in (Len(cpg) + 1)..Len(cl)}))
            /\ IF cpg = <<>>
                  THEN /\ cl' = <<>>
                       /\ pc' = [pc EXCEPT !["pd"] = "D0"]
                  ELSE /\ pc' = [pc EXCEPT !["pd"] = "D3"]
                       /\ cl' = cl
            /\ UNCHANGED <<pg, slot, cpg>>
      /\ UNCHANGED << val, alive, pdata, rel, devOn, disk, pending, en,
                      staleIns, soDone, leftover, seenStore, seenSoAzram, st,
                      sa >>

D3 == /\ pc["pd"] = "D3"
      /\ \E A \in Accept(cpg):
           /\ st' = A
           /\ seenStore' = (seenStore \/ A # {})
           /\ staleIns' = (staleIns \/ \E j \in A : idx[cl[j]] # Empty)
           /\ nent' = nent - Cardinality({j \in A : idx[cl[j]] # Empty})
                      + (IF Bug = "CountAfterComplete" THEN 0 ELSE Cardinality(A))
           /\ items' = items - Cardinality({j \in A : idx[cl[j]].k = "comp"})
                       + Cardinality({j \in A : Kind(cpg[j]) = "comp"})
           /\ idx' = Stored(cl, cpg, A)
           /\ pending' = (       pending \cup
                          {<<SubSeq(cpg, r[1], r[2]), RunSlot(cl, r[1])>> : r \in Runs(cpg, A)})
      /\ pc' = [pc EXCEPT !["pd"] = "D4"]
      /\ UNCHANGED << val, alive, pg, pdata, rel, slot, free, devOn, disk, en,
                      late, soDone, leftover, seenSoAzram, cl, cpg, sa >>

D4 == /\ pc["pd"] = "D4"
      /\ IF Bug # "ForgetStored"
            THEN /\ pg' = [x \in Anons |-> IF x \in ({cpg[j] : j \in st}) THEN "none" ELSE pg[x]]
                 /\ IF Bug = "FreeAfterReturn"
                       THEN /\ late' = (late \cup ({slot[x] : x \in {y \in ({cpg[j] : j \in st}) : rel[y]}}))
                            /\ UNCHANGED << idx, nent, items >>
                       ELSE /\ IF Bug # "NoFreeHook" /\ nent # 0
                                  THEN /\ nent' = nent - Cardinality({u \in ({slot[x] : x \in {y \in ({cpg[j] : j \in st}) : rel[y]}}) : idx[u] # Empty})
                                       /\ items' = items - Cardinality({u \in ({slot[x] : x \in {y \in ({cpg[j] : j \in st}) : rel[y]}}) : idx[u].k = "comp"})
                                       /\ idx' = [u \in Slots |-> IF u \in ({slot[x] : x \in {y \in ({cpg[j] : j \in st}) : rel[y]}}) THEN Empty ELSE idx[u]]
                                  ELSE /\ TRUE
                                       /\ UNCHANGED << idx, nent, items >>
                            /\ late' = late
                 /\ free' = (free \cup ({slot[x] : x \in {y \in ({cpg[j] : j \in st}) : rel[y]}}))
                 /\ slot' = [x \in Anons |-> IF x \in ({cpg[j] : j \in st}) /\ rel[x] THEN 0 ELSE slot[x]]
            ELSE /\ TRUE
                 /\ UNCHANGED << pg, slot, free, idx, nent, items, late >>
      /\ IF Bug = "CountAfterComplete"
            THEN /\ pc' = [pc EXCEPT !["pd"] = "D5"]
                 /\ UNCHANGED << cl, cpg, st >>
            ELSE /\ cl' = <<>>
                 /\ cpg' = <<>>
                 /\ st' = {}
                 /\ pc' = [pc EXCEPT !["pd"] = "D0"]
      /\ UNCHANGED << val, alive, pdata, rel, devOn, disk, pending, en,
                      staleIns, soDone, leftover, seenStore, seenSoAzram, sa >>

D5 == /\ pc["pd"] = "D5"
      /\ nent' = nent + Cardinality(st)
      /\ cl' = <<>>
      /\ cpg' = <<>>
      /\ st' = {}
      /\ pc' = [pc EXCEPT !["pd"] = "D0"]
      /\ UNCHANGED << val, alive, pg, pdata, rel, slot, free, devOn, disk,
                      pending, en, idx, items, late, staleIns, soDone,
                      leftover, seenStore, seenSoAzram, sa >>

PD == D0 \/ D1 \/ D3 \/ D4 \/ D5

I0 == /\ pc["io"] = "I0"
      /\ \E w \in pending:
           /\ disk' = [u \in Slots |-> IF u \in w[2]..(w[2] + Len(w[1]) - 1)
                                       THEN pdata[w[1][u - w[2] + 1]]
                                       ELSE disk[u]]
           /\ pending' = pending \ {w}
           /\ pg' = [x \in Anons |-> IF x \in (Range(w[1])) THEN "none" ELSE pg[x]]
           /\ IF Bug = "FreeAfterReturn"
                 THEN /\ late' = (late \cup ({slot[x] : x \in {y \in (Range(w[1])) : rel[y]}}))
                      /\ UNCHANGED << idx, nent, items >>
                 ELSE /\ IF Bug # "NoFreeHook" /\ nent # 0
                            THEN /\ nent' = nent - Cardinality({u \in ({slot[x] : x \in {y \in (Range(w[1])) : rel[y]}}) : idx[u] # Empty})
                                 /\ items' = items - Cardinality({u \in ({slot[x] : x \in {y \in (Range(w[1])) : rel[y]}}) : idx[u].k = "comp"})
                                 /\ idx' = [u \in Slots |-> IF u \in ({slot[x] : x \in {y \in (Range(w[1])) : rel[y]}}) THEN Empty ELSE idx[u]]
                            ELSE /\ TRUE
                                 /\ UNCHANGED << idx, nent, items >>
                      /\ late' = late
           /\ free' = (free \cup ({slot[x] : x \in {y \in (Range(w[1])) : rel[y]}}))
           /\ slot' = [x \in Anons |-> IF x \in (Range(w[1])) /\ rel[x] THEN 0 ELSE slot[x]]
      /\ pc' = [pc EXCEPT !["io"] = "I0"]
      /\ UNCHANGED << val, alive, pdata, rel, devOn, en, staleIns, soDone,
                      leftover, seenStore, seenSoAzram, cl, cpg, st, sa >>

IO == I0

M0(self) == /\ pc[self] = "M0"
            /\ en' = FALSE
            /\ pc' = [pc EXCEPT ![self] = "M1"]
            /\ UNCHANGED << val, alive, pg, pdata, rel, slot, free, devOn,
                            disk, pending, idx, nent, items, late, staleIns,
                            soDone, leftover, seenStore, seenSoAzram, cl, cpg,
                            st, sa >>

M1(self) == /\ pc[self] = "M1"
            /\ en' = TRUE
            /\ pc' = [pc EXCEPT ![self] = "Done"]
            /\ UNCHANGED << val, alive, pg, pdata, rel, slot, free, devOn,
                            disk, pending, idx, nent, items, late, staleIns,
                            soDone, leftover, seenStore, seenSoAzram, cl, cpg,
                            st, sa >>

ADM(self) == M0(self) \/ M1(self)

S0(self) == /\ pc[self] = "S0"
            /\ devOn' = FALSE
            /\ pc' = [pc EXCEPT ![self] = "S1"]
            /\ UNCHANGED << val, alive, pg, pdata, rel, slot, free, disk,
                            pending, en, idx, nent, items, late, staleIns,
                            soDone, leftover, seenStore, seenSoAzram, cl, cpg,
                            st, sa >>

S1(self) == /\ pc[self] = "S1"
            /\ IF \A x \in Anons : slot[x] = 0
                  THEN /\ pc' = [pc EXCEPT ![self] = "S3"]
                       /\ UNCHANGED << pg, pdata, slot, free, idx, nent, items,
                                       late, seenSoAzram, sa >>
                  ELSE /\ \E a \in {x \in Anons : slot[x] # 0 /\ pg[x] \notin {"in", "out"}}:
                            IF pg[a] = "none"
                               THEN /\ pg' = [pg EXCEPT ![a] = "in"]
                                    /\ seenSoAzram' = (seenSoAzram \/ (nent # 0 /\ idx[slot[a]] # Empty))
                                    /\ pdata' = [pdata EXCEPT ![a] = Read((slot[a]))]
                                    /\ IF Bug = "DropOnLoad" /\ nent # 0 /\ idx[(slot[a])] # Empty
                                          THEN /\ nent' = nent - 1
                                               /\ items' = items - (IF idx[(slot[a])].k = "comp" THEN 1 ELSE 0)
                                               /\ idx' = [idx EXCEPT ![(slot[a])] = Empty]
                                          ELSE /\ TRUE
                                               /\ UNCHANGED << idx, nent,
                                                               items >>
                                    /\ sa' = [sa EXCEPT ![self] = a]
                                    /\ pc' = [pc EXCEPT ![self] = "S2"]
                                    /\ UNCHANGED << slot, free, late >>
                               ELSE /\ IF Bug = "FreeAfterReturn"
                                          THEN /\ late' = (late \cup ({slot[a]}))
                                               /\ UNCHANGED << idx, nent,
                                                               items >>
                                          ELSE /\ IF Bug # "NoFreeHook" /\ nent # 0
                                                     THEN /\ nent' = nent - Cardinality({u \in ({slot[a]}) : idx[u] # Empty})
                                                          /\ items' = items - Cardinality({u \in ({slot[a]}) : idx[u].k = "comp"})
                                                          /\ idx' = [u \in Slots |-> IF u \in ({slot[a]}) THEN Empty ELSE idx[u]]
                                                     ELSE /\ TRUE
                                                          /\ UNCHANGED << idx,
                                                                          nent,
                                                                          items >>
                                               /\ late' = late
                                    /\ free' = (free \cup ({slot[a]}))
                                    /\ slot' = [slot EXCEPT ![a] = 0]
                                    /\ pg' = [pg EXCEPT ![a] = "dirty"]
                                    /\ pc' = [pc EXCEPT ![self] = "S1"]
                                    /\ UNCHANGED << pdata, seenSoAzram, sa >>
            /\ UNCHANGED << val, alive, rel, devOn, disk, pending, en,
                            staleIns, soDone, leftover, seenStore, cl, cpg, st >>

S2(self) == /\ pc[self] = "S2"
            /\ pg' = [pg EXCEPT ![sa[self]] = IF rel[sa[self]] THEN "none" ELSE "dirty"]
            /\ IF Bug = "FreeAfterReturn"
                  THEN /\ late' = (late \cup ({slot[sa[self]]}))
                       /\ UNCHANGED << idx, nent, items >>
                  ELSE /\ IF Bug # "NoFreeHook" /\ nent # 0
                             THEN /\ nent' = nent - Cardinality({u \in ({slot[sa[self]]}) : idx[u] # Empty})
                                  /\ items' = items - Cardinality({u \in ({slot[sa[self]]}) : idx[u].k = "comp"})
                                  /\ idx' = [u \in Slots |-> IF u \in ({slot[sa[self]]}) THEN Empty ELSE idx[u]]
                             ELSE /\ TRUE
                                  /\ UNCHANGED << idx, nent, items >>
                       /\ late' = late
            /\ free' = (free \cup ({slot[sa[self]]}))
            /\ slot' = [slot EXCEPT ![sa[self]] = 0]
            /\ sa' = [sa EXCEPT ![self] = None]
            /\ pc' = [pc EXCEPT ![self] = "S1"]
            /\ UNCHANGED << val, alive, pdata, rel, devOn, disk, pending, en,
                            staleIns, soDone, leftover, seenStore, seenSoAzram,
                            cl, cpg, st >>

S3(self) == /\ pc[self] = "S3"
            /\ IF free = Slots
                  THEN /\ leftover' = {u \in Slots : idx[u] # Empty}
                       /\ soDone' = TRUE
                       /\ devOn' = devOn
                  ELSE /\ devOn' = TRUE
                       /\ UNCHANGED << soDone, leftover >>
            /\ pc' = [pc EXCEPT ![self] = "Done"]
            /\ UNCHANGED << val, alive, pg, pdata, rel, slot, free, disk,
                            pending, en, idx, nent, items, late, staleIns,
                            seenStore, seenSoAzram, cl, cpg, st, sa >>

SO(self) == S0(self) \/ S1(self) \/ S2(self) \/ S3(self)

L0(self) == /\ pc[self] = "L0"
            /\ \E u \in late:
                 /\ IF nent # 0 /\ idx[u] # Empty
                       THEN /\ nent' = nent - 1
                            /\ items' = items - (IF idx[u].k = "comp" THEN 1 ELSE 0)
                            /\ idx' = [idx EXCEPT ![u] = Empty]
                       ELSE /\ TRUE
                            /\ UNCHANGED << idx, nent, items >>
                 /\ late' = late \ {u}
            /\ pc' = [pc EXCEPT ![self] = "L0"]
            /\ UNCHANGED << val, alive, pg, pdata, rel, slot, free, devOn,
                            disk, pending, en, staleIns, soDone, leftover,
                            seenStore, seenSoAzram, cl, cpg, st, sa >>

LT(self) == L0(self)

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == PD \/ IO
           \/ (\E self \in Anons: P(self))
           \/ (\E self \in XIds: X(self))
           \/ (\E self \in ADMs: ADM(self))
           \/ (\E self \in SOs: SO(self))
           \/ (\E self \in LTs: LT(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in Anons : WF_vars((pc[self] # "PC") /\ P(self))
        /\ \A self \in XIds : WF_vars((pc[self] # "X0") /\ X(self))
        /\ WF_vars((pc["pd"] # "D0") /\ PD)
        /\ WF_vars(IO)
        /\ \A self \in ADMs : WF_vars((pc[self] \notin {"M0", "M1"}) /\ ADM(self))
        /\ \A self \in SOs : SF_vars((pc[self] # "S0") /\ SO(self))
        /\ \A self \in LTs : WF_vars(LT(self))

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION

\* ---------------------------------------------------------------------------
\* 全体
\* ---------------------------------------------------------------------------

\* 全部の anon が解放され、動くものがない
Quiescent ==
    /\ \A a \in Anons : ~alive[a] /\ pg[a] \notin {"in", "out"}
    /\ pending = {}
    /\ late = {}
    /\ pc["pd"] = "D0"
    /\ \A x \in SOs : pc[x] \in {"S0", "Done"}

\* 静止した後の足踏み（デッドロックと区別する）
Idle == Quiescent /\ UNCHANGED vars

\* 翻訳された Spec の次状態に Idle を足したもの。公平性は翻訳と同じ
FullSpec ==
    /\ Init /\ [][Next \/ Idle]_vars
    /\ \A self \in Anons : WF_vars((pc[self] # "PC") /\ P(self))
    /\ \A self \in XIds : WF_vars((pc[self] # "X0") /\ X(self))
    /\ WF_vars((pc["pd"] # "D0") /\ PD)
    /\ WF_vars(IO)
    /\ \A self \in ADMs : WF_vars((pc[self] \notin {"M0", "M1"}) /\ ADM(self))
    /\ \A self \in SOs : SF_vars((pc[self] # "S0") /\ SO(self))
    /\ \A self \in LTs : WF_vars(LT(self))

\* ---------------------------------------------------------------------------
\* 性質
\* ---------------------------------------------------------------------------

\* ページインが読むもの: 索引にあればそれ、なければディスク
Fetch(s) == IF idx[s] # Empty THEN idx[s].v ELSE disk[s]

Pages == {"none", "clean", "dirty", "in", "out"}
Words == {Empty} \cup [k : {"same", "comp"}, v : Vals]

TypeOK ==
    /\ val \in [Anons -> 0..MaxVer]
    /\ alive \in [Anons -> BOOLEAN]
    /\ pg \in [Anons -> Pages]
    /\ pdata \in [Anons -> {Garbage} \cup Vals]
    /\ rel \in [Anons -> BOOLEAN]
    /\ slot \in [Anons -> {0} \cup Slots]
    /\ free \subseteq Slots
    /\ disk \in [Slots -> {Garbage} \cup Vals]
    /\ \A w \in pending : /\ Len(w[1]) \in 1..ClusterMax
                          /\ Range(w[1]) \subseteq Anons
                          /\ w[2] \in Slots
    /\ idx \in [Slots -> Words]
    /\ nent \in Nat
    /\ items \in Nat

\* S1 プロセスが見るページの中身は、最後に書いた値
DataOK ==
    \A a \in Anons : alive[a] /\ pg[a] \in {"clean", "dirty"} => pdata[a] = <<a, val[a]>>

\* S2 ページがないかきれいな anon はスロットを持ち、ページインすれば最後に
\*    書いた値を読める（索引にあればそれ、なければディスク）
SlotOK ==
    \A a \in Anons : alive[a] /\ pg[a] \in {"none", "clean"}
                     => slot[a] # 0 /\ Fetch(slot[a]) = <<a, val[a]>>

\* S3 返されたスロットにエントリは残っていない
FreeNotIndexed == \A s \in free : idx[s] = Empty

\* S4 登録しようとしたスロットに古いエントリはない（azram_insert の KASSERT）
NoStaleInsert == ~staleIns

\* S5 ページインしうるページのエントリは、azram_empty() の近道から見える
CountCovers ==
    \A a \in Anons : alive[a] /\ slot[a] # 0 /\ pg[a] \in {"none", "clean"}
                     /\ idx[slot[a]] # Empty
                     => nent > 0

\* S6 プール予算を超えない
BudgetOK == items <= PoolMax

\* S7 エントリはどれも、そのスロットを持つ anon のもの
Owned == \A s \in Slots : idx[s] # Empty => \E a \in Anons : slot[a] = s

\* S8 全部が解放されたら、azram には何も残らない
CleanAtEnd == Quiescent => /\ \A s \in Slots : idx[s] = Empty
                           /\ nent = 0 /\ items = 0 /\ free = Slots

\* S9 swapctl -d が通ったら、azram にそのデバイスのものは残っていない
SwapoffClean == soDone => leftover = {}

\* L1 始まったページインは終わる
PageinsComplete == \A a \in Anons : (pg[a] = "in") ~> (pg[a] # "in")

\* L2 始まったページアウトは終わる
PageoutsComplete == \A a \in Anons : (pg[a] = "out") ~> (pg[a] # "out")

\* L3 始まった swapctl -d は終わる
SwapoffEnds == \A x \in SOs : (pc[x] \notin {"S0", "Done"}) ~> (pc[x] = "Done")

=============================================================================
