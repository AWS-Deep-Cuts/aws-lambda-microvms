このリポジトリは AWS Deep Cuts の、AWS Lambda MicroVMs に関するハンズオンコンテンツです。

<!-- TODO: 記事公開後にリンクを追加 -->
<!-- AWS Lambda MicroVMs の解説記事(Qiita)は[こちら]() -->

解説記事の原稿は [article/aws-lambda-microvms.md](./article/aws-lambda-microvms.md) にあります。

> **Note**: 2026 年 6 月に GA となった **AWS Lambda MicroVMs** を、東京リージョン（`ap-northeast-1`）で使います。AWS CLI は `aws lambda-microvms` に対応した **v2.35.10 以降** が必要です（CloudShell には最新版が入っています）。`:ai` コマンドでは Amazon Bedrock の **Amazon Nova 2 Lite**（`amazon.nova-2-lite-v1:0`、東京リージョンで直接呼び出し可）を使います。Bedrock が使えない場合はその機能だけスキップされます。

> ⚠️ **コストに関する注意**
>
> 起動する microVM は最小クラス（0.25 vCPU / 0.5 GB）で **約 $0.04/時間**、しかも **5 分放置で自動サスペンド、60 分で自動終了** する設定です。残るのはイメージ（スナップショット）の保存料金（最低 1 週間分、約 $0.07）だけです。`:ai` 1 回あたりの Bedrock の料金は 1 円未満です。
>
> | 放置期間 | 概算コスト |
> | --- | --- |
> | 1日 | 約 **$0.1**（約 15 円） |
> | 1週間 | 約 **$0.1**（イメージの保存は最低 1 週間分が課金されるため、1 日放置と変わりません） |
>
> **検証が終わったら速やかに後片付けを実施してください。**

# AWS Deep Cutsとは
AWS Deep Cutsは、AWS の最新のサービスやニッチな機能、または高度にアカデミックな知識を要求するサービスなど、多くの人が知らない 『隠れた名曲 = **Deep Cuts**』 を深くまで掘り下げる技術シリーズです。

このようなサービスはWeb情報も少なく、初学者は気軽にキャッチアップできないのが実情です。

そこで AWS Deep Cuts シリーズでは、**前提知識も含めた分かりやすいサービス解説** と **手順通りに進めれば誰でも再現できるハンズオン** を提供します！

# このハンズオンの物語

「AI にコードを書かせて、そのまま実行させたい」。生成 AI を使っていると、誰もが一度は思います。でも、どこで実行しますか？

- 自分の PC で動かす → AI が `rm -rf` を書いてきたら終わりです。
- Lambda 関数で動かす → 15 分で終わるうえ、リクエストごとに状態が消えます。「さっき定義した変数、覚えてる？」ができません。
- コンテナで動かす → ホストとカーネルを共有するので、隔離としては弱めです。
- EC2 を立てる → 起動に 1 分、1 人 1 台用意するには高くて遅いです。

欲しいのは、**数秒で起動し、途中の状態を保ったまま眠らせられ、壊れたら捨てられる、自分専用の小さな VM** です。それが Lambda MicroVMs です。

このハンズオンでは、CloudShell から microVM の中の Python と会話できる「サンドボックス」を作り、AI（Amazon Bedrock）に書かせたコードをその中で動かします。わざと壊して、捨てて、新しいのを数秒で手に入れるところまで体験します。

# ハンズオンのゴール

1. **会話する** — `>>>` プロンプトに Python を書くと、microVM の中で実行され、変数が残ること
2. **AI に書かせて、VM の中で動かす** — `:ai` で Bedrock にコードを書かせ、確認してから microVM で実行すること。危ないコードでも、あなたの CloudShell は無傷であること
3. **眠らせても覚えている** — `:sleep` でサスペンドし、`:wake` で起こすと変数がそのまま残っていること（眠っている間はコンピュート料金がかからない）
4. **壊しても捨てればいい** — `:break` でサンドボックスのプロセスを殺し、`:new` で新しい microVM を数秒で手に入れること
5. （発展）**同じ冷凍食品は同じ味** — 同じイメージから起動した 2 台が同じ乱数を出すかどうか

# ハンズオン手順

以降の手順は、ハンズオン用に用意した AWS アカウントで実施してください。

## 構築するアーキテクチャ

![構成図](img/architecture.png)

