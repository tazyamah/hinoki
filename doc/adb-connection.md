# ADB 接続設定

## database.yml の生成

`hinoki db:init` コマンドで対話形式に生成できます:

```bash
$ hinoki db:init
🌲 database.yml の設定を行います。

  接続サービス名 (DSN / OCID 末尾の接続名, 例: myadb_high): myadb_high
  DBユーザー名 [ADMIN]: ADMIN
  DBパスワード: ********
  DBパスワード (確認): ********
  ウォレットフォルダのパス (例: /path/to/Wallet_xxx): /home/user/Wallet_myadb

✓ config/database.yml を生成しました。
✓ .gitignore に config/database.yml を追加しました。
```

引数で一括指定する場合 (CI/CD 環境など):

```bash
hinoki db:init \
  --dsn myadb_high \
  --username ADMIN \
  --password "YourPassword!" \
  --wallet /home/user/Wallet_myadb
```

既存ファイルを上書きする場合は `--force` を追加してください。

生成される `config/database.yml` の形式:

```yaml
environment: development

development:
  username: ADMIN
  password: YourSecurePassword123!
  dsn: myatp_high                        # tnsnames.ora のサービス名
  wallet_location: /path/to/Wallet_myatp # Wallet展開先ディレクトリ

production:
  username: APP_USER
  password: YourSecurePassword123!
  dsn: myatp_high
  wallet_location: /path/to/Wallet_myatp
```

> **セキュリティ**: `database.yml` にはパスワードが含まれます。`hinoki db:init` は自動的に `.gitignore` へ追加しますが、誤ってコミットしないよう注意してください。

## Wallet のダウンロード

### 方法1: CLI で自動ダウンロード（推奨）

OCI SDK をインストール済みであれば、コマンド一発でダウンロード〜展開〜設定反映まで完了します:

```bash
pip install "hinoki[oci]"   # または pip install oci
hinoki db:download-wallet --update-config
```

初回は ADB の OCID・ウォレットパスワード・保存先を対話形式で入力します。  
`--update-config` を指定すると `config/database.yml` の `wallet_location` も自動更新されます。

引数で一括指定する場合:

```bash
hinoki db:download-wallet \
  --ocid ocid1.autonomousdatabase.oc1.ap-tokyo-1.xxx \
  --wallet-password "WalletPass!" \
  --dest ./wallet \
  --update-config
```

> **前提**: `~/.oci/config` に OCI の認証情報が設定されていること。  
> 設定方法: https://docs.oracle.com/en-us/iaas/Content/API/Concepts/sdkconfig.htm

### 方法2: OCI コンソールから手動ダウンロード

1. OCI Console → Autonomous Database → 対象DB → 「データベース接続」
2. 「ウォレットのダウンロード」→ パスワード設定 → ZIP ダウンロード
3. 任意のディレクトリに展開
4. `wallet_location` にそのディレクトリパスを設定

## mTLS なしの接続 (TLS)

ADB で mTLS 不要設定にしている場合、Wallet は不要です:

```yaml
development:
  username: ADMIN
  password: YourSecurePassword123!
  dsn: "(description=(address=(protocol=tcps)(host=xxx.adb.ap-tokyo-1.oraclecloud.com)(port=1522))(connect_data=(service_name=xxx_myatp_high.adb.oraclecloud.com)))"
```

## プロジェクト構成

`hinoki new myapp` で以下の構成が生成されます:

```
myapp/
├── hinoki.yml                # プロジェクト設定
├── config/
│   ├── database.yml          # DB接続情報 (.gitignore推奨)
│   └── routes.hk             # ルーティング定義
├── app/
│   ├── controllers/          # コントローラ (.hk または .sql)
│   ├── models/               # モデル (.hk または .sql)
│   └── views/
│       ├── layouts/
│       │   └── application.html
│       ├── posts/
│       │   ├── index.html
│       │   ├── show.html
│       │   ├── new.html
│       │   └── edit.html
│       └── shared/
├── db/
│   └── migrate/              # マイグレーション (.hk または .sql)
├── public/
│   ├── css/
│   └── js/
└── test/
```
