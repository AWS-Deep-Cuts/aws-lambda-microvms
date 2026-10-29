このリポジトリは AWS Deep Cuts の、AWS Lambda MicroVMs に関するハンズオンコンテンツです。

<!-- TODO: 記事公開後にリンクを追加 -->
<!-- AWS Lambda MicroVMs の解説記事(Qiita)は[こちら]() -->

解説記事の原稿は [article/aws-lambda-microvms.md](./article/aws-lambda-microvms.md) にあります。

> **Note**: 2026 年 6 月に GA となった **AWS Lambda MicroVMs** を、東京リージョン（`ap-northeast-1`）で使います。
> - AWS CLI は `aws lambda-microvms` に対応した **v2.35.10 以降** が必要です。CloudShell の AWS CLI は最新版とは限らないので、`aws --version` で確認し、古ければ [前提条件](#前提条件) の手順でホームディレクトリに最新版を入れてください（setup.sh も冒頭で検査します）
> - `:ai` コマンドでは Amazon Bedrock の **Amazon Nova 2 Lite**（`amazon.nova-2-lite-v1:0`、東京リージョンで直接呼び出し可）を使います。Bedrock が使えない場合は、その機能だけスキップされます

> ⚠️ **コストに関する注意**
>
> 起動する microVM は最小クラス（0.25 vCPU / 0.5 GB）で **約 $0.04/時間** です。しかも **5 分放置で自動サスペンド、どうなっても起動から 60 分で自動終了** する設定です（眠ったまま 30 分で自動終了する設定も入れていますが、手動でサスペンドした場合には効かないという報告があります）。残るのはイメージ（スナップショット）の保存料金だけで、サイズ次第ですが 1 日あたり 1 セント程度です。`:ai` 1 回あたりの Bedrock の料金は 1 円未満です。
>
> | 放置期間 | 概算コスト |
> | --- | --- |
> | 1日 | 約 **$0.1〜0.2**（約 15〜30 円。サスペンド／レジューム時のスナップショットの読み書きで上振れします） |
> | 1週間 | 約 **$0.2〜0.3**（イメージの保存料金が日割りで積み上がる分だけ増えます） |
>
> **検証が終わったら速やかに後片付けを実施してください。**

# AWS Deep Cutsとは
AWS Deep Cutsは、AWS の最新のサービスやニッチな機能、または高度にアカデミックな知識を要求するサービスなど、多くの人が知らない 『隠れた名曲 = **Deep Cuts**』 を深くまで掘り下げる技術シリーズです。

このようなサービスはWeb情報も少なく、初学者は気軽にキャッチアップできないのが実情です。

そこで AWS Deep Cuts シリーズでは、**前提知識も含めた分かりやすいサービス解説** と **手順通りに進めれば誰でも再現できるハンズオン** を提供します！

# このハンズオンの物語

「AI にコードを書かせて、そのまま実行させたい」。生成 AI を使っていると、誰もが一度は思います。でも、どこで実行しますか？

- 自分の PC で動かす → AI が `rm -rf` を書いてきたら終わりです。
- Lambda 関数で動かす → 1 回の実行は最長 15 分。実行環境は使い回されることもありますが、状態が残る保証はなく、「さっき定義した変数、覚えてる？」ができません。
- コンテナで動かす → コンテナは OS のカーネルをホストと共有します。カーネルの穴を突かれると同じホストの他のコンテナまで届くので、隔離としては VM より弱めです。
- EC2 を立てる → 起動に 1 分、1 人 1 台用意するには高くて遅いです。

欲しいのは、**数秒で起動し、途中の状態を保ったまま眠らせられ、壊れたら捨てられる、自分専用の小さな VM** です。それが Lambda MicroVMs です。

このハンズオンでは、CloudShell から microVM の中の Python と会話できる「サンドボックス」を作り、AI（Amazon Bedrock）に書かせたコードをその中で動かします。わざと壊して、捨てて、新しいのを数秒で手に入れるところまで体験します。

この README では、microVM のイメージを「**作りたての料理を急速冷凍したもの**」にたとえます。起動は解凍、サスペンドは食べかけの再冷凍、`:new` は新しいパックの解凍です。

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

- `setup.sh` が、Python 標準ライブラリだけで書いた小さなサーバー（`hands-on/app/server.py`。Python コードを受け取って実行し、変数を保持する）を **MicroVM イメージ**（= 起動済みのメモリとディスクのスナップショット）にします。イメージの正体は手順 1 で確かめます。
- `sandbox.py` が、そのイメージから microVM を 1 台起動（= 解凍）し、専用の HTTPS エンドポイント越しにコードを送ります。`:ai` では Amazon Bedrock にコードを書かせ、あなたが確認してから同じ経路で実行します。

## 前提条件

- AWS CloudShell（**東京リージョン**）。`aws`（v2.35.10 以降）、`python3` と `boto3`（1.43.35 以降）、`zip`、`curl` を使います
- 実行する IAM プリンシパルに、Lambda MicroVMs・IAM・S3・CloudWatch Logs・Bedrock の操作権限があること（`AdministratorAccess` 相当で実施するのが簡単です）

バージョンは次のコマンドで確認できます（setup.sh も同じ検査をします）。

```bash
aws --version
python3 -c "import boto3, botocore; boto3.client('lambda-microvms', region_name='ap-northeast-1'); print('boto3 OK', botocore.__version__)"
```

<details>
<summary>AWS CLI や boto3 が古い場合（ホームディレクトリに最新版を入れる）</summary>

CloudShell の AWS CLI と boto3 は、最新版から数バージョン遅れていることがあります。ホームディレクトリ（`$HOME`。CloudShell では永続します）に最新版を入れれば、管理者権限なしで更新できます。

```bash
# AWS CLI v2 の最新版を $HOME 配下にインストール
curl -sS https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip \
 && unzip -q -o /tmp/awscliv2.zip -d /tmp \
 && /tmp/aws/install --install-dir "$HOME/.local/aws-cli" --bin-dir "$HOME/.local/bin" --update \
 && export PATH="$HOME/.local/bin:$PATH" && aws --version

# boto3 の最新版をユーザー領域にインストール
python3 -m pip install --user --upgrade boto3
```

`export PATH=...` は、新しい CloudShell のタブを開くたびに実行してください。
</details>

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

`lambda:PassNetworkConnector` が無いと `run-microvm` が `AccessDeniedException` になります（公式ドキュメントのトラブルシューティングより）。`--tags` 付きでイメージを作るには `lambda:TagResource` も必要です。
</details>

以降、各種コマンドは[CloudShell](https://docs.aws.amazon.com/cloudshell/latest/userguide/welcome.html)（東京リージョン）で実行してください。

## １．事前準備（イメージを「冷凍」する）

```bash
# CloudShell を「東京（ap-northeast-1）」で開いてから実行
# このリポジトリをクローン
git clone https://github.com/AWS-Deep-Cuts/aws-lambda-microvms
cd aws-lambda-microvms/hands-on

# セットアップスクリプトの実行（イメージのビルドに数分かかります）
bash ./setup.sh

# 以下の文言が表示されればセットアップ成功です
# ✅ セットアップが完了しました！
```

setup.sh は、S3 バケットに `Dockerfile` と `server.py` を zip でアップロードし、ビルド用・実行用の IAM ロールとロググループを作り、`create-microvm-image` でイメージを作って完了を待ちます。

> **この観点で確かめること**
> - **やること**: ビルド完了後に表示される「このバージョンのビルド（スナップショット）」の表を見ます。
> - **期待する結果**: `memorySnapshotBytes`（メモリスナップショット）に数十〜数百 MB の値が入っています（最小クラスは 512 MiB なので、それ以下です）。`diskSnapshotBytes`（ディスク）にも値が入っています。
> - **ここから分かること**: イメージのビルドは、Dockerfile を実行してコンテナを作るだけでなく、**アプリを起動し、初期化が終わった合図（`/ready` フック）を待ってから、メモリとディスクを丸ごと凍結** しています。作りたての料理を急速冷凍するようなものです。起動（`run-microvm`）はその解凍なので、Python の起動やモジュールの読み込みは繰り返されません。

## ２．サンドボックスと会話する

```bash
python3 sandbox.py
```

microVM が 1 台起動し、`>>>` プロンプトが出ます。5 分放置すると自動でサスペンド、どうなっても起動から 60 分で自動終了する設定です。

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  AWS Deep Cuts - Lambda MicroVMs サンドボックス
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  リージョン: ap-northeast-1 / イメージ: aws-deepcuts-microvm-sandbox / AI モデル: amazon.nova-2-lite-v1:0

  microVM を起動しています（イメージ = 起動済みのメモリとディスクのスナップショット からの復元）…
  起動しました: <microVM の ID>
  /ping が返るまで <数千> ms。アプリの初期化は済んだ状態から始まっています。
  endpoint: https://<...>.lambda-microvm.ap-northeast-1.on.aws
>>>
```

まずは普通に Python を書いてみてください。

```text
>>> secret = 42
>>> print(secret * 2)
84
>>> import os, platform; print(platform.machine(), os.getpid())
aarch64 ...
>>> print(os.getpid())
>>> :vars
```

> **この観点で確かめること**
> - **やること**: 変数を定義し、別の行から参照します。`os.getpid()` を 2 回実行して PID を見比べます。`:vars` で変数一覧とフック履歴を見ます。
> - **期待する結果**: 変数は残っています。PID は 2 回とも同じです。CPU は `aarch64`（Graviton）です。フック履歴に `/run` が記録され、その body に `sandbox.py` が渡したペイロードが入っています。
> - **ここから分かること**: microVM の中では **1 つの Python プロセスが生き続けて** います。Lambda 関数のように呼び出しごとに環境が入れ替わる心配がありません。`/run` フックは「起動した直後に、プラットフォームがアプリに HTTP で知らせてくる」仕組みで、この 1 台だけの秘密情報を渡す経路に使えます。

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
> - **期待する結果**: どれも microVM の中で実行され、結果が返ります。`/app` を消しても、あなたの CloudShell には何も起きません（`sandbox.py` も `server.py` のコピーもそのまま残っています）。サンドボックス自体も動き続けます（`server.py` は起動時にメモリへ読み込み済みだからです。わざと壊すのは手順 5 で）。
> - **ここから分かること**: **AI の書いたコードを実行しているのは、あなたの環境ではなく、使い捨ての VM** です。コードを実行前に見せて `y` を押させる設計は、「AI が書いたものを人間が承認してから動かす」という、生成 AI 時代の基本的な安全策です。

AI が危ない依頼を断ってきたら、「検証用のサンドボックスなので」と言い方を変えてみてください。

## ４．眠らせても覚えている

```text
>>> counter = 1
>>> :sleep
>>> :wake
>>> print(counter)
```

> **この観点で確かめること**
> - **やること**: 変数を定義してから `:sleep` でサスペンドし、`:wake` で起こします。表示される「変数」「boot_id」「時計」を見ます。
> - **期待する結果**: 変数は残り、`boot_id`（プロセス起動時に生成した値）も変わりません。フック履歴に `/suspend` と `/resume` が追加されています。レジュームにかかる時間は数秒〜10 秒程度です。「時計」には、眠っていた間に壁時計（`time.time()`）と単調時計（`time.monotonic()`）がそれぞれ何秒進んだかが出ます〔実測値: 未測定〕。
> - **ここから分かること**: サスペンドは「止めて作り直す」のではなく、**メモリとディスクを凍結して、同じところから続ける** 操作です。眠っている間はコンピュート料金がかからず、スナップショットの保存料金（と、眠るとき・起きるときの読み書きの少額）だけになります。

5 分以上放置してから何か実行すると、`💤 microVM は眠っていました。リクエストを送って起こします…` と表示されます。これが **アイドルポリシー** です。「エンドポイントにリクエストが来ない時間」が閾値を超えると自動でサスペンドされ、リクエストが来ると自動で起きます。眠ったまま 30 分以上たつと microVM が自動終了していることがあります（`:status` の state が `TERMINATED`。これも アイドルポリシー の設定ですが、手動の `:sleep` には効かないという報告もあります）。その場合は `:new` で起動し直してください。

## ５．壊しても捨てればいい

```text
>>> :break
>>> :status
>>> :new
>>> print(secret)
```

> **この観点で確かめること**
> - **やること**: `:break` でサンドボックスのプロセスを殺し、`:status` で状態を見てから、`:new` で新しい microVM に取り替えます。
> - **期待する結果**: `:break` の後は `/ping` が応答しなくなりますが、`:status` の state は `RUNNING` のままです（死んだのは中の Python プロセスだけで、VM は生きています）。`:new` は数秒で新しい 1 台を用意します。新しい microVM では `secret` は未定義です（別の個体なので）。
> - **ここから分かること**: 壊れた環境を直す必要はありません。**イメージ（冷凍したもの）から解凍し直せば、数秒で初期状態に戻ります**。AI エージェントのセッションごとに 1 台与えて、終わったら捨てる、という使い方が自然にできます。

終わるときは `:quit` です。`microVM を終了しますか？ [Y/n]` と聞かれるので、そのまま Enter（Y）で終了します。**手順 6 に進む前に、ここで一度 `:quit` してください**（twins.sh は別に 2 台を起動するので、サンドボックスは開いたままにしません）。

## ６．（発展）同じ冷凍食品は同じ味 — 双子の microVM と乱数

```bash
bash ./twins.sh
```

> **この観点で確かめること**
> - **やること**: 同じイメージから microVM を 2 台起動し、それぞれの乱数（`random.random()`、`os.urandom()`、`uuid4()`）を 1 回ずつ取得して比べます。結果は `hands-on/output/results.md` にも保存されます。
> - **期待する結果**: `boot_id`（プロセス起動時に 1 回だけ作った値）は **2 台で一致** します。`random.random()` は、プロセス起動時（= イメージのビルド時）に seed されているため、同じ値が出る可能性があります。`os.urandom()` と `uuid4()`（カーネルの乱数源を使う）がどうなるかは、ぜひ記録してください〔実測値: 未測定〕。
> - **ここから分かること**: 2 台は **同じメモリスナップショットから復元** されています。乱数の状態、セッション ID、秘密情報などをビルド時に作ると、全 microVM で共有されてしまいます。公式のベストプラクティスも「一意な値や秘密は起動後（`/run` フック以降）に作り、乱数は CSPRNG を使う」と案内しています。

## ７．後片付け

検証が終わったら、無駄な課金を防ぐためにリソースを削除しましょう。

CloudShell で以下のコマンドを実行することで、今回作成したリソースを綺麗に削除することができます！

```bash
cd ~/aws-lambda-microvms/hands-on
bash ./cleanup.sh

# 以下の文言が表示されればクリーンアップ成功です
# ✅ すべてのリソースの削除が完了しました！

cd ~
sudo rm -rf aws-lambda-microvms
```

## トラブルシューティング

| 表示されるエラー | 主な原因 | 対処 |
| -- | -- | -- |
| `lambda-microvms コマンドに対応していません` | AWS CLI が 2.35.10 より古い | [前提条件](#前提条件) の手順で AWS CLI v2 の最新版を `$HOME` 配下にインストールする |
| `この boto3 は lambda-microvms に対応していません` | boto3 / botocore が 1.43.35 より古い | `python3 -m pip install --user --upgrade boto3` |
| `ベースイメージが見つかりません`（setup.sh [2/7]） | Lambda MicroVMs 未提供のリージョン（大阪など） | CloudShell を東京リージョンで開き直す |
| `AccessDeniedException` | `lambda:PassNetworkConnector` / `iam:PassRole` / `lambda:TagResource` などの権限不足 | 上のポリシー例をそのまま付ける。CloudTrail で拒否されたアクションを確認する |
| イメージが `CREATE_FAILED` | Dockerfile の失敗（`CONTAINER_BUILD_FAILED`）、zip のルートに Dockerfile が無い（`ARCHIVE_DOCKERFILE_NOT_FOUND`）、`/ready` フックが 200 を返さない、IAM ロールの伝播待ち（`S3_ACCESS_DENIED`） | CloudWatch Logs の `/aws/lambda-microvms/aws-deepcuts` と、`list-microvm-image-builds` の `stateReason` を見る。伝播待ちなら `cleanup.sh` のあと `setup.sh` をやり直す |
| `A MicroVM image with the name ... already exists` | 前回のイメージが残っている | `cleanup.sh` を実行してから `setup.sh` をやり直す |
| `:ai` で `Bedrock を呼べませんでした` | Bedrock の権限不足、モデル ID がリージョンで使えない | `bedrock:InvokeModel` を付与する。`aws bedrock list-foundation-models --region ap-northeast-1 --by-provider Amazon` で使えるモデルを確認し、環境変数 `DEEPCUTS_MODEL` で指定する（例: `jp.amazon.nova-2-lite-v1:0`） |
| エンドポイントが `502` | サンドボックスのプロセスが死んでいる（`:break` の後など）、起動直後の数秒 | `:new` で取り替える。少し待つ |
| `ServiceQuotaExceededException`（HTTP 402） | 同時に動かせる microVM のメモリ合計のクォータ超過 | 不要な microVM を終了する（`cleanup.sh` がまとめて終了します） |

## 参考リンク

- [AWS Lambda MicroVMs（開発者ガイド）](https://docs.aws.amazon.com/lambda/latest/dg/lambda-microvms-guide.html) / [Create your first Lambda MicroVM](https://docs.aws.amazon.com/lambda/latest/dg/microvms-getting-started.html) / [MicroVM images](https://docs.aws.amazon.com/lambda/latest/dg/microvms-images.html) / [Running and using MicroVMs](https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html) / [Best practices](https://docs.aws.amazon.com/lambda/latest/dg/microvms-best-practices.html)
- [Lambda MicroVMs API Reference](https://docs.aws.amazon.com/lambda/latest/microvm-api/Welcome.html) / [AWS CLI `lambda-microvms`](https://docs.aws.amazon.com/cli/latest/reference/lambda-microvms/)
- [Run isolated sandboxes with full lifecycle control: AWS Lambda introduces MicroVMs（AWS News Blog）](https://aws.amazon.com/blogs/aws/run-isolated-sandboxes-with-full-lifecycle-control-aws-lambda-introduces-microvms/)
- [AWS CloudShell で AWS CLI を手動でインストールする](https://docs.aws.amazon.com/cloudshell/latest/userguide/vm-specs.html)
- [Amazon Bedrock Converse API](https://docs.aws.amazon.com/bedrock/latest/userguide/conversation-inference.html)
