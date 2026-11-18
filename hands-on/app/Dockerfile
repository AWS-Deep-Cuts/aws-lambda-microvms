# AWS Deep Cuts - Lambda MicroVMs ハンズオン用のアプリ
# MicroVM の OS（Amazon Linux 2023）は、create-microvm-image の --base-image-arn で指定するベースイメージが用意する。
# この Dockerfile は、その OS の上でアプリを動かすコンテナの作り方を定義する。
FROM public.ecr.aws/lambda/microvms:al2023-minimal

# server.py は Python の標準ライブラリだけで動くため、python3 だけをインストールする
RUN dnf install -y python3 && dnf clean all

COPY server.py /app/server.py

# 8080: アプリの API、9000: ライフサイクルフックを受け取るポート（create-microvm-image の --hooks の port と合わせる）
EXPOSE 8080 9000
CMD ["python3", "/app/server.py"]
