#!/bin/bash
# Tải gói cài về máy controller theo link trong package/<tên>/link-to-download.txt
# Dùng: ./download_packages.sh [mariadb maxscale ...]   (mặc định: mariadb maxscale)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKGS=("$@")
[ ${#PKGS[@]} -eq 0 ] && PKGS=(mariadb maxscale)

for pkg in "${PKGS[@]}"; do
  dir="$ROOT/package/$pkg"
  link_file="$dir/link-to-download.txt"
  [ -f "$link_file" ] || { echo "[$pkg] thiếu $link_file" >&2; exit 1; }

  url="$(tr -d '[:space:]' < "$link_file")"
  file="$dir/$(basename "$url")"

  if [ -s "$file" ]; then
    echo "[$pkg] đã có $(basename "$file"), bỏ qua"
    continue
  fi

  echo "[$pkg] tải $url"
  # -C - cho phép chạy lại để tải tiếp khi đứt giữa chừng
  curl -fL -C - --retry 3 -o "$file.part" "$url"
  mv "$file.part" "$file"
done

echo "Xong:"
ls -lh "$ROOT"/package/mariadb "$ROOT"/package/maxscale
