---------------------------- MODULE MCProtocol ----------------------------
\* AzramProtocol.tla の検査に使う具体的な定数。
\*
\*   anon  版0      版1       （版は書き込むたびに1つ増える。書き込みは MaxVer 回まで）
\*   a1    same     comp      全バイト同じ値 → 圧縮できる
\*   a2    comp     incomp    圧縮できる → 圧縮できない
\*   a3    comp     same      圧縮できる → 全バイト同じ値（MC_Anons3 だけ）
\*
\* スロットの数、まとまりの大きさ、プールの枠などは .cfg で与える。
EXTENDS AzramProtocol, TLC

MC_Anons  == {"a1", "a2"}
MC_KindOf == ("a1" :> (0 :> "same" @@ 1 :> "comp"))
             @@ ("a2" :> (0 :> "comp" @@ 1 :> "incomp"))

MC_Anons3  == {"a1", "a2", "a3"}
MC_KindOf3 == MC_KindOf @@ ("a3" :> (0 :> "comp" @@ 1 :> "same"))

=============================================================================