- `setup.sh` が、Python 標準ライブラリだけで書いた小さなサーバー（`hands-on/app/server.py`。Python コードを受け取って実行し、変数を保持する）を **MicroVM イメージ** にします。イメージの正体は「アプリを起動して初期化が終わった状態のメモリとディスクを丸ごと凍結したもの」です。
- `sandbox.py` が、そのイメージから microVM を 1 台起動（= 解凍）し、専用の HTTPS エンドポイント越しにコードを送ります。`:ai` では Amazon Bedrock にコードを書かせ、あなたが確認してから同じ経路で実行します。

## 前提条件

- AWS CloudShell（**東京リージョン**）。`aws`、`python3`、`zip` を使います
- 実行する IAM プリンシパルに、Lambda MicroVMs・IAM・S3・CloudWatch Logs・Bedrock の操作権限があること（`AdministratorAccess` 相当で実施するのが簡単です）

<details>
<summary>最小権限に近い IAM ポリシー例（実行者用）</summary>

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LambdaMicroVMs",
      "Effect": "Allow",
      "Action": [
        "lambda:ListManagedMicrovmImages", "lambda:ListManagedMicrovmImageVersions",
        "lambda:CreateMicrovmImage", "lambda:GetMicrovmImage", "lambda:GetMicrovmImageVersion",
        "lambda:ListMicrovmImageVersions", "lambda:ListMicrovmImageBuilds", "lambda:GetMicrovmImageBuild",
        "lambda:DeleteMicrovmImage", "lambda:DeleteMicrovmImageVersion",
        "lambda:RunMicrovm", "lambda:GetMicrovm", "lambda:ListMicrovms",
        "lambda:SuspendMicrovm", "lambda:ResumeMicrovm", "lambda:TerminateMicrovm",
        "lambda:CreateMicrovmAuthToken", "lambda:PassNetworkConnector",
        "lambda:TagResource", "lambda:ListTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Roles",
      "Effect": "Allow",
      "Action": ["iam:CreateRole", "iam:GetRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:DeleteRole", "iam:TagRole", "iam:PassRole"],
      "Resource": ["arn:aws:iam::*:role/aws-deepcuts-microvm-build-role", "arn:aws:iam::*:role/aws-deepcuts-microvm-exec-role"]
    },
    {
      "Sid": "ArtifactBucket",
      "Effect": "Allow",
      "Action": ["s3:CreateBucket", "s3:PutPublicAccessBlock", "s3:PutBucketVersioning", "s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:ListBucketVersions", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:DeleteBucket"],
      "Resource": ["arn:aws:s3:::aws-deepcuts-microvms-*", "arn:aws:s3:::aws-deepcuts-microvms-*/*"]
    },
    {
      "Sid": "Logs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:DescribeLogGroups", "logs:PutRetentionPolicy", "logs:TagResource", "logs:DeleteLogGroup", "logs:FilterLogEvents", "logs:GetLogEvents", "logs:DescribeLogStreams"],
      "Resource": "*"
    },
    {
      "Sid": "Bedrock",
      "Effect": "Allow",
      "Action": "bedrock:InvokeModel",
      "Resource": ["arn:aws:bedrock:ap-northeast-1::foundation-model/amazon.nova-2-lite-v1:0", "arn:aws:bedrock:ap-northeast-3::foundation-model/amazon.nova-2-lite-v1:0", "arn:aws:bedrock:ap-northeast-1:*:inference-profile/jp.amazon.nova-2-lite-v1:0"]
    },
    {
      "Sid": "Identity",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
```

`lambda:TagResource` が無いと `create-microvm-image --tags` が、`lambda:PassNetworkConnector` が無いと `run-microvm` が、それぞれメッセージ無しの `AccessDeniedException` になります（原因は CloudTrail に出ます）。
</details>

以降、各種コマンドは[CloudShell](https://docs.aws.amazon.com/cloudshell/latest/userguide/welcome.html)（東京リージョン）で実行してください。

## １．事前準備（イメージを「冷凍」する）

```bash
# このリポジトリをクローン
git clone https://github.com/AWS-Deep-Cuts/aws-lambda-microvms
cd aws-lambda-microvms/hands-on

# セットアップスクリプトの実行（イメージのビルドに数分かかります）
bash ./setup.sh

# 以下の文言が表示されればセットアップ成功です
# ✅ セットアップが完了しました！
```

setup.sh は、S3 バケットに `Dockerfile` と `server.py` を zip でアップロードし、ビルド用・実行用の IAM ロールとロググループを作り、`create-microvm-image` でイメージを作って完了を待ちます。

> **この手順で確かめること**
> - **やること**: ビルド完了後に表示される「このバージョンのビルド（スナップショット）」の表を見ます。
> - **期待する結果**: `memorySnapshotBytes`（メモリスナップショット）に数百 MB 規模の値が入っています。
> - **ここから分かること**: イメージのビルドは、Dockerfile を実行してコンテナを作るだけでなく、**アプリを起動し、初期化が終わった合図（`/ready` フック）を待ってから、メモリとディスクを丸ごと凍結** しています。作りたての料理を急速冷凍するようなものです。起動（`run-microvm`）はその解凍なので、Python の起動やモジュールの読み込みは繰り返されません。

## ２．サンドボックスと会話する

```bash
python3 sandbox.py
```

microVM が 1 台起動し（最長 60 分で自動終了、5 分放置で自動サスペンド）、`>>>` プロンプトが出ます。まずは普通に Python を書いてみてください。

```text
>>> secret = 42
>>> print(secret * 2)
84
>>> import os, platform; print(platform.machine(), os.getpid())
aarch64 ...
>>> :vars
```

> **この観点で確かめること**
> - **やること**: 変数を定義し、別の行から参照します。`:vars` で変数一覧とフック履歴を見ます。
> - **期待する結果**: 変数は残っています。CPU は `aarch64`（Graviton）です。フック履歴に `run` が記録され、その body に `sandbox.py` が渡したペイロードが入っています。
> - **ここから分かること**: microVM の中では **1 つの Python プロセスが生き続けて** います。Lambda 関数のように呼び出しごとに環境が入れ替わることはありません。`run` フックは「起動した直後に、プラットフォームがアプリに HTTP で知らせてくる」仕組みで、この 1 台だけの秘密情報を渡す経路に使えます。

## ３．AI にコードを書かせて、VM の中で動かす

```text
>>> :ai 1 から 100 までの素数を表示して
```

Bedrock が書いたコードが表示されるので、内容を見て `y` を押すと microVM の中で実行されます。いくつか試してみてください。

```text
>>> :ai さっき定義した secret という変数を使って、その数の階乗を計算して
>>> :ai /app 以下のファイルを全部削除して
>>> :ai 100MB のメモリを確保して、確保できた量を表示して
```

> **この観点で確かめること**
> - **やること**: 役に立つお願いと、危ないお願い（ファイルの削除など）を両方試します。
> - **期待する結果**: どれも microVM の中で実行され、結果が返ります。`/app` を消しても、あなたの CloudShell には何も起きません（`sandbox.py` も `server.py` のコピーもそのまま残っています）。
> - **ここから分かること**: **AI の書いたコードを実行しているのは、あなたの環境ではなく、使い捨ての VM** です。コードを実行前に見せて `y` を押させる設計は、「AI が書いたものを人間が承認してから動かす」という、生成 AI 時代の基本的な安全策です。

## ４．眠らせても覚えている

```text
>>> counter = 1
>>> :sleep
>>> :wake
>>> print(counter)
```

> **この観点で確かめること**
> - **やること**: 変数を定義してから `:sleep` でサスペンドし、`:wake` で起こします。表示される「変数」「boot_id」「時計」を見ます。
> - **期待する結果**: 変数は残り、`boot_id`（プロセス起動時に生成した値）も変わりません。フック履歴に `suspend` と `resume` が追加されています。レジュームにかかる時間は数秒です。
> - **ここから分かること**: サスペンドは「止めて作り直す」のではなく、**メモリとディスクを凍結して、同じところから続ける** 操作です。眠っている間はコンピュート料金がかからず、スナップショットの保存料金だけになります。「時計」の表示で、眠っていた時間が壁時計・単調時計にどう反映されたかも分かります。

5 分以上放置してから何か実行すると、`💤 microVM は眠っていました。リクエストを送って起こします…` と表示されます。これが **アイドルポリシー** です。「エンドポイントにリクエストが来ない時間」が閾値を超えると自動でサスペンドされ、リクエストが来ると自動で起きます。

## ５．壊しても捨てればいい

```text
>>> :break
>>> :new
>>> print(secret)
```

> **この観点で確かめること**
> - **やること**: `:break` でサンドボックスのプロセスを殺し、`:status` で状態を見てから、`:new` で新しい microVM に取り替えます。
> - **期待する結果**: `:break` の後は `/ping` が応答しなくなります。`:new` は数秒で新しい 1 台を用意します。新しい microVM では `secret` は未定義です（別の個体なので）。
> - **ここから分かること**: 壊れた環境を直す必要はありません。**イメージ（冷凍したもの）から解凍し直せば、数秒で初期状態に戻ります**。AI エージェントのセッションごとに 1 台与えて、終わったら捨てる、という使い方が自然にできます。

終わるときは `:quit` です。microVM を終了するか聞かれます。

## ６．（発展）同じ冷凍食品は同じ味 — 双子の microVM と乱数

```bash
bash ./twins.sh
```

> **この観点で確かめること**
> - **やること**: 同じイメージから microVM を 2 台起動し、それぞれの `/random`（`random.random()`、`os.urandom()`、`uuid4()`）を 1 回ずつ取得して比べます。
> - **期待する結果**: 結果を記録してください。`random.random()` は、プロセス起動時（= イメージのビルド時）に seed されているため、同じ値が出る可能性があります。
> - **ここから分かること**: 2 台は **同じメモリスナップショットから復元** されています。乱数の状態、セッション ID、秘密情報などをビルド時に作ると、全 microVM で共有されてしまいます。公式のベストプラクティスも「一意な値や秘密は起動後（`run` フック以降）に作り、乱数は CSPRNG を使う」と案内しています。

## ７．後片付け

検証が終わったら、無駄な課金を防ぐためにリソースを削除しましょう。

CloudShellで以下のコマンドを実行することで、今回作成したリソースを綺麗に削除することができます！

```bash
cd aws-lambda-microvms/hands-on
bash ./cleanup.sh

# 以下の文言が表示されればクリーンアップ成功です
# ✅ すべてのリソースの削除が完了しました！

cd ../..
sudo rm -rf aws-lambda-microvms
```

## トラブルシューティング

| 表示されるエラー | 主な原因 | 対処 |
| -- | -- | -- |
| `lambda-microvms コマンドに対応していません` | AWS CLI が古い | AWS CLI v2 を最新版に更新する。CloudShell なら新しいセッションを開く |
| `AccessDeniedException`（メッセージ無し） | Lambda MicroVMs 未提供のリージョン、または `lambda:TagResource` / `lambda:PassNetworkConnector` などの権限不足 | リージョンを `ap-northeast-1` にする。CloudTrail で拒否されたアクションを確認する |
| イメージが `CREATE_FAILED` | Dockerfile の失敗（`CONTAINER_BUILD_FAILED`）、zip のルートに Dockerfile が無い（`ARCHIVE_DOCKERFILE_NOT_FOUND`）、`/ready` フックが 200 を返さない | CloudWatch Logs の `/aws/lambda-microvms/aws-deepcuts` と、`list-microvm-image-builds` の `stateReason` を見る |
| `A MicroVM image with the name ... already exists` | 前回のイメージが残っている | `cleanup.sh` を実行してから `setup.sh` をやり直す |
| `:ai` で `Bedrock を呼べませんでした` | Bedrock の権限不足、モデル ID がリージョンで使えない | `bedrock:InvokeModel` を付与する。`aws bedrock list-foundation-models --region ap-northeast-1 --by-provider Amazon` で使えるモデルを確認し、環境変数 `DEEPCUTS_MODEL` で指定する（例: `jp.amazon.nova-2-lite-v1:0`） |
| エンドポイントが `502` | サンドボックスのプロセスが死んでいる（`:break` の後など）、起動直後の数秒 | `:new` で取り替える。少し待つ |
| `ServiceQuotaExceededException`（HTTP 402） | 同時に動かせる microVM のメモリ合計のクォータ超過 | 不要な microVM を終了する（`cleanup.sh` がまとめて終了します） |

## 参考リンク

- [AWS Lambda MicroVMs（開発者ガイド）](https://docs.aws.amazon.com/lambda/latest/dg/lambda-microvms-guide.html) / [Create your first Lambda MicroVM](https://docs.aws.amazon.com/lambda/latest/dg/microvms-getting-started.html) / [MicroVM images](https://docs.aws.amazon.com/lambda/latest/dg/microvms-images.html) / [Running and using MicroVMs](https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html) / [Best practices](https://docs.aws.amazon.com/lambda/latest/dg/microvms-best-practices.html)
- [Lambda MicroVMs API Reference](https://docs.aws.amazon.com/lambda/latest/microvm-api/Welcome.html) / [AWS CLI `lambda-microvms`](https://docs.aws.amazon.com/cli/latest/reference/lambda-microvms/)
- [Run isolated sandboxes with full lifecycle control: AWS Lambda introduces MicroVMs（AWS News Blog）](https://aws.amazon.com/blogs/aws/run-isolated-sandboxes-with-full-lifecycle-control-aws-lambda-introduces-microvms/)
- [Amazon Bedrock Converse API](https://docs.aws.amazon.com/bedrock/latest/userguide/conversation-inference.html)
