<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="autumn-logo/autumnbsd-lockup-dark.svg">
    <img src="autumn-logo/autumnbsd-lockup.svg" alt="AutumnBSD" width="380">
  </picture>
</p>

# AutumnBSD

古い PC をもう少し快適に使うための、NetBSD ベースのデスクトップ向け OS です。

10 年以上前のノート PC を、SSD への換装やメモリの増設なしで使っていると、待たされるのはたいてい HDD のシークか、メモリ不足によるスワップです。AutumnBSD は、その待ち時間を OS の側で減らすことを目指しています。

## いまあるもの: aprefetch

起動時に読んだファイルと FFS のメタデータを記録しておき、次の起動では、それをディスク上の位置の順に並べ替えてまとめて先読みします。ばらばらのランダムアクセスを、1 回の掃引に近づけるための仕組みです。

下のターゲット機では、ユーザランド（init から login プロンプトまで）が 16.2 秒から 7.3 秒になりました（5 回の中央値）。postfix の起動を待たないようにした分も合わせると 5.4 秒です（まだ 1 回しか測っていません）。アプリ単位の先読みは、まだありません。

- [HDD 高速化の仕様書](AutumnBSD_SPEC_HDD.md): 設計、フェーズ分け、計測の結果
- [TLA+ のモデル](tla/aprefetch/README.md): 先読みと、通常の読み込みやアンマウントが同時に起きる場合のモデル検査
- マニュアル: [aprefetch(4)](share/man/man4/aprefetch.4)、[aprefd(8)](usr.sbin/aprefd/aprefd.8)、[aprefctl(8)](usr.sbin/aprefctl/aprefctl.8)

## これから

- 圧縮メモリ（設計中）: スワップに出す前に、RAM 上で LZ4 で圧縮します。zram のようなものです。書き出しきれないデータの一時置き場にも使うつもりです。
- ディスプレイマネージャ（構想段階）: 依存の少ない、自作のログイン画面です。パスワードを打っている間に、セッションを先読みします。
- パッケージのインストール（検討中）: 後処理や `fsync` をまとめて、HDD での待ち時間を減らします。

## 方針

- 速さのために、正しさとデータの安全は削りません。`fsync` の約束は守りますし、先読みはどこで失敗しても「先読みしなかった」だけで済むように作ります。
- 設計の要所は形式手法で確かめます。aprefetch は TLA+ でモデル検査しました。
- 依存は少なく保ちます。それでも、デスクトップとしての見た目には気を配ります。

## ターゲット機

設計と計測は、この実機を基準にしています。

- 機種: NEC LaVie S LS150/F（2011 年ごろのノート PC）
- CPU: Intel Pentium B950（2.1GHz、2 コア 2 スレッド、AES-NI なし）
- メモリ: 4GB
- ストレージ: 512GB HDD
- GPU: Intel HD Graphics（Sandy Bridge 世代、i915）

## ビルド

インストール用のイメージは、まだ配布していません。

ビルドの仕組みは NetBSD の `build.sh` そのままなので、UNIX 系の OS からクロスビルドできます。amd64 向けのリリースとインストールイメージを作るなら、リポジトリのルートで次のようにします。

```sh
./build.sh -U -u -j4 -m amd64 -O ~/obj release
./build.sh -U -u -j4 -m amd64 -O ~/obj install-image
```

オプションについては [BUILDING](BUILDING) を見てください。

## 関連プロジェクト

- [NetBSD](https://www.NetBSD.org/): AutumnBSD のベースです。
- KyanBSD: 姉妹プロジェクトです。FreeBSD をベースに、ハイパーバイザや Frama-C による形式検証など、データセンター向けの堅牢さを狙っています。向かう先は逆ですが、ディスプレイマネージャなど一部は共有する予定です。

## ライセンス

AutumnBSD で足したコード（aprefetch など）は BSD-2-Clause です。それ以外は NetBSD のライセンスに従います。`external/` などのサードパーティのものについては、各ソースファイルと [doc/3RDPARTY](doc/3RDPARTY) を見てください。

## 連絡先

不具合の報告や提案は、[Issue](https://github.com/Serusion/AutumnBSD/issues) か Pull Request でどうぞ。
