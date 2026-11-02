----------------------------- MODULE AzramIndex -----------------------------
\* azram の索引とプールの予算（sys/uvm/uvm_azram.c の azram_insert、
\* azram_load、azram_free、azram_swapon、azram_chunk_alloc）の並行動作のモデル。
\* AzramProtocol.tla は索引の操作を不可分として扱う。ここでは、その操作を
\* コードと同じ区切りで並行に動かし、索引が「1つずつ順に起きる表」と同じに
\* 振る舞うこと（各操作がロックを持つ1回の区間で起きたように見えること）を
\* 確かめる。
\*
\* 主体:
\*   T(t)   スロットを取り（uvm_swap_alloc）、ページを格納し（azram_store1
\*          のうちプールの確保と azram_insert）、引き（azram_load）、解放する
\*          （uvm_swap_free の azram_free）、をくり返す。UVM と同じく、
\*          スロットは取った主体だけが使う
\*   G      2つ目のスワップデバイスを足す（swap_on の azram_swapon）
\*
\* 抽象化:
\*   - ロックの区間は1つの動作にする。同じロックの区間どうしは互いに排他なので、
\*     区間の中の順序は外から見えない。異なるロックの区間は別々の葉を触る。
\*     ディレクトリの配列（azram_dir）は、どのロックの下でも読まれ、全部の
\*     ロックの下でしか書かれない。
\*   - 葉のメモリはプールから取る。取れないことは非決定に起きてよい。
\*   - 圧縮したページはプールのチャンクを1つ使う（1チャンク1エントリ）。
\*     チャンクを取ってから、メモリが取れずに返すこともある。
\*   - 予算の compare-and-swap のループは、成功した1回を1つの動作にする。
\*     ループが回り続けるのは、ほかの主体が予算を変え続ける（その主体は
\*     進んでいる）ときだけで、lock-free だが wait-free ではない。分けて
\*     書くと、Progress はその飢餓の反例で崩れる。
\*   - 語の中身は、どの主体がどの種類のページを置いたかで表す。主体ごとに
\*     別のスロットを使うので、取り違えれば値が合わなくなる。
\*
\* 定数 Bug で故障を1つ注入できる。"none" が正しいモデル。

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Threads,    \* 格納・参照・解放をする主体
    LeafSize,   \* 葉1枚のスロット数（カーネルでは 512）
    NLeaves1,   \* 最初のスワップデバイスの葉の数
    NLeaves2,   \* swap_on で足す2つ目のデバイスの葉の数（0 なら足さない）
    NLocks,     \* ロックの数（AZRAM_NLOCKS、カーネルでは 64）
    PoolMax,    \* プール予算（チャンク数）
    MaxRun,     \* 1回に取るスロットの数の上限（uvm_swap_free の nslots）
    FreeBatch,  \* azram_free が1回のロックで外す語の数（AZRAM_FREEBATCH、32）
    Bug

BugNames ==
    { "none",
      "NoRecheck",          \* 葉を確保した後、取り直したロックの下で確かめずに入れる
      "StaleDir",           \* ロックを離す前に読んだディレクトリの位置に書く
      "CountOutsideLock",   \* 葉の語の数を、ロックを離してから書き戻す
      "BudgetNoCAS",        \* 予算を compare-and-swap でなく、読んだ値+1 で書く
      "NoUnlockOnMiss" }    \* 引いて見つからなかったときにロックを離さない

ASSUME
    /\ LeafSize \in Nat \ {0}
    /\ NLeaves1 \in Nat \ {0}
    /\ NLeaves2 \in Nat
    /\ NLocks \in Nat \ {0}
    /\ PoolMax \in Nat
    /\ MaxRun \in Nat \ {0}
    /\ FreeBatch \in Nat \ {0}
    /\ Bug \in BugNames

NLeaves   == NLeaves1 + NLeaves2
Leaves    == 1..NLeaves
Slots     == 1..(NLeaves * LeafSize)
LeafOf(s) == ((s - 1) \div LeafSize) + 1
LockOf(l) == ((l - 1) % NLocks) + 1
None      == "none"
Zero      == [t |-> None, k |-> "none"]        \* 語 0
Word(t, k) == [t |-> t, k |-> k]
Min(S)    == CHOOSE x \in S : \A y \in S : x <= y

