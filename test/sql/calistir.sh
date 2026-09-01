#!/usr/bin/env bash
# kurulum.sql'i GERCEK bir Postgres'te bastan sona calistirir ve sunucu
# tarafi guvenlik testlerini kosar.  Kullanim:  bash test/sql/calistir.sh
#
# Neden: kurulum.sql'in buyuk kismi PL/pgSQL. Sozdizimi ayristiricilari
# fonksiyon govdelerini opak metin sayar, yani gercek hatalari ancak
# Supabase'e yapistirinca gorursunuz. Burada once burada gorursunuz.
#
# Ayrica canlida DENENEMEYECEK seyler burada denenir: brute-force kilidi
# canlida 5 yanlis denemeyle depo personelini 15 dakika disarida birakir.
#
# Gereken: docker.  Kapsayici test sonunda silinir.

set -euo pipefail
export MSYS_NO_PATHCONV=1          # Git Bash /tmp yolunu Windows yoluna cevirmesin

KOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KAP="gurok-pg-test"
DEPO_SIFRE="TestDepoSifre2026!"
ADMIN_SIFRE="TestAdminSifre2026!"

temizle() { docker rm -f "$KAP" >/dev/null 2>&1 || true; }
trap temizle EXIT
temizle

echo "Postgres baslatiliyor..."
docker run -d --name "$KAP" -e POSTGRES_PASSWORD=test -e POSTGRES_DB=gurok postgres:16 >/dev/null

# DIKKAT: pg_isready kullanmayin. postgres imaji kurulum sirasinda once
# YALNIZCA unix soketinde dinleyen gecici bir sunucu acar; pg_isready ona da
# "hazir" der, sonra sunucu yeniden baslar ve bir sonraki komut patlar.
# TCP uzerinden gercek sorgu, kurulum bitene kadar basarisiz olur.
hazir=0
for _ in $(seq 1 90); do
  if docker exec "$KAP" psql -h 127.0.0.1 -U postgres -d gurok -c 'select 1' >/dev/null 2>&1; then
    hazir=1; break
  fi
done
if [ "$hazir" != 1 ]; then
  echo "  ✗ Postgres hazir olmadi"; docker logs --tail 25 "$KAP"; exit 1
fi

calistir() { docker exec "$KAP" psql -h 127.0.0.1 -U postgres -d gurok -v ON_ERROR_STOP=1 -q -f "$1"; }

# Kurulum betigi icin: "already exists, skipping" NOTICE yagmurunu sustur.
# Bunlar idempotentligin normal ciktisi, hata degil.
calistir_sessiz() {
  docker exec -e PGOPTIONS='-c client_min_messages=warning' "$KAP" \
    psql -h 127.0.0.1 -U postgres -d gurok -v ON_ERROR_STOP=1 -q -f "$1"
}

# MSYS_NO_PATHCONV=1 kapsayici icindeki /tmp yolunun bozulmasini engelliyor,
# ama ayni zamanda YEREL yolun cevrilmesini de engelliyor: Git Bash'te yerel
# yol /d/... seklinde ve Docker bunu anlamiyor ("GetFileAttributesEx D:\d").
# Yereli acikca Windows bicimine cevir; Linux/macOS'ta cygpath yok, oldugu gibi kalir.
yerel() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}
kopyala() { docker cp "$(yerel "$1")" "$KAP:$2" >/dev/null; }

GECICI="$(mktemp -d)"
trap 'temizle; rm -rf "$GECICI"' EXIT

kopyala "$KOK/test/sql/onhazirlik.sql" /tmp/onhazirlik.sql
kopyala "$KOK/kurulum.sql"             /tmp/kurulum_yertutucu.sql
kopyala "$KOK/test/sql/guvenlik.sql"   /tmp/guvenlik.sql

# Supabase'in sagladigi ama vanilla Postgres'te olmayan parcalar
calistir_sessiz /tmp/onhazirlik.sql

echo
echo "### 1) Yer tutucu korumasi: duzenlenmemis kurulum.sql DURMALI"
if calistir_sessiz /tmp/kurulum_yertutucu.sql >/dev/null 2>&1; then
  echo "  ✗ BASARISIZ: betik durmadi — yer tutucu sifrelerle kurulum yapildi"
  exit 1
fi
echo "  ✓ betik durdu (beklendigi gibi)"

# Gercek sifrelerle
sed -e "s/BURAYA_DEPO_SIFRE/$DEPO_SIFRE/g" \
    -e "s/BURAYA_ADMIN_SIFRE/$ADMIN_SIFRE/g" \
    "$KOK/kurulum.sql" > "$GECICI/kurulum.sql"
kopyala "$GECICI/kurulum.sql" /tmp/kurulum.sql

echo
echo "### 2) Gercek sifrelerle kurulum"
calistir_sessiz /tmp/kurulum.sql >/dev/null
echo "  ✓ kurulum.sql tamamlandi"

echo
echo "### 3) Idempotentlik: ayni betik ikinci kez"
calistir_sessiz /tmp/kurulum.sql >/dev/null
echo "  ✓ tekrar calisti, hata yok"

echo
echo "### 4) Guvenlik testleri"
calistir /tmp/guvenlik.sql 2>&1 | sed 's/^psql:[^ ]* //; s/^NOTICE:  //'

echo
echo "### 5) Ortak sifre KAPATILDIKTAN sonra kurulum.sql yine calisiyor mu"
# 4. adimin sonunda guvenlik.sql ortak depo sifresini siliyor ve geride depo
# rolunde kullanicilar birakiyor -- yani gercek gecis sonrasi durum. Yer tutucu
# korumasi burada DEVREYE GIRMEMELI, yoksa kullanici bir daha kurulum.sql
# calistiramaz.
if ! calistir_sessiz /tmp/kurulum.sql >/dev/null 2>&1; then
  echo "  ✗ BASARISIZ: gecis sonrasi kurulum.sql duruyor"
  calistir_sessiz /tmp/kurulum.sql 2>&1 | grep -i error | head -3
  exit 1
fi
echo "  ✓ calisti"
# ve ortak sifreyi GERI KURMAMIS olmali
kalan=$(docker exec "$KAP" psql -h 127.0.0.1 -U postgres -d gurok -At \
  -c "select count(*) from ayarlar where anahtar='depo_sifre';")
if [ "$kalan" != "0" ]; then
  echo "  ✗ BASARISIZ: kapatilan ortak sifre geri kuruldu"
  exit 1
fi
echo "  ✓ kapatilan ortak sifre geri kurulmadi"

echo
echo "TAMAM."
