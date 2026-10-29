#!/usr/bin/env python3
"""構成図を生成する（pip install diagrams と graphviz が必要）: python3 img/diagram.py"""
import os
from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import Lambda
from diagrams.aws.general import User
from diagrams.aws.ml import Bedrock
from diagrams.aws.storage import S3

FONT = os.environ.get("DIAGRAM_FONT", "WenQuanYi Zen Hei")
ATTR = {"fontname": FONT}
os.chdir(os.path.dirname(os.path.abspath(__file__)))

with Diagram("", show=False, filename="architecture", outformat="png", direction="LR",
             graph_attr={**ATTR, "pad": "0.4", "nodesep": "0.6", "ranksep": "1.2", "splines": "spline"},
             node_attr={**ATTR, "fontsize": "12"}, edge_attr={**ATTR, "fontsize": "11"}):
    ai = Bedrock("Amazon Bedrock\n(Nova がコードを書く)")
    you = User("あなた\n(CloudShell で sandbox.py)")
    with Cluster("AWS Lambda MicroVMs（東京）", graph_attr=ATTR):
        with Cluster("microVM（使い捨ての VM）", graph_attr=ATTR):
            vm = Lambda("Python サンドボックス\n（AI のコードはここで動く）")
        image = Lambda("MicroVM イメージ\n= 起動済みメモリの\nスナップショット")
        s3 = S3("app.zip\n(Dockerfile + server.py)")
    you >> Edge(label=":ai お願い") >> ai
    ai >> Edge(label="Python コード", style="dashed") >> you
    you >> Edge(label="コードを送って実行\n(HTTPS + 認証トークン)") >> vm
    you >> Edge(label="sleep / wake / new\n(suspend / resume / run)", style="dotted") >> image
    s3 >> Edge(label="setup.sh: 起動して凍結") >> image
    image >> Edge(label="数秒で解凍") >> vm
