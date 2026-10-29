---
title: 【AWS Deep Cutsシリーズ】AWS Lambda MicroVMsって知ってる？AIが書いたコードを「使い捨てのVM」で安全に動かそう！
tags: AWS AWSDeepCuts Lambda MicroVMs Firecracker
author: kenken38
slide: false
---
:::note info
AWS Deep Cuts の GitHub はこちらです。
https://github.com/AWS-Deep-Cuts/AWS-Deep-Cuts
:::

# AWS Deep Cutsとは？
AWS Deep Cutsは、AWS の最新のサービスやニッチな機能、または高度にアカデミックな知識を要求するサービスなど、多くの人が知らない 『隠れた名曲 = **Deep Cuts**』 を深くまで掘り下げる技術シリーズです。

このようなサービスはWeb情報も少なく、初学者は気軽にキャッチアップできないのが実情です。

そこで AWS Deep Cuts シリーズでは、**前提知識も含めた分かりやすいサービス解説** と **手順通りに進めれば誰でも再現できるハンズオン** を提供します！

# そもそも「AIが書いたコードを動かす場所」はどこ？
生成 AI にコードを書かせるのは、もう日常になりました。次に誰もが思うのが「**書いたコードを、そのまま実行させたい**」です。データを集計して、グラフを描いて、結果を返してほしい。AI エージェントと呼ばれるものは、まさにこれを繰り返しています。

ところが、実行する場所に困ります。

| 実行する場所 | 困ること |
| --- | --- |
| 自分の PC | AI が `rm -rf` を書いてきたら終わり。信用できないコードを動かす場所ではない |
| Lambda 関数 | 1 回の実行は最長 15 分。リクエストごとに状態が消えるので「さっきの変数を使って」ができない |
| コンテナ（ECS など） | ホストとカーネルを共有するので、隔離としては VM より弱い |
| EC2 | 起動に 1 分前後。AI のセッションごとに 1 台用意するには高くて遅い |

欲しいのは「**数秒で起動し、途中の状態を保ったまま眠らせられ、壊れたら捨てられる、自分専用の小さな VM**」です。2026 年 6 月に登場した AWS Lambda MicroVMs は、まさにこのための仕組みです。

:::note info
**microVM（マイクロ VM）とは**
普通の仮想マシン（VM）から、要らない機能（グラフィック、USB、たくさんのデバイス……）をそぎ落として、数十〜数百ミリ秒で起動できるようにした軽量な VM のことです。AWS は 2018 年に **Firecracker** という microVM の技術を公開し、実は Lambda 関数はずっとこの microVM の中で動いてきました。Lambda MicroVMs は、その裏方だった microVM を「自分で起動したり眠らせたりできるリソース」として表に出したサービスです。
:::

# AWS Lambda MicroVMsとは？
AWS Lambda MicroVMs は、Firecracker の microVM を **API で起動・サスペンド・レジューム・終了できる** サーバーレスのコンピュート環境です。ユーザーや AI が生成したコードを、隔離された環境で実行することを主な用途として設計されています。

Lambda MicroVMs には、以下のような特徴があります。

- **1 台ずつ、自分で起動する**
  `RunMicrovm` を呼ぶと microVM が 1 台起動し、専用の HTTPS エンドポイントが付きます。イベントで呼ばれる Lambda 関数と違い、「セッション」の単位で 1 台を占有できます。寿命は最長 8 時間です。

- **状態を保ったまま眠らせられる**
  サスペンドすると、メモリ・ディスク・動いているプロセスがそのまま凍結されます。レジュームすると続きから動きます。眠っている間はコンピュート料金がかかりません。「しばらく使われなかったら自動で眠り、リクエストが来たら自動で起きる」設定（アイドルポリシー）もできます。

- **数秒で起動する**
  起動が速い理由は、イメージの作り方にあります（次の章で解説します）。

- **ポートで待ち受ける普通のサーバーが動く**
  中では HTTP サーバーでも WebSocket でも gRPC でも、ポートを開いて待ち受ける普通のプログラムが動きます。Lambda 関数のような「ハンドラー関数」の形に書き換える必要はありません。

- **料金は「動いていた時間」と「スナップショット」**
  稼働中は vCPU 秒とメモリ GB 秒、加えてスナップショットの読み書き（GB）と保存（GB 時間）で課金されます。東京リージョンの最小クラス（0.25 vCPU / 0.5 GB）なら 1 時間あたり約 $0.04、既定サイズ（1 vCPU / 2 GB）で約 $0.15 です（2026 年 10 月時点）。イメージの保存には最低 1 週間分の料金がかかります。

- **東京リージョンで使える**
  2026 年 6 月の発表時点から東京リージョンで提供されています（2026 年 10 月時点で 14 リージョン。大阪は未対応）。アーキテクチャは ARM64（Graviton）のみです。

