<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="autumn-logo/autumnbsd-lockup-dark.svg">
    <img src="autumn-logo/autumnbsd-lockup.svg" alt="AutumnBSD" width="380">
  </picture>
</p>

# AutumnBSD

古い PC を、今でも快適に使えるようにするための、NetBSD ベースのデスクトップ向け OS です。

---

## AutumnBSD とは

AutumnBSD は NetBSD からフォークしたデスクトップ向けの BSD 系 OS です。  
HDD・少ないメモリ・古い CPU といった、遅い部品での待ち時間を減らすことに力を入れています。

### 誰のための OS か

- 10〜15 年ほど前のノート PC やデスクトップを、今も使っている人・使いたい人
- SSD への換装やメモリの増設をせずに、そのままの構成で快適さを上げたい人
- BSD に興味がある人、軽量なデスクトップ環境が好きな人

## 方針

- **遅いディスクに、できるだけ触らせない**: 先読みや圧縮メモリによって、HDD のシーク待ちやスワップによる停滞を減らします。
- **依存は最低限、見た目は綺麗に**: ソフトウェアの構成は小さく保ちつつ、デスクトップとしての見栄えも大切にします。
- **速さのために、正しさとデータの安全性は犠牲にしない**: `fsync` の約束は必ず守り、先読みがどこで失敗しても「先読みをしない」だけになるように作ります。
- **設計の要所は形式手法で確かめる**: `aprefetch` の先読みと通常の読み込み・アンマウントの並行動作は [TLA+ モデル](tla/aprefetch/README.md)で検証済みです。

## 主な機能と状態

| 機能 | 内容 | 状態 |
|---|---|---|
| **aprefetch** | 起動時・アプリ起動時の読み込みを記録し、次回はディスク上の物理位置（LBA）の順にまとめて先読みする AutumnBSD 独自の機構。散らばったランダムアクセスを 1 回のシーケンシャルなスイープに置き換える。 | 実装済み・実機テスト前（アプリ単位の先読みなどは未実装） |
| **圧縮メモリ** | スワップの前に RAM 上で LZ4 圧縮する（zram 相当）。あふれた未書き込みデータの一時置き場にも使う。 | 設計中 |
| **ディスプレイマネージャ** | 依存を最低限にした自作のログイン画面。パスワード入力中にセッションを先読みする。 | 構想段階 |
| **パッケージのインストール高速化** | 後処理や `fsync` をまとめて、HDD での待ち時間を減らす。 | 検討中 |

HDD 高速化（`aprefetch`）の詳しい設計・フェーズ分け・計測項目については、仕様書および TLA+ 検証ドキュメントを参照してください。

- [AutumnBSD HDD高速化 仕様書 (`AutumnBSD_SPEC_HDD.md`)](AutumnBSD_SPEC_HDD.md)
- [aprefetch TLA+ 仕様・モデル検査 (`tla/aprefetch/README.md`)](tla/aprefetch/README.md)
- マニュアルページ: [`aprefetch(4)`](share/man/man4/aprefetch.4), [`aprefd(8)`](usr.sbin/aprefd/aprefd.8), [`aprefctl(8)`](usr.sbin/aprefctl/aprefctl.8)

## 動作環境の目安

以下の実機を基準（ターゲット機）として設計・計測を進めています。

| 項目 | 構成 |
|---|---|
| 機種 | NEC LaVie S LS150/F（2011 年頃のノート PC） |
| CPU | Intel Pentium B950（2 コア 2 スレッド、2.1GHz、AES-NI なし） |
| メモリ | 4GB RAM |
| ストレージ | 512GB HDD |
| GPU | Intel HD Graphics（Sandy Bridge 世代、内蔵 GPU / `i915`） |

※ 起動時間やアプリ起動時間などの効果測定は、各機能の実装・評価にあわせて順次計測予定です（現時点の計測条件や記録は [仕様書の「計測と評価」](AutumnBSD_SPEC_HDD.md#計測と評価)を参照してください）。

## ビルドとインストール

一般向けのインストールイメージおよび導入手順は**準備中**です。

ソースツリー自体は NetBSD の `build.sh` の仕組みをそのまま引き継いでいるため、UNIX 系 OS 上からクロスビルドが可能です。たとえば `amd64` 向けのリリースイメージをビルドする場合は、リポジトリのルートで以下を実行します。

```sh
./build.sh -U -u -j4 -m amd64 -O ~/obj release
./build.sh -U -u -j4 -m amd64 -O ~/obj install-image
```

`build.sh` の詳細なオプションについては [BUILDING](BUILDING) を参照してください。

## 関連プロジェクト

- **NetBSD**: AutumnBSD のベースとなっている OS です。クリーンな設計と高い移植性を持つ NetBSD のコードベースの上に、古い PC 向けの改善を加えています。
- **KyanBSD**: AutumnBSD の姉妹プロジェクトです。FreeBSD をベースとし、ハイパーバイザや Frama-C による形式検証など、データセンター向けの堅牢さを目指しています。目指す方向は正反対ですが、自作ディスプレイマネージャなど一部のコンポーネントは共有する予定です。

## ライセンス

- AutumnBSD 独自の追加コード（`aprefetch` など）は **BSD-2-Clause** ライセンスの下で提供されます。
- ベースシステムは NetBSD のライセンス（主に BSD ライセンス群、および `external/` 等に含まれる各サードパーティライセンス）に従います。詳細は各ソースファイルのヘッダおよび [`doc/3RDPARTY`](doc/3RDPARTY) を参照してください。

## 貢献・連絡先

不具合の報告、設計へのフィードバック、パッチの提案などは GitHub の Issue または Pull Request へお寄せください。

- リポジトリ: <https://github.com/Serusion/AutumnBSD>
- Issue / Pull Request: <https://github.com/Serusion/AutumnBSD/issues>