(* --algorithm AzramIndex
variables
    ndir = NLeaves1,                    \* ディレクトリが覆う葉の数（azram_ndir）
    gen = 1,                            \* ディレクトリの配列の世代（swap_on で替わる）
    has = [l \in Leaves |-> FALSE],     \* ad_leaf != NULL
    wd = [s \in Slots |-> Zero],        \* 葉の語（al_w）
    cnt = [l \in Leaves |-> 0],         \* ad_count
    lk = [x \in 1..NLocks |-> None],    \* NoUnlockOnMiss で持ったままになるロック
    leaves = 0,                         \* 確保されている葉の数
    chunks = 0,                         \* プールのチャンク（azram_pool_pages）
    amap = [s \in Slots |-> Zero],      \* 抽象の表: 各操作の完了時点の正しい中身
    freeSlots = {s \in Slots : LeafOf(s) <= NLeaves1},
    staleIns = FALSE,                   \* 書こうとした語が 0 でなかった
    badLoad = FALSE;                    \* 引いた値が抽象の表と違った

define
    \* azram_free が1回の区間で見るスロット: 前に 0 でない語が FreeBatch 個未満
    Batch(ts, s) ==
        Cardinality({u \in ts : u < s /\ LeafOf(u) = LeafOf(s) /\ wd[u] # Zero})
        < FreeBatch
end define;

fair process T \in Threads
variables my = {}, todo = {}, cur = 0, k = "same", c = 0, g = 0, tl = FALSE,
          lf = 0, nrm = 0, nrmc = 0, det = FALSE, oldc = 0;
begin
A0:-
    \* uvm_swap_alloc: 連続した空きスロットを取る
    with n \in 1..MaxRun, s0 \in freeSlots do
        await (s0..(s0 + n - 1)) \subseteq freeSlots;
        my := s0..(s0 + n - 1);
        todo := s0..(s0 + n - 1);
        freeSlots := freeSlots \ (s0..(s0 + n - 1));
    end with;
A1:
    \* 取ったスロットに1枚ずつ格納する
    if todo = {} then
        goto B0;
    else
        with s \in todo, kk \in {"same", "comp"} do
            cur := s;
            k := kk;
            todo := todo \ {s};
        end with;
    end if;
A2:
    \* 圧縮したページ: azram_chunk_alloc で予算からチャンクを1つ取る。
    \* compare-and-swap のループは、不可分な読み・比較・書きを1回したことに
    \* なるので、1つの動作で書く（BudgetNoCAS では読みと書きを分ける）
    if k # "comp" then
        goto A4;
    elsif Bug = "BudgetNoCAS" then
        c := chunks;
    elsif chunks >= PoolMax then
        goto A1;                        \* pool_max に達した: 断る
    else
        chunks := chunks + 1;
        goto A3b;
    end if;
A3:
    \* BudgetNoCAS だけが通る: 読んだ値に1を足して書く
    if c >= PoolMax then
        goto A1;
    else
        chunks := c + 1;
    end if;
A3b:
    either
        skip;
    or
        chunks := chunks - 1;           \* メモリがない: 予算を戻して断る
        goto A1;
    end either;
A4:
    \* azram_insert: 1回目のロックの区間
    await lk[LockOf(LeafOf(cur))] = None;
    g := gen;
    if has[LeafOf(cur)] then
        if wd[cur] # Zero then
            staleIns := TRUE;
        end if;
        wd[cur] := Word(self, k);
        amap[cur] := Word(self, k);
        cnt[LeafOf(cur)] := cnt[LeafOf(cur)] + 1;
        goto A1;
    end if;
A5:
    \* 葉がない: ロックを離して葉を確保する（pool_get、PR_NOWAIT）
    either
        tl := TRUE;
        leaves := leaves + 1;
    or
        if k = "comp" then
            chunks := chunks - 1;       \* 断る: チャンクを返す
        end if;
        goto A1;
    end either;
A6:
    \* 2回目のロックの区間: 取り直したロックの下で葉の有無を確かめ直す
    await lk[LockOf(LeafOf(cur))] = None;
    if Bug = "StaleDir" /\ g # gen then
        \* 古い配列の要素に葉を入れ、その葉に語を書いた: どちらも失われる
        amap[cur] := Word(self, k);
        tl := FALSE;
    else
        with over = (Bug = "NoRecheck" /\ has[LeafOf(cur)]),
             inst = (~has[LeafOf(cur)] \/ Bug = "NoRecheck") do
            if wd[cur] # Zero /\ ~over then
                staleIns := TRUE;
            end if;
            \* over: ほかの主体が入れた葉を、新しい葉で上書きする
            wd := [s \in Slots |-> IF s = cur THEN Word(self, k)
                                   ELSE IF over /\ LeafOf(s) = LeafOf(cur) THEN Zero
                                   ELSE wd[s]];
            amap[cur] := Word(self, k);
            cnt[LeafOf(cur)] := (IF over THEN 0 ELSE cnt[LeafOf(cur)]) + 1;
            has[LeafOf(cur)] := TRUE;
            if inst then
                tl := FALSE;            \* 確保した葉を入れた
            end if;
        end with;
    end if;
A7:
    \* 使わなかった葉を返す
    if tl then
        leaves := leaves - 1;
        tl := FALSE;
    end if;
    goto A1;
B0:
    \* azram_load: 取ったスロットを1つ引いてみる（引かないこともある）
    either
        with s \in my do
            await lk[LockOf(LeafOf(s))] = None;
            if (IF has[LeafOf(s)] THEN wd[s] ELSE Zero) # amap[s] then
                badLoad := TRUE;
            end if;
            if Bug = "NoUnlockOnMiss" /\ ~has[LeafOf(s)] then
                lk[LockOf(LeafOf(s))] := self;
            end if;
        end with;
    or
        skip;
    end either;
C0:
    todo := my;
C1:
    \* azram_free: 葉ごとに、その葉のロックの下で語を外す
    if todo = {} then
        goto C4;
    else
        lf := LeafOf(Min(todo));
    end if;
C2:
    \* 葉の語を前から見て、0 でない語を FreeBatch 個まで外す。残りは
    \* ロックを離してから次の区間で外す
    await lk[LockOf(lf)] = None;
    if ~has[lf] then
        todo := {s \in todo : LeafOf(s) # lf};
        goto C1;
    else
        with seen = {s \in todo : LeafOf(s) = lf /\ Batch(todo, s)},
             gone = {s \in seen : wd[s] # Zero} do
            nrm := Cardinality(gone);
            nrmc := Cardinality({s \in gone : wd[s].k = "comp"});
            wd := [s \in Slots |-> IF s \in gone THEN Zero ELSE wd[s]];
            amap := [s \in Slots |-> IF s \in gone THEN Zero ELSE amap[s]];
            if Bug = "CountOutsideLock" then
                oldc := cnt[lf];         \* ロックの下で読み、離してから書く
            else
                cnt[lf] := cnt[lf] - Cardinality(gone);
                if cnt[lf] = 0 then
                    has[lf] := FALSE;    \* 空になった葉を外す
                    det := TRUE;
                end if;
            end if;
            todo := todo \ seen;
        end with;
    end if;
C2b:
    if Bug = "CountOutsideLock" then
        cnt[lf] := oldc - nrm;
        if oldc - nrm = 0 then
            has[lf] := FALSE;
            det := TRUE;
        end if;
    end if;
C3:
    \* azram_drop: チャンクを返す。外した葉も返す
    chunks := chunks - nrmc;
    if det then
        leaves := leaves - 1;
    end if;
    det := FALSE;
    nrm := 0;
    nrmc := 0;
    oldc := 0;
    goto C1;
C4:
    \* blist_free: スロットを返す
    freeSlots := freeSlots \cup my;
    my := {};
    cur := 0;
    k := "same";
    c := 0;
    g := 0;
    lf := 0;
    goto A0;
end process;

\* swap_on で2つ目のデバイスを足す。azram_swapon はディレクトリを全部の
\* ロックの下で伸ばし、その後でデバイスのスロットが使われ始める
fair process G = "grow"
begin
G1:-
    await NLeaves2 > 0 /\ \A x \in 1..NLocks : lk[x] = None;
    ndir := NLeaves;
    gen := gen + 1;
G2:
    freeSlots := freeSlots \cup {s \in Slots : LeafOf(s) > NLeaves1};
end process;

end algorithm; *)
\* BEGIN TRANSLATION
VARIABLES pc, ndir, gen, has, wd, cnt, lk, leaves, chunks, amap, freeSlots,
          staleIns, badLoad

(* define statement *)
Batch(ts, s) ==
    Cardinality({u \in ts : u < s /\ LeafOf(u) = LeafOf(s) /\ wd[u] # Zero})
    < FreeBatch

VARIABLES my, todo, cur, k, c, g, tl, lf, nrm, nrmc, det, oldc

vars == << pc, ndir, gen, has, wd, cnt, lk, leaves, chunks, amap, freeSlots,
           staleIns, badLoad, my, todo, cur, k, c, g, tl, lf, nrm, nrmc, det,
           oldc >>

ProcSet == (Threads) \cup {"grow"}

Init == (* Global variables *)
        /\ ndir = NLeaves1
        /\ gen = 1
        /\ has = [l \in Leaves |-> FALSE]
        /\ wd = [s \in Slots |-> Zero]
        /\ cnt = [l \in Leaves |-> 0]
        /\ lk = [x \in 1..NLocks |-> None]
        /\ leaves = 0
        /\ chunks = 0
        /\ amap = [s \in Slots |-> Zero]
        /\ freeSlots = {s \in Slots : LeafOf(s) <= NLeaves1}
        /\ staleIns = FALSE
        /\ badLoad = FALSE
        (* Process T *)
        /\ my = [self \in Threads |-> {}]
        /\ todo = [self \in Threads |-> {}]
        /\ cur = [self \in Threads |-> 0]
        /\ k = [self \in Threads |-> "same"]
        /\ c = [self \in Threads |-> 0]
        /\ g = [self \in Threads |-> 0]
        /\ tl = [self \in Threads |-> FALSE]
        /\ lf = [self \in Threads |-> 0]
        /\ nrm = [self \in Threads |-> 0]
        /\ nrmc = [self \in Threads |-> 0]
        /\ det = [self \in Threads |-> FALSE]
        /\ oldc = [self \in Threads |-> 0]
        /\ pc = [self \in ProcSet |-> CASE self \in Threads -> "A0"
                                        [] self = "grow" -> "G1"]

A0(self) == /\ pc[self] = "A0"
            /\ \E n \in 1..MaxRun:
                 \E s0 \in freeSlots:
                   /\ (s0..(s0 + n - 1)) \subseteq freeSlots
                   /\ my' = [my EXCEPT ![self] = s0..(s0 + n - 1)]
                   /\ todo' = [todo EXCEPT ![self] = s0..(s0 + n - 1)]
                   /\ freeSlots' = freeSlots \ (s0..(s0 + n - 1))
            /\ pc' = [pc EXCEPT ![self] = "A1"]
            /\ UNCHANGED << ndir, gen, has, wd, cnt, lk, leaves, chunks, amap,
                            staleIns, badLoad, cur, k, c, g, tl, lf, nrm, nrmc,
                            det, oldc >>

A1(self) == /\ pc[self] = "A1"
            /\ IF todo[self] = {}
                  THEN /\ pc' = [pc EXCEPT ![self] = "B0"]
                       /\ UNCHANGED << todo, cur, k >>
                  ELSE /\ \E s \in todo[self]:
                            \E kk \in {"same", "comp"}:
                              /\ cur' = [cur EXCEPT ![self] = s]
                              /\ k' = [k EXCEPT ![self] = kk]
                              /\ todo' = [todo EXCEPT ![self] = todo[self] \ {s}]
                       /\ pc' = [pc EXCEPT ![self] = "A2"]
            /\ UNCHANGED << ndir, gen, has, wd, cnt, lk, leaves, chunks, amap,
                            freeSlots, staleIns, badLoad, my, c, g, tl, lf,
                            nrm, nrmc, det, oldc >>

A2(self) == /\ pc[self] = "A2"
            /\ IF k[self] # "comp"
                  THEN /\ pc' = [pc EXCEPT ![self] = "A4"]
                       /\ UNCHANGED << chunks, c >>
                  ELSE /\ IF Bug = "BudgetNoCAS"
                             THEN /\ c' = [c EXCEPT ![self] = chunks]
                                  /\ pc' = [pc EXCEPT ![self] = "A3"]
                                  /\ UNCHANGED chunks
                             ELSE /\ IF chunks >= PoolMax
                                        THEN /\ pc' = [pc EXCEPT ![self] = "A1"]
                                             /\ UNCHANGED chunks
                                        ELSE /\ chunks' = chunks + 1
                                             /\ pc' = [pc EXCEPT ![self] = "A3b"]
                                  /\ c' = c
            /\ UNCHANGED << ndir, gen, has, wd, cnt, lk, leaves, amap,
                            freeSlots, staleIns, badLoad, my, todo, cur, k, g,
                            tl, lf, nrm, nrmc, det, oldc >>

A3(self) == /\ pc[self] = "A3"
            /\ IF c[self] >= PoolMax
                  THEN /\ pc' = [pc EXCEPT ![self] = "A1"]
                       /\ UNCHANGED chunks
                  ELSE /\ chunks' = c[self] + 1
                       /\ pc' = [pc EXCEPT ![self] = "A3b"]
            /\ UNCHANGED << ndir, gen, has, wd, cnt, lk, leaves, amap,
                            freeSlots, staleIns, badLoad, my, todo, cur, k, c,
                            g, tl, lf, nrm, nrmc, det, oldc >>

A3b(self) == /\ pc[self] = "A3b"
             /\ \/ /\ TRUE
                   /\ pc' = [pc EXCEPT ![self] = "A4"]
                   /\ UNCHANGED chunks
                \/ /\ chunks' = chunks - 1
                   /\ pc' = [pc EXCEPT ![self] = "A1"]
             /\ UNCHANGED << ndir, gen, has, wd, cnt, lk, leaves, amap,
                             freeSlots, staleIns, badLoad, my, todo, cur, k, c,
                             g, tl, lf, nrm, nrmc, det, oldc >>

A4(self) == /\ pc[self] = "A4"
            /\ lk[LockOf(LeafOf(cur[self]))] = None
            /\ g' = [g EXCEPT ![self] = gen]
            /\ IF has[LeafOf(cur[self])]
                  THEN /\ IF wd[cur[self]] # Zero
                             THEN /\ staleIns' = TRUE
                             ELSE /\ TRUE
                                  /\ UNCHANGED staleIns
                       /\ wd' = [wd EXCEPT ![cur[self]] = Word(self, k[self])]
                       /\ amap' = [amap EXCEPT ![cur[self]] = Word(self, k[self])]
                       /\ cnt' = [cnt EXCEPT ![LeafOf(cur[self])] = cnt[LeafOf(cur[self])] + 1]
                       /\ pc' = [pc EXCEPT ![self] = "A1"]
                  ELSE /\ pc' = [pc EXCEPT ![self] = "A5"]
                       /\ UNCHANGED << wd, cnt, amap, staleIns >>
            /\ UNCHANGED << ndir, gen, has, lk, leaves, chunks, freeSlots,
                            badLoad, my, todo, cur, k, c, tl, lf, nrm, nrmc,
                            det, oldc >>

A5(self) == /\ pc[self] = "A5"
            /\ \/ /\ tl' = [tl EXCEPT ![self] = TRUE]
                  /\ leaves' = leaves + 1
                  /\ pc' = [pc EXCEPT ![self] = "A6"]
                  /\ UNCHANGED chunks
               \/ /\ IF k[self] = "comp"
                        THEN /\ chunks' = chunks - 1
                        ELSE /\ TRUE
                             /\ UNCHANGED chunks
                  /\ pc' = [pc EXCEPT ![self] = "A1"]
                  /\ UNCHANGED <<leaves, tl>>
            /\ UNCHANGED << ndir, gen, has, wd, cnt, lk, amap, freeSlots,
                            staleIns, badLoad, my, todo, cur, k, c, g, lf, nrm,
                            nrmc, det, oldc >>

A6(self) == /\ pc[self] = "A6"
            /\ lk[LockOf(LeafOf(cur[self]))] = None
            /\ IF Bug = "StaleDir" /\ g[self] # gen
                  THEN /\ amap' = [amap EXCEPT ![cur[self]] = Word(self, k[self])]
                       /\ tl' = [tl EXCEPT ![self] = FALSE]
                       /\ UNCHANGED << has, wd, cnt, staleIns >>
                  ELSE /\ LET over == (Bug = "NoRecheck" /\ has[LeafOf(cur[self])]) IN
                            LET inst == (~has[LeafOf(cur[self])] \/ Bug = "NoRecheck") IN
                              /\ IF wd[cur[self]] # Zero /\ ~over
                                    THEN /\ staleIns' = TRUE
                                    ELSE /\ TRUE
                                         /\ UNCHANGED staleIns
                              /\ wd' = [s \in Slots |-> IF s = cur[self] THEN Word(self, k[self])
                                                        ELSE IF over /\ LeafOf(s) = LeafOf(cur[self]) THEN Zero
                                                        ELSE wd[s]]
                              /\ amap' = [amap EXCEPT ![cur[self]] = Word(self, k[self])]
                              /\ cnt' = [cnt EXCEPT ![LeafOf(cur[self])] = (IF over THEN 0 ELSE cnt[LeafOf(cur[self])]) + 1]
                              /\ has' = [has EXCEPT ![LeafOf(cur[self])] = TRUE]
                              /\ IF inst
                                    THEN /\ tl' = [tl EXCEPT ![self] = FALSE]
                                    ELSE /\ TRUE
                                         /\ tl' = tl
            /\ pc' = [pc EXCEPT ![self] = "A7"]
            /\ UNCHANGED << ndir, gen, lk, leaves, chunks, freeSlots, badLoad,
                            my, todo, cur, k, c, g, lf, nrm, nrmc, det, oldc >>

A7(self) == /\ pc[self] = "A7"
            /\ IF tl[self]
                  THEN /\ leaves' = leaves - 1
                       /\ tl' = [tl EXCEPT ![self] = FALSE]
                  ELSE /\ TRUE
                       /\ UNCHANGED << leaves, tl >>
            /\ pc' = [pc EXCEPT ![self] = "A1"]
            /\ UNCHANGED << ndir, gen, has, wd, cnt, lk, chunks, amap,
                            freeSlots, staleIns, badLoad, my, todo, cur, k, c,
                            g, lf, nrm, nrmc, det, oldc >>

B0(self) == /\ pc[self] = "B0"
            /\ \/ /\ \E s \in my[self]:
                       /\ lk[LockOf(LeafOf(s))] = None
                       /\ IF (IF has[LeafOf(s)] THEN wd[s] ELSE Zero) # amap[s]
                             THEN /\ badLoad' = TRUE
                             ELSE /\ TRUE
                                  /\ UNCHANGED badLoad
                       /\ IF Bug = "NoUnlockOnMiss" /\ ~has[LeafOf(s)]
                             THEN /\ lk' = [lk EXCEPT ![LockOf(LeafOf(s))] = self]
                             ELSE /\ TRUE
                                  /\ lk' = lk
               \/ /\ TRUE
                  /\ UNCHANGED <<lk, badLoad>>
            /\ pc' = [pc EXCEPT ![self] = "C0"]
            /\ UNCHANGED << ndir, gen, has, wd, cnt, leaves, chunks, amap,
                            freeSlots, staleIns, my, todo, cur, k, c, g, tl,
                            lf, nrm, nrmc, det, oldc >>

C0(self) == /\ pc[self] = "C0"
            /\ todo' = [todo EXCEPT ![self] = my[self]]
            /\ pc' = [pc EXCEPT ![self] = "C1"]
            /\ UNCHANGED << ndir, gen, has, wd, cnt, lk, leaves, chunks, amap,
                            freeSlots, staleIns, badLoad, my, cur, k, c, g, tl,
                            lf, nrm, nrmc, det, oldc >>

C1(self) == /\ pc[self] = "C1"
            /\ IF todo[self] = {}
                  THEN /\ pc' = [pc EXCEPT ![self] = "C4"]
                       /\ lf' = lf
                  ELSE /\ lf' = [lf EXCEPT ![self] = LeafOf(Min(todo[self]))]
                       /\ pc' = [pc EXCEPT ![self] = "C2"]
            /\ UNCHANGED << ndir, gen, has, wd, cnt, lk, leaves, chunks, amap,
                            freeSlots, staleIns, badLoad, my, todo, cur, k, c,
                            g, tl, nrm, nrmc, det, oldc >>

C2(self) == /\ pc[self] = "C2"
            /\ lk[LockOf(lf[self])] = None
            /\ IF ~has[lf[self]]
                  THEN /\ todo' = [todo EXCEPT ![self] = {s \in todo[self] : LeafOf(s) # lf[self]}]
                       /\ pc' = [pc EXCEPT ![self] = "C1"]
                       /\ UNCHANGED << has, wd, cnt, amap, nrm, nrmc, det,
                                       oldc >>
                  ELSE /\ LET seen == {s \in todo[self] : LeafOf(s) = lf[self] /\ Batch(todo[self], s)} IN
                            LET gone == {s \in seen : wd[s] # Zero} IN
                              /\ nrm' = [nrm EXCEPT ![self] = Cardinality(gone)]
                              /\ nrmc' = [nrmc EXCEPT ![self] = Cardinality({s \in gone : wd[s].k = "comp"})]
                              /\ wd' = [s \in Slots |-> IF s \in gone THEN Zero ELSE wd[s]]
                              /\ amap' = [s \in Slots |-> IF s \in gone THEN Zero ELSE amap[s]]
                              /\ IF Bug = "CountOutsideLock"
                                    THEN /\ oldc' = [oldc EXCEPT ![self] = cnt[lf[self]]]
                                         /\ UNCHANGED << has, cnt, det >>
                                    ELSE /\ cnt' = [cnt EXCEPT ![lf[self]] = cnt[lf[self]] - Cardinality(gone)]
                                         /\ IF cnt'[lf[self]] = 0
                                               THEN /\ has' = [has EXCEPT ![lf[self]] = FALSE]
                                                    /\ det' = [det EXCEPT ![self] = TRUE]
                                               ELSE /\ TRUE
                                                    /\ UNCHANGED << has, det >>
                                         /\ oldc' = oldc
                              /\ todo' = [todo EXCEPT ![self] = todo[self] \ seen]
                       /\ pc' = [pc EXCEPT ![self] = "C2b"]
            /\ UNCHANGED << ndir, gen, lk, leaves, chunks, freeSlots, staleIns,
                            badLoad, my, cur, k, c, g, tl, lf >>

C2b(self) == /\ pc[self] = "C2b"
             /\ IF Bug = "CountOutsideLock"
                   THEN /\ cnt' = [cnt EXCEPT ![lf[self]] = oldc[self] - nrm[self]]
                        /\ IF oldc[self] - nrm[self] = 0
                              THEN /\ has' = [has EXCEPT ![lf[self]] = FALSE]
                                   /\ det' = [det EXCEPT ![self] = TRUE]
                              ELSE /\ TRUE
                                   /\ UNCHANGED << has, det >>
                   ELSE /\ TRUE
                        /\ UNCHANGED << has, cnt, det >>
             /\ pc' = [pc EXCEPT ![self] = "C3"]
             /\ UNCHANGED << ndir, gen, wd, lk, leaves, chunks, amap,
                             freeSlots, staleIns, badLoad, my, todo, cur, k, c,
                             g, tl, lf, nrm, nrmc, oldc >>

C3(self) == /\ pc[self] = "C3"
            /\ chunks' = chunks - nrmc[self]
            /\ IF det[self]
                  THEN /\ leaves' = leaves - 1
                  ELSE /\ TRUE
                       /\ UNCHANGED leaves
            /\ det' = [det EXCEPT ![self] = FALSE]
            /\ nrm' = [nrm EXCEPT ![self] = 0]
            /\ nrmc' = [nrmc EXCEPT ![self] = 0]
            /\ oldc' = [oldc EXCEPT ![self] = 0]
            /\ pc' = [pc EXCEPT ![self] = "C1"]
            /\ UNCHANGED << ndir, gen, has, wd, cnt, lk, amap, freeSlots,
                            staleIns, badLoad, my, todo, cur, k, c, g, tl, lf >>

C4(self) == /\ pc[self] = "C4"
            /\ freeSlots' = (freeSlots \cup my[self])
            /\ my' = [my EXCEPT ![self] = {}]
            /\ cur' = [cur EXCEPT ![self] = 0]
            /\ k' = [k EXCEPT ![self] = "same"]
            /\ c' = [c EXCEPT ![self] = 0]
            /\ g' = [g EXCEPT ![self] = 0]
            /\ lf' = [lf EXCEPT ![self] = 0]
            /\ pc' = [pc EXCEPT ![self] = "A0"]
            /\ UNCHANGED << ndir, gen, has, wd, cnt, lk, leaves, chunks, amap,
                            staleIns, badLoad, todo, tl, nrm, nrmc, det, oldc >>

T(self) == A0(self) \/ A1(self) \/ A2(self) \/ A3(self) \/ A3b(self)
              \/ A4(self) \/ A5(self) \/ A6(self) \/ A7(self) \/ B0(self)
              \/ C0(self) \/ C1(self) \/ C2(self) \/ C2b(self) \/ C3(self)
              \/ C4(self)

G1 == /\ pc["grow"] = "G1"
      /\ NLeaves2 > 0 /\ \A x \in 1..NLocks : lk[x] = None
      /\ ndir' = NLeaves
      /\ gen' = gen + 1
      /\ pc' = [pc EXCEPT !["grow"] = "G2"]
      /\ UNCHANGED << has, wd, cnt, lk, leaves, chunks, amap, freeSlots,
                      staleIns, badLoad, my, todo, cur, k, c, g, tl, lf, nrm,
                      nrmc, det, oldc >>

G2 == /\ pc["grow"] = "G2"
      /\ freeSlots' = (freeSlots \cup {s \in Slots : LeafOf(s) > NLeaves1})
      /\ pc' = [pc EXCEPT !["grow"] = "Done"]
      /\ UNCHANGED << ndir, gen, has, wd, cnt, lk, leaves, chunks, amap,
                      staleIns, badLoad, my, todo, cur, k, c, g, tl, lf, nrm,
                      nrmc, det, oldc >>

G == G1 \/ G2

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == G
           \/ (\E self \in Threads: T(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in Threads : WF_vars((pc[self] # "A0") /\ T(self))
        /\ WF_vars((pc["grow"] # "G1") /\ G)

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION

\* ---------------------------------------------------------------------------
\* 性質
\* ---------------------------------------------------------------------------

\* 今の索引から読める語（葉がなければ 0）
Concrete(s) == IF LeafOf(s) <= ndir /\ has[LeafOf(s)] THEN wd[s] ELSE Zero

Words == {Zero} \cup [t : Threads, k : {"same", "comp"}]

TypeOK ==
    /\ ndir \in {NLeaves1, NLeaves}
    /\ has \in [Leaves -> BOOLEAN]
    /\ wd \in [Slots -> Words]
    /\ cnt \in [Leaves -> Nat]
    /\ leaves \in Nat
    /\ chunks \in Nat
    /\ amap \in [Slots -> Words]

\* S1 索引は、抽象の表と同じ中身を持つ（どの操作も1回の区間で起きたように見える）
IndexOK == \A s \in Slots : Concrete(s) = amap[s]

\* S2 引いた値はいつも抽象の表と同じ
LoadOK == ~badLoad

\* S3 書こうとした語は 0（UVM は解放したスロットにしか書かない）
NoStaleInsert == ~staleIns

\* CountOutsideLock で、語を外してから数を書き戻すまでの主体がいる葉。
\* その間は数が古いのが当然なので、書き戻した後で確かめる
InWindow(x) ==
    Bug = "CountOutsideLock" /\ \E t \in Threads : pc[t] = "C2b" /\ lf[t] = x

\* S4 葉の語の数は正しく、葉があるのは語があるときだけ
CountOK ==
    \A x \in Leaves : ~InWindow(x) =>
        /\ cnt[x] = Cardinality({s \in Slots : LeafOf(s) = x /\ wd[s] # Zero})
        /\ has[x] <=> cnt[x] > 0

\* S5 確保した葉は、索引にあるか、主体が手元に持っている（漏れない）
LeavesOK ==
    leaves = Cardinality({x \in Leaves : has[x]})
             + Cardinality({t \in Threads : tl[t] \/ det[t]})

RECURSIVE Sum(_, _)
Sum(f, S) == IF S = {} THEN 0
             ELSE LET x == CHOOSE y \in S : TRUE IN f[x] + Sum(f, S \ {x})

\* 使われているチャンク: 語が指すもの、主体が予算から取ってまだ語にして
\* いないもの、語を外してまだ返していないもの
InUse ==
    Cardinality({s \in Slots : wd[s].k = "comp"})
    + Cardinality({t \in Threads : pc[t] \in {"A3b", "A4", "A5", "A6"} /\ k[t] = "comp"})
    + Sum(nrmc, Threads)

\* S6 プール予算を超えない
BudgetOK == InUse <= PoolMax

\* S7 予算の数（azram_pool_pages）は、使われているチャンクの数に等しい
ChunksOK == chunks = InUse

\* S8 使われるスロットは、ディレクトリが覆う葉にある
Covered == \A s \in Slots : (s \notin freeSlots /\ amap[s] # Zero) => LeafOf(s) <= ndir

\* L1 どの主体も、始めた一巡（取る、格納、引く、解放）を終える
Progress == \A t \in Threads : (pc[t] # "A0") ~> (pc[t] = "A0")

=============================================================================
