# Bundle ID と署名証明書名の唯一の定義。build-app.sh / e2e-check.sh / make-dev-cert.sh が source する
AUTONOTE_BUNDLE_ID="com.yutaokoshi.autonote"
AUTONOTE_CERT_NAME="AutoNote Dev"
# 「AutoNote Dev」証明書の SHA-1（公開してよい値）。手元のビルドとすべてのリリースをこの証明書で署名し、
# designated requirement の `certificate leaf = H"…"` がこれと一致することを release.yml と scripts/signing.sh check が確かめる
AUTONOTE_CERT_SHA1="9d9496ca741b99eaca086c186f2082530ad491c2"
