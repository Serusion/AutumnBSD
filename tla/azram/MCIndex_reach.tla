----------------------------- MODULE MCIndex_reach -----------------------------
\* AzramIndex の到達確認（検査が空振りしていないことの確認）。
\* 各式は「その状況には到達しない」という主張で、正しいモデルで TLC が違反を
\* 報告すれば、その状況が実際に探索されていることになる。check.sh が1つずつ
\* -inv で検査する。MCIndex.cfg の定数で全部に到達する。
EXTENDS MCIndex

\* 2つの主体が同じ葉を確保し、後の方は先に入った葉を見つけて自分の葉を返す
Reach_LeafRace == ~(\E t \in Threads : pc[t] = "A7" /\ tl[t])

\* 葉を確保している間に、ほかの主体がその葉の別のスロットに格納を終えている
Reach_LeafRaceWords ==
    ~(\E t \in Threads : pc[t] = "A6" /\ has[LeafOf(cur[t])]
                         /\ \E s \in Slots : LeafOf(s) = LeafOf(cur[t]) /\ s # cur[t]
                                             /\ wd[s] # Zero)

\* 葉を確保している間に swap_on がディレクトリを替えた
Reach_GrowDuringInsert == ~(\E t \in Threads : pc[t] = "A6" /\ g[t] # gen)

\* 解放で葉が空になり、外した葉を返そうとしている
Reach_LeafDetached == ~(\E t \in Threads : pc[t] = "C3" /\ det[t])

\* 葉を外す間に、ほかの主体が同じ葉に新しい葉を入れて格納している
Reach_DetachAndReinsert ==
    ~(\E t \in Threads : pc[t] = "C3" /\ det[t] /\ has[lf[t]])

\* 1つの葉の語を、ロックを2回に分けて外している（AZRAM_FREEBATCH）
Reach_FreeInBatches ==
    ~(\E t \in Threads : pc[t] = "C1" /\ lf[t] # 0
                         /\ \E s \in todo[t] : LeafOf(s) = lf[t])

\* 予算がいっぱいで、圧縮したページを断ろうとしている
Reach_BudgetFull ==
    ~(\E t \in Threads : pc[t] = "A2" /\ k[t] = "comp" /\ chunks >= PoolMax)

\* 予算からチャンクを取った後で、メモリがなくて返すかどうかの分かれ目にいる
Reach_ChunkTaken == ~(\E t \in Threads : pc[t] = "A3b" /\ chunks = PoolMax)

\* 2つ目のデバイスのスロットに語がある
Reach_SecondDevice == ~(\E s \in Slots : LeafOf(s) > NLeaves1 /\ wd[s] # Zero)

\* 語のあるスロットと、ないスロット（断られた）の両方を引こうとしている
Reach_LoadHitAndMiss ==
    ~(\E t \in Threads : pc[t] = "B0" /\ \E s, u \in my[t] : wd[s] # Zero /\ amap[u] = Zero)

=============================================================================
