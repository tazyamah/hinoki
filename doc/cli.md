# CLI コマンド一覧

## コマンドリファレンス

```bash
# プロジェクト管理
hinoki new <app_name>           # 新規プロジェクト作成
hinoki install                   # ADBにフレームワークをインストール
hinoki deploy                    # 全ファイルをADBにデプロイ

# 接続設定
hinoki db:init                   # config/database.yml を対話形式で生成
hinoki db:init \                 # 引数で直接指定する場合
  --dsn myadb_high \
  --username ADMIN \
  --password <pw> \
  --wallet /path/to/Wallet
hinoki db:init --force           # 既存の database.yml を上書き

hinoki db:download-wallet        # OCI SDK でウォレットをダウンロード・展開 (要: pip install oci)
hinoki db:download-wallet \      # 引数で直接指定する場合
  --ocid ocid1.autonomousdatabase.oc1.xxx \
  --wallet-password <pw> \
  --dest ./wallet \
  --update-config                # database.yml の wallet_location も自動更新

# コード生成
hinoki generate scaffold <name> <columns...>        # CRUD一式 (.hk)
hinoki generate scaffold <name> <columns...> --sql  # CRUD一式 (.sql)
hinoki generate migration <name>                    # 空のマイグレーション

# データベース
hinoki migrate                   # 未実行マイグレーションを実行
hinoki migrate:rollback          # 直前のマイグレーションをロールバック

# 情報表示
hinoki routes                    # 登録済みルート一覧

# トランスパイラ
hinoki compile <file.hk>              # .hk → PL/SQL を標準出力
hinoki compile <file.hk> -o out.sql   # .hk → PL/SQL をファイル出力

# デバッグ
hinoki console                   # PL/SQL 対話コンソール
```

## scaffold のカラム型

`hinoki generate scaffold` で使える型:

```bash
hinoki generate scaffold product \
  name:string \          # VARCHAR2(200)
  description:text \     # CLOB
  price:number \         # NUMBER
  quantity:integer \     # NUMBER(10)
  active:boolean \       # NUMBER(1) DEFAULT 0
  released_on:date \     # DATE
  updated_at:timestamp   # TIMESTAMP
```

## トランスパイラの Python API

`hinoki.transpiler` モジュールを Python から直接使うこともできます。

```python
from hinoki.transpiler import transpile, transpile_file
from pathlib import Path

# 文字列から変換
source = '''
model Post
  table :posts
  permit :title, :body
  validates :title, presence: true
end
'''
plsql = transpile(source, "post.model.hk")
print(plsql)

# ファイルから変換
plsql = transpile_file(Path("app/models/article.model.hk"))
```