# 仕組み：冷凍して、解凍して、また冷凍する
Lambda MicroVMs を理解するコツは、「**イメージ = 作りたての料理を急速冷凍したもの**」と考えることです。

## イメージを作る＝起動して、凍結する
普通のコンテナイメージは「ファイルの詰め合わせ」です。起動するたびに、プログラムを読み込んで初期化します。

MicroVM イメージは違います。`CreateMicrovmImage` を呼ぶと、Lambda は次のことをします。

1. Lambda が管理するベースイメージ（Amazon Linux 2023）から、まっさらな microVM を起動する
2. あなたが S3 に置いた zip の中の **Dockerfile** を実行して、依存関係を入れる
3. `ENTRYPOINT` / `CMD` で **アプリを起動する**
4. アプリが「準備できた」と HTTP で返事する（`/ready` フック）のを待つ
5. **メモリとディスクを、動いているプロセスごと凍結する**（スナップショット）

つまり、イメージの正体は「起動して初期化が終わった状態のメモリ」です。`RunMicrovm` はこの凍結状態の復元（解凍）なので、Python のインタプリタ起動やライブラリの読み込みは繰り返されません。これが「数秒で起動する」理由です。

![イメージはスナップショット](https://github.com/AWS-Deep-Cuts/aws-lambda-microvms/raw/main/img/architecture.png)

:::note info
**Lambda SnapStart との関係**
Lambda 関数には、初期化後のスナップショットから起動して遅延を減らす SnapStart という機能があります（2022 年に Java、2024 年に Python と .NET）。MicroVMs は同じ考え方を、任意のサーバープログラムに広げたものです。しかも `GetMicrovmImageBuild` という API で、メモリスナップショットのサイズをバイト単位で見られます。
:::

## 眠らせる＝食べかけを、また冷凍する
サスペンドは「止めて、あとで作り直す」操作ではありません。**メモリとディスクを凍結して、レジューム時に同じところから続ける** 操作です。変数の値も、プロセス ID も、開いていたファイルも残ります。

アイドルの判定は「**エンドポイントにリクエストが来ない時間**」で行われます。中で CPU を使い続けていても、外からリクエストが来なければ「アイドル」です。逆に、監視のつもりで `/health` を叩き続けると永遠に眠りません。

:::note warn
**同じ冷凍食品は、同じ味**
同じイメージから起動した microVM は、全部「同じメモリ」から始まります。ビルド時に作った乱数の状態、セッション ID、秘密情報は、全 microVM で共有されてしまいます。一意な値や秘密は、起動後（`/run` フック以降）に作りましょう。公式のベストプラクティスにもそう書かれています。
:::

## 話しかける＝専用エンドポイントと認証トークン
microVM には 1 台ずつ HTTPS のエンドポイントが付きます。ただし、認証なしではアクセスできません。`CreateMicrovmAuthToken` で発行した暗号化トークン（どの microVM の、どのポートに、いつまでアクセスしてよいか、が埋め込まれている。最長 60 分）を `X-aws-proxy-auth` ヘッダーに載せて送ります。転送先のポートは `X-aws-proxy-port` ヘッダーで指定し、省略すると 8080 番です。

## フック＝プラットフォームからの「お知らせ」
microVM の中のアプリは、ライフサイクルの節目にプラットフォームから HTTP で呼ばれます。

| フック | いつ | 使いどころ |
| --- | --- | --- |
| `/ready` | イメージのビルド中、アプリ起動後 | 初期化が終わったら 200 を返す（= 凍結してよい合図） |
| `/run` | 起動直後、外部トラフィックが来る前 | この 1 台だけの秘密情報を受け取る、乱数を作り直す |
| `/suspend` | 眠る直前 | 書きかけのデータを保存する |
| `/resume` | 起きた直後 | 外部との接続を張り直す（眠る前の接続は切れている） |
| `/terminate` | 終了直前 | 後始末 |

パスは `/aws/lambda-microvms/runtime/v1/<フック名>` という固定の形で、アプリが待ち受けるポートをイメージ作成時に指定します。

# AWS Lambda MicroVMsの主な活用事例
- **AI エージェントのコード実行サンドボックス**
  セッションごとに 1 台与え、会話の合間は眠らせ、終わったら捨てる。公式ドキュメントには Claude Managed Agents、OpenAI Agents API、Cursor のクラウドエージェント向けの統合ガイドがあります。
- **対話型の開発環境・教育環境**
  Jupyter や REPL、研修の受講者ごとの環境。放置されたら自動で眠るので、使われていない環境にお金を払わずに済みます。
- **CI/CD やビルドの実行環境**
  信用できない（外部からの）コードを、テナントごとに VM で隔離して動かす。
- **セッションを持つゲームサーバーや対戦サーバー**
  WebSocket で接続するサーバーをそのまま載せられます。
- **セキュリティスキャン**
  疑わしいファイルや解析ツールを隔離環境で動かす。

# AWS Lambda MicroVMsを使う際のベストプラクティス
- **寿命と眠りを必ず設定する**
  `maximumDurationInSeconds`（最長時間）と `idlePolicy`（アイドルで自動サスペンド、サスペンドが続いたら自動終了）を必ず設定し、「起動したのを忘れた microVM」を作らないようにしましょう。
- **一意な値は起動後に作る**
  乱数・セッション ID・秘密情報はビルド時に作らず、`/run` フック以降に作ります。乱数は CSPRNG（Python なら `secrets`）を使います。
- **出口を絞る**
  microVM は既定でインターネットに出られます。信用できないコードを動かすなら、VPC のネットワークコネクタで出口を制御しましょう。実行ロール（microVM が引き受ける IAM ロール）は最小権限にします。
- **トークンは短く、ポートは狭く**
  認証トークンは必要なポートだけに絞り、有効期限は 15〜30 分程度にします。
- **実行ロールを付ける**
  実行ロールが無いと、アプリのログが CloudWatch Logs に転送されません。
- **AI の書いたコードは、人間が見てから動かす**
  サンドボックスがあっても、実行前にコードを見せて承認する流れを作っておくと、事故が減ります。

# ハンズオンはこちら！
CloudShell から microVM の中の Python と会話できる「サンドボックス」を作り、Amazon Bedrock に書かせたコードをその中で動かします。眠らせても変数が残ること、わざと壊しても数秒で新しい VM が手に入ることを体験できます。

https://github.com/AWS-Deep-Cuts/aws-lambda-microvms

# まとめ
AWS Lambda MicroVMs は、「数秒で起動し、状態を保ったまま眠らせられ、壊れたら捨てられる VM」です。イメージの正体は起動済みメモリのスナップショットで、これが速さの理由であり、乱数や秘密情報の扱いに注意が要る理由でもあります。AI が書いたコードを安全に動かす場所に困っていたら、まず触ってみてください！

# もっと深く知りたい人へ
- **Firecracker の系譜**: 2018 年に公開された Firecracker は、NSDI '20 の論文で「最小限のデバイスモデル」「jailer による二重の隔離」「125 ms 程度の起動」が述べられています。2021 年の論文 "Restoring Uniqueness in MicroVM Snapshots" は、スナップショットから多数の VM を起動したときの乱数や ID の重複問題を整理したもので、本記事の「同じ冷凍食品は同じ味」の元ネタです。
- **Lambda の分化**: 2025〜2026 年に Lambda は、テナント分離モード、Managed Instances、Durable Functions、MicroVMs、Web Functions と形態を増やし、従来の関数は「Lambda Event Functions」と呼び直されました。使い分けの軸は「15 分で終わるか」「状態を持ちたいか」、そして「**誰のコードを動かすか**」だと筆者は考えています。自分のコードはイベント駆動の関数で、AI が書いたコードはセッションを持つサンドボックスで。
- **細かい仕様**: `runHookPayload`（`/run` フックに渡す起動ごとのデータ）の上限は、API 定義の制約値では 4,096 バイトです。クォータ超過の例外 `ServiceQuotaExceededException` の HTTP ステータスは、HTTP/1.1 の仕様で長らく「予約済み」だった **402 Payment Required** です。

---

参考文献
1. [AWS Lambda MicroVMs（開発者ガイド）](https://docs.aws.amazon.com/lambda/latest/dg/lambda-microvms-guide.html)
1. [AWS Lambda MicroVMs core concepts](https://docs.aws.amazon.com/lambda/latest/dg/microvms-how-it-works.html)
1. [MicroVM images](https://docs.aws.amazon.com/lambda/latest/dg/microvms-images.html) / [Best practices](https://docs.aws.amazon.com/lambda/latest/dg/microvms-best-practices.html)
1. [Run isolated sandboxes with full lifecycle control: AWS Lambda introduces MicroVMs（AWS News Blog）](https://aws.amazon.com/blogs/aws/run-isolated-sandboxes-with-full-lifecycle-control-aws-lambda-introduces-microvms/)
1. [AWS Lambda の料金](https://aws.amazon.com/lambda/pricing/)
1. [Firecracker: Lightweight Virtualization for Serverless Applications（NSDI '20）](https://www.usenix.org/conference/nsdi20/presentation/agache)
1. [Restoring Uniqueness in MicroVM Snapshots（arXiv:2102.12892）](https://arxiv.org/abs/2102.12892)
