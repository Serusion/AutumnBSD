--------------------------- MODULE MCProtocol_reach ---------------------------
\* AzramProtocol の到達確認（検査が空振りしていないことの確認）。
\* 各式は「その状況には到達しない」という主張で、正しいモデルで TLC が違反を
\* 報告すれば、その状況が実際に探索されていることになる。check.sh が1つずつ
\* -inv で検査する。MCProtocol_reach.cfg（swapctl -d と切り替えあり）で全部に
\* 到達する。
EXTENDS MCProtocol

\* 一度も書かれていないスロットの中身を、azram から読んでいる
Reach_LoadFromAzram ==
    ~(\E a \in Anons : pg[a] = "in" /\ idx[slot[a]] # Empty /\ disk[slot[a]] = Garbage
                       /\ pdata[a] = idx[slot[a]].v)

\* azram にないページを、ディスクから読んでいる
Reach_LoadFromDisk ==
    ~(\E a \in Anons : pg[a] = "in" /\ idx[slot[a]] = Empty /\ pdata[a] # Garbage)

\* azram が空で、ページインが索引を引かずにディスクへ行く（azram_empty()）
Reach_FastPath == ~(\E a \in Anons : pg[a] = "in" /\ nent = 0 /\ pdata[a] # Garbage)

\* 全バイト同じ値のページと、圧縮したページが、同時に索引にある
Reach_BothKinds ==
    ~(\E s, t \in Slots : idx[s].k = "same" /\ idx[t].k = "comp")

\* ページインした後もエントリが残り、きれいなページが書かずに解放される
Reach_CleanFreedKeepsEntry ==
    ~(\E a \in Anons : alive[a] /\ pg[a] = "none" /\ idx[slot[a]] # Empty
                       /\ val[a] = 1 /\ disk[slot[a]] = Garbage /\ pc["pd"] = "D0"
                       /\ \E b \in Anons : b # a /\ pg[b] = "none" /\ slot[b] # 0)

\* 書き込みで汚れたページのスロットに、古い中身のエントリが残っている
Reach_StaleEntryOfDirtyPage ==
    ~(\E a \in Anons : alive[a] /\ pg[a] = "dirty" /\ slot[a] # 0
                       /\ idx[slot[a]] # Empty /\ idx[slot[a]].v # <<a, val[a]>>)

\* まとまりの中で、格納したページの後ろに断ったページの塊がある
Reach_RunAfterStored ==
    ~(pc["pd"] = "D4" /\ 1 \in st /\ 2 \notin st)

\* 圧縮できるページが、プールの枠がいっぱいで断られる
Reach_BudgetFull ==
    ~(pc["pd"] = "D4" /\ items = PoolMax
      /\ \E j \in 1..Len(cpg) : j \notin st /\ Kind(cpg[j]) = "comp")

\* 圧縮できないページが、ディスクに書かれようとしている
Reach_IncompWritten == ~(\E w \in pending : \E j \in DOMAIN w[1] : Kind(w[1][j]) = "incomp")

\* azram が無効の間に、azram が持っているページをページインする
Reach_LoadWhileDisabled ==
    ~(~en /\ \E a \in Anons : pg[a] = "in" /\ idx[slot[a]] # Empty
                              /\ pdata[a] = idx[slot[a]].v)

\* 格納したページの完了前に anon が解放された（完了がエントリとスロットを捨てる）
Reach_ReleasedStored ==
    ~(\E a \in Anons : pg[a] = "out" /\ rel[a] /\ idx[slot[a]] # Empty /\ pc["pd"] = "D4")

\* ディスクへの書き込み中に anon が解放された
Reach_ReleasedWriting == ~(\E w \in pending : \E j \in DOMAIN w[1] : rel[w[1][j]])

\* ページインの読み込み中に anon が解放された
Reach_ReleasedReading == ~(\E a \in Anons : pc[a] = "P1" /\ rel[a])

\* 古いスロットを解放してから、新しいスロットにページアウトする
Reach_Reswapped ==
    ~(\E a \in Anons : pg[a] = "out" /\ val[a] = 1 /\ disk[slot[a]] = Garbage
                       /\ \E s \in Slots : disk[s] = <<a, 0>> /\ s \in free)

\* swapctl -d が、azram にあるページを読み戻している
Reach_SwapoffFromAzram ==
    ~(\E x \in SOs : pc[x] = "S2" /\ idx[slot[sa[x]]] # Empty)

\* swapctl -d が、読み戻すページのページアウトが終わるのを待っている
Reach_SwapoffWaitsPageout ==
    ~(\E x \in SOs : pc[x] = "S1" /\ \E a \in Anons : pg[a] = "out" /\ slot[a] # 0)

\* swapctl -d が読み戻している間に anon が解放された
Reach_SwapoffReleased == ~(\E x \in SOs : pc[x] = "S2" /\ rel[sa[x]])

\* swapctl -d が、ページデーモンが持つスロットのために EBUSY で終わる
Reach_SwapoffBusy == ~(\E x \in SOs : pc[x] = "Done" /\ ~soDone)

\* swapctl -d が、azram から読み戻したうえで通る
Reach_SwapoffDone == ~(soDone /\ seenSoAzram)

\* azram がページを持った後で、全部が解放されて静止する（CleanAtEnd の前提）
Reach_Quiescent == ~(Quiescent /\ seenStore)

=============================================================================
