#!/bin/bash
cd "$(dirname "$0")"
chmod +x build.sh
./build.sh
echo
read -n 1 -s -r -p "아무 키나 누르면 창이 닫힙니다…"
