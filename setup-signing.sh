#!/bin/bash
# À lancer UNE fois : crée un certificat de signature local « Toolbox Dev » dans ton trousseau.
# build.sh signe ensuite Toolbox avec lui : macOS reconnaît l'appli d'une compilation à l'autre
# et ne redemande plus les autorisations (Calendrier, Rappels, capture d'écran, Notes, Bluetooth…).
# Le certificat reste sur ton Mac ; il ne sert qu'à ça.
set -euo pipefail

NAME="${TOOLBOX_SIGN_ID:-Toolbox Dev}"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"${NAME}\""; then
  echo "✓ Le certificat « ${NAME} » existe déjà : ./build.sh l'utilise."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

cat > "${TMP}/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = ${NAME}
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "→ Création du certificat « ${NAME} » (valable 10 ans)…"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "${TMP}/cert.cnf" \
  -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" >/dev/null 2>&1
/usr/bin/openssl pkcs12 -export -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" -name "${NAME}" \
  -passout pass:toolbox -out "${TMP}/id.p12" >/dev/null 2>&1

echo "→ Ajout au trousseau de session…"
security import "${TMP}/id.p12" -k "${HOME}/Library/Keychains/login.keychain-db" -P toolbox -T /usr/bin/codesign >/dev/null

if security find-identity -p codesigning 2>/dev/null | grep -q "\"${NAME}\""; then
  echo "✓ Certificat « ${NAME} » prêt."
  echo
  echo "Maintenant : ./build.sh"
  echo "  • macOS demandera peut-être une fois « codesign veut utiliser la clé » → Toujours autoriser."
  echo "  • Les autorisations seront redemandées UNE dernière fois (nouvelle signature), puis gardées."
else
  echo "✗ Le certificat n'a pas pu être créé automatiquement. À la main (2 minutes) :"
  echo "  Trousseau d'accès → menu Trousseau d'accès → Assistant de certification → Créer un certificat…"
  echo "  Nom : ${NAME} · Type d'identité : Racine auto-signée · Type de certificat : Signature de code → Créer"
  exit 1
fi
