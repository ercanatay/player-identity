#!/usr/bin/env bash
# Kaynak spec'i (özel, kişisel veri içerebilir) docs/spec.md'ye sanitize ederek kopyalar.
#
# Kullanım:
#   scripts/sync-spec.sh           kaynağı docs/spec.md'ye kopyala + sanitize et
#   scripts/sync-spec.sh --check   docs/spec.md içinde hassas desen var mı kontrol et (kopyalamaz)
#
# Çıkış kodları: 0 başarılı / temiz, 1 --check'te hassas desen bulundu, 2 kullanım/kaynak hatası.

set -euo pipefail

SOURCE="${SPEC_SOURCE:-$HOME/Documents/specs/player-identity/spec.md}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/docs/spec.md"

# Hassas desenler (--check bu listeyi arar). Nokta regex'te kaçışlı.
SENSITIVE_RE='159\.146|192\.168|Fener''Bahce|Donald''-''Trump'

if [[ "${1:-}" == "--check" ]]; then
  if [[ ! -f "$TARGET" ]]; then
    echo "HATA: $TARGET bulunamadı." >&2
    exit 2
  fi
  matches="$(grep -nE "$SENSITIVE_RE" "$TARGET" || true)"
  if [[ -n "$matches" ]]; then
    echo "HATA: docs/spec.md içinde hassas desen bulundu:" >&2
    echo "$matches" >&2
    echo "Çözüm: scripts/sync-spec.sh çalıştırıp sanitize edilmiş kopyayı üret." >&2
    exit 1
  fi
  echo "OK: docs/spec.md hassas desen içermiyor."
  exit 0
fi

if [[ $# -gt 0 ]]; then
  echo "Kullanım: $0 [--check]" >&2
  exit 2
fi

if [[ ! -f "$SOURCE" ]]; then
  echo "HATA: kaynak spec bulunamadı: $SOURCE" >&2
  exit 2
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

{
  printf '<!-- Source: specs/player-identity/spec.md; run scripts/sync-spec.sh -->\n'
  # Sıra önemli: özel IP'ler önce, genel 159.146. kuralı en sonda.
  # \b sınırları 192.0.2.1 kuralının 192.0.2.10 gibi adreslere uymasını engeller.
  NAME1='Fener''Bahce\(Original\)'
  NAME2='Donald''-''Trump'
  perl -pe '
    s/192\.168\.2\.156\b/192.0.2.10/g;
    s/192\.168\.1\.101\b/192.0.2.11/g;
    s/192\.168\.2\.1\b/192.0.2.1/g;
    s/159\.146\.69\.0\/24/198.51.100.0\/24/g;
    s/159\.146\.0\.0\/16/198.51.0.0\/16/g;
    s/159\.146\./198.51.100./g;
  ' "$SOURCE" | sed -e "s/${NAME1}/TestPlayer/g" -e "s/${NAME2}/TestPlayer/g" -e 's/Ercan ATAY/Test/g' -e 's/Ercan/Test/g'
} > "$tmp"

mv "$tmp" "$TARGET"
trap - EXIT
echo "Kopyalandı ve sanitize edildi: $SOURCE -> $TARGET"

# Kopya temiz mi? Temizse ek kontrol olarak --check'i çalıştır.
"$0" --check
