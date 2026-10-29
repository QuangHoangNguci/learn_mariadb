#!/bin/bash
# Tải gói cài về máy controller theo link trong package/<tên>/link-to-download.txt
# Dùng: ./download_packages.sh [mariadb maxscale ...]   (mặc định: mariadb maxscale)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKGS=("$@")
[ ${#PKGS[@]} -eq 0 ] && PKGS=(mariadb maxscale)

OK=()
SKIP=()
FAIL=()
TOTAL=${#PKGS[@]}
IDX=0

for pkg in "${PKGS[@]}"; do
  IDX=$((IDX + 1))
  tag="[$IDX/$TOTAL][$pkg]"
  dir="$ROOT/package/$pkg"
  link_file="$dir/link-to-download.txt"
  if [ ! -f "$link_file" ]; then
    echo "$tag THẤT BẠI: thiếu $link_file" >&2
    FAIL+=("$pkg")
    continue
  fi

  url="$(tr -d '[:space:]' < "$link_file")"
  name="$(basename "$url")"
  file="$dir/$name"

  if [ -s "$file" ]; then
    echo "$tag BỎ QUA: đã có $name ($(du -h "$file" | cut -f1))"
    SKIP+=("$name")
    continue
  fi

  echo "$tag Đang tải $url"
  # -C - cho phép chạy lại để tải tiếp khi đứt giữa chừng
  if curl -fL -C - --retry 3 -o "$file.part" "$url" && mv "$file.part" "$file"; then
    echo "$tag THÀNH CÔNG: $name ($(du -h "$file" | cut -f1)) -> $file"
    OK+=("$name")
  else
    echo "$tag THẤT BẠI: $name (file dở dang giữ ở $file.part, chạy lại để tải tiếp)" >&2
    FAIL+=("$name")
  fi
done

echo
echo "===== Tổng kết ====="
echo "Thành công: ${#OK[@]}   Bỏ qua (đã có): ${#SKIP[@]}   Thất bại: ${#FAIL[@]}"
for f in ${OK[@]+"${OK[@]}"};     do echo "  [OK]   $f"; done
for f in ${SKIP[@]+"${SKIP[@]}"}; do echo "  [SKIP] $f"; done
for f in ${FAIL[@]+"${FAIL[@]}"}; do echo "  [FAIL] $f"; done

[ ${#FAIL[@]} -eq 0 ]
