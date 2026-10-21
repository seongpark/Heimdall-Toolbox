# Heimdall Toolbox (macOS)

Samsung Firmware Flashing Tool for macOS — Heimdall(Odin) + ADB 올인원 앱

맥에서 쓰는 삼성 Odin 대체 올인원 앱입니다. Heimdall, adb, fastboot, lz4와 필요한 라이브러리가 전부 `.app` 안에 들어가므로 빌드 후에는 앱만 실행하면 됩니다 (Homebrew 등 별도 설치 불필요).

## 기능

| 탭 | 내용 |
|---|---|
| 기기 | ADB / Fastboot / Download 모드 기기 감지, 재부팅(시스템·리커버리·Download·부트로더·사이드로드), ADB 셸 명령 |
| APK 설치 | 드래그 앤 드롭, 여러 개 일괄 설치, 분할 APK(install-multiple), `-r -d -g -t` 옵션 (디버그/테스트 APK 설치 포함) |
| ADB 사이드로드 | 리커버리 "Apply update from ADB" 상태에서 ZIP 바로 전송 |
| 파일 전송 | `adb push`로 `/sdcard/Download` 등 원하는 폴더에 바로 복사 |
| Odin 플래시 (Heimdall) | BL/AP/CP/CSC `.tar.md5`를 Odin처럼 넣으면 압축 해제 → `.lz4` 해제 → PIT로 파티션 자동 매핑 → 플래시. 수동 이미지 추가, `--no-reboot`/`--resume`/`--repartition` 지원 |

진행률은 하단 상태줄에, 전체 로그는 로그 창에 표시되며 작업 중지 버튼이 있습니다.

## 다운로드

[Releases](../../releases)에서 맥에 맞는 zip을 받으세요 (`arm64` = Apple Silicon, `x86_64` = Intel). 압축을 풀고 앱을 우클릭 → 열기로 처음 실행합니다.

새 버전 배포: `build.sh`의 `VERSION`을 올려 `main`에 푸시하면 GitHub Actions가 두 아키텍처용 앱을 빌드해 `v<VERSION>` Release에 올립니다.

## 직접 빌드

필요한 것: macOS 13 이상, Xcode Command Line Tools, Homebrew (빌드할 때만 필요)

```bash
cd HeimdallToolbox
chmod +x build.sh
./build.sh
```

또는 Finder에서 `빌드하기.command`를 더블클릭하세요.

스크립트가 자동으로 하는 일:
1. cmake, pkg-config, libusb 설치 (Homebrew)
2. Google 공식 platform-tools(맥용 adb/fastboot) 다운로드
3. Heimdall 소스(Henrik Grimler 유지보수 포크, 최신 기기 프로토콜 대응)를 libusb 정적 링크로 빌드, lz4도 소스에서 정적 빌드
4. SwiftUI 앱 컴파일
5. 바이너리와 dylib을 `.app` 안에 넣고 경로 재작성 → 애드혹 서명 → 외부 의존성 없음을 검증
6. `dist/Heimdall Toolbox.app` 및 배포용 zip 생성

결과물을 `/Applications`로 옮겨 쓰면 됩니다. 빌드한 맥의 아키텍처(Apple Silicon 또는 Intel)용으로 만들어집니다.

## 사용 팁

- **USB 디버깅**: 휴대폰 설정 → 개발자 옵션 → USB 디버깅 켜기. 처음 연결 시 휴대폰의 허용 창을 눌러야 합니다.
- **Download 모드**: '기기' 탭의 Download 모드 재부팅, 또는 전원 끈 상태에서 볼륨 상+하를 누른 채 케이블 연결(기종별 상이).
- **Odin 플래시 순서**: 펌웨어 슬롯에 파일 넣기 → ① 압축 풀기 + 매핑 → 목록 확인 → ② 플래시 시작.
  - 대부분의 펌웨어는 CSC 안에 `.pit`이 있어 자동으로 매핑됩니다. 없으면 기기(Download 모드)에서 PIT를 읽습니다.
  - `HOME_CSC`는 데이터 유지, `CSC`는 초기화입니다 (Odin과 동일).
  - 펌웨어 압축 해제에는 원본 크기만큼 여유 공간이 필요합니다. 끝나면 "임시 파일 정리"를 누르세요.
- **다른 맥으로 복사한 경우**: 처음 한 번은 앱을 우클릭 → 열기. 그래도 막히면 `xattr -cr "/Applications/Heimdall Toolbox.app"`.

## 문제 해결

- `heimdall detect`가 실패하면: 케이블/포트를 바꾸고 USB 허브를 피하세요. Smart Switch 등 삼성 USB 드라이버가 기기를 잡고 있으면 해당 앱을 종료하세요.
- 플래시 중 `ERROR: Failed to ...` 후 재시도할 때는 기기를 다시 Download 모드로 진입시키세요. 직전에 `--no-reboot`로 세션을 남겼다면 "이전 세션 이어서" 옵션을 켭니다.
- 리파티션은 PIT가 기기와 정확히 맞을 때만 사용하세요.

## 구성

```
Heimdall Toolbox.app/Contents
├── MacOS/HeimdallToolbox            SwiftUI 앱
└── Resources
    ├── bin/  adb, fastboot, heimdall, lz4 (+ platform-tools 전체)
    ├── lib/  libusb, liblz4 등 (번들 내부 경로로 연결)
    └── AppIcon.icns
```

Heimdall은 MIT 라이선스, Android platform-tools는 Google 이용약관을 따릅니다.
