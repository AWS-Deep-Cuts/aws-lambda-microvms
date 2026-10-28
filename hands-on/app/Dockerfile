# AWS Deep Cuts - Lambda MicroVMs ハンズオン用イメージ
# microVM の OS（Amazon Linux 2023 + サービスコンポーネント）は --base-image-arn で指定する
# Lambda 管理のベースイメージが提供する。この Dockerfile の FROM は、その上で動く「コンテナ」のベース。
FROM public.ecr.aws/lambda/microvms:al2023-minimal

# 標準ライブラリだけで動く Python サーバーなので、python3 さえあればよい
RUN dnf install -y python3 && dnf clean all

COPY server.py /app/server.py

# 8080: アプリ API / 9000: ライフサイクルフックのリスナー（create-microvm-image の --hooks port と合わせる）
EXPOSE 8080 9000
CMD ["python3", "/app/server.py"]
