# 00CaptureDate (macOS 13+, Apple Silicon + Intel)

촬영일자 신뢰도를 먼저 판단하고, 대량의 사진·RAW·영상을 **원본 이름 변경**하거나 **다른 위치로 복사**하는 macOS용 독립 앱입니다. 구 00Favorite / My Tangerine의 이름 변경 규칙을 참고한 독립 구현입니다. 기존 HK13 전체 소스와 byte-for-byte 동등성은 현재 증명되지 않았습니다.

## 순서

1. `파일·폴더 추가`에서 파일 여러 개 또는 상위 폴더 하나를 선택합니다. Finder에서 200GB 전체를 선택하고 액션 휠에 드래그할 필요가 없습니다.
2. `촬영일자 분석`을 클릭하고 각 파일의 날짜·출처·신뢰도를 확인합니다.
3. `원본 이름변경` 또는 `새 위치에 복사`를 선택합니다.
4. 파일명 양식을 편집합니다. 기본값: `{YYYYMMDD}_{hhmmss}_{Originalname}`. `Originalname`은 확장자를 제외한 원본 파일 이름입니다. 원래 확장자는 항상 자동으로 붙습니다.
5. `충돌·규칙 사전 검사`를 클릭합니다. 정확한 일시를 못 읽은 파일과 이름 충돌 파일은 작업 대상에서 제외됩니다.
6. `작업 시작`. 일시정지·중단은 파일 경계에서 이루어집니다. 복사 중 중단되면 임시 파일을 삭제합니다.

### 파일명 토큰

`{YYYYMMDD}` `{hhmmss}` `{YYYY}` `{MM}` `{DD}` `{hh}` `{mm}` `{ss}` `{Originalname}` `{filename}` `{ext}` `{SEQ}`. `{SEQ}`는 입력 파일 전체 순서 기준 4자리 번호입니다. `{ext}`를 중간에 넣으면 원래 확장자가 끝에 추가되고, `{filename}.{ext}`처럼 끝에 넣으면 이중으로 추가하지 않습니다.

### 촬영일자 판정 정책

- JPEG, HIF, HEIC, ARW 등 사진·RAW: `ExifIFD:DateTimeOriginal` 최우선. 원본 EXIF를 편집하지 않음. EXIF가 없으면 제조사 기록·XMP 등은 **확인 필요**.
- MOV, MP4, MTS 등 영상: 명시적으로 `+09:00` 같은 시간대가 있는 `Keys:CreationDate` 등을 우선. 같은 클립의 Sony XML (`C0001.MP4` ↔ `C0001M01.XML` 포함)에 시간대가 명시돼 있으면 사용. 서로 일시가 다르면 **확인 필요**.
- QuickTime `CreateDate`, `MediaCreateDate` 등에서만 읽은 시각은 UTC/로컬 해석이 애매하므로 **확인 필요**. UTC `Z`만 있는 태그는 촬영 장소의 현지시각이 분명하지 않으므로 자동 확정하지 않음.
- Finder의 파일 생성일/수정일은 촬영일시 자동 판정에 사용하지 않음.
- HIF·ARW 지원 목록은 GitHub CI 검사에서 고정 확인.
- `확인 필요`는 행 체크박스를 직접 체크해야 이름을 바꿀 수 있습니다. `수정`으로 수동 일시 입력 가능. 기록에는 자동 판정과 구별됨.
- Sony XML 연동은 파일명이 같은 XML 및 Sony의 `M01`, `M02`, `S01` 접미어가 붙은 XML을 지원합니다. 다른 폴더에 있거나 파일명 매핑이 다른 비표준 XML은 자동으로 연결하지 않습니다.

### 100~200GB 안정성

- 메타데이터는 ExifTool 48개 파일씩 일괄 읽기; 전체 원본 데이터 메모리 적재 금지.
- 목록은 페이지당 400개 표시; 모든 결과는 순서대로 보관.
- 기존 원본 이름변경은 같은 폴더 내 파일명 작업만 수행. `.xmp`/`.xml` 같은 이름의 사이드카를 함께 변경하고 문제 발생 시 롤백을 시도하고, 롤백 실패한 경로는 오류로 명시.
- 복사는 대상 볼륨의 여유 공간이 원본 총량보다 적으면 사전 중단합니다. 같은 폴더에 `.00CaptureDate-*.partial` 임시 파일을 만든 뒤 `SHA-256(원본) == SHA-256(복사본)` 검증 후 최종 파일명으로 이동. 결과 파일이 존재하면 절대 덮어쓰지 않음.
- `작업 기록 보기`로 `~/Library/Application Support/00CaptureDate/logs/run_*.jsonl` 확인 가능. 성공·오류·경로·SHA를 남김.
- 충돌·미확인·이름 중복 항목은 자동 건너뛰므로 같은 패턴에서 대상 파일명이 중복되면 `{Originalname}` 또는 `{SEQ}`를 사용하세요.
- 대용량 복사에서는 원본 SHA 계산과 복사본 SHA 검증 때문에 처리량보다 검증을 우선합니다. APFS 복제 최적화는 볼륨과 FileManager 동작에 따라 달라집니다.
- **현재 앱은 작업 완료 항목을 로그로 남기지만, 앱 재시작 후 로그를 자동으로 읽어 재개하는 기능은 없습니다.** 재실행 전 결과와 충돌 내역을 확인하세요. 예기치 않은 종료로 남은 숨김 `.partial` 파일은 로그와 대조 후 수동 정리해야 합니다.
- 파일 복사 작업 도중 갑작스러운 정전·강제 종료는 시스템이 쓰기를 완료한 데이터까지 보장하지 못합니다. 중요 자료는 다른 매체에 백업 후 사용하세요.

### GitHub에서 빌드

1. GitHub에 새 **Public 또는 Private 저장소**를 만듭니다 (예: `00CaptureDate`).
2. 이 ZIP의 압축을 풀어 내부 파일과 폴더 (`Sources`, `Tests`, `scripts`, `.github`, `.gitignore`, `README.md`)를 저장소 루트에 올립니다. `.github` 폴더는 숨겨져 보일 수 있으니 Finder에서 `Command + Shift + .`로 표시하세요.
3. `Actions` → `Build 00CaptureDate macOS` → `Run workflow`를 실행하거나 `main`에 업로드된 커밋을 기다립니다.
4. 성공한 실행의 `Artifacts`에서 `00CaptureDate-macOS-universal`을 내려받습니다.
5. 압축을 두 번 풀어 `00CaptureDate.app`를 Applications로 옮깁니다.

GitHub Actions는 Apple Silicon(arm64)과 Intel(x86_64)을 합친 **Universal** 앱을 만듭니다. 빌드 도중 ExifTool 13.64 공식 소스 아카이브를 받고 **SHA-256 `dcb9f6be1f6705ee826a92d1522e3fec1d0b3749cdc061b03c46873d5fe204fc`** 검증 후 앱 내부에 포함합니다. 사용자 Mac에는 Homebrew나 ExifTool을 따로 설치하지 않아도 됩니다.

**배포 제한:** Apple Developer ID 공증이 없는 ad-hoc 서명 앱입니다. 처음 실행할 때 macOS에서 차단하면 Finder에서 앱을 Control-클릭 → 열기, 필요한 경우 시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기를 사용하세요. 서명·공증 없이 일반 사용자에게 자동 신뢰되는 앱으로 배포하는 것은 지원하지 않습니다.

### 컴파일 및 테스트 범위

- 플랫폼 종속성이 없는 날짜 파서와 파일명 규칙은 자체 Swift 테스트 실행.
- macOS 앱 및 GUI는 GitHub Actions macOS 러너에서 컴파일/코드 서명/아티팩트로 검증.
- 실제 Sony HIF/ARW/영상 100–200GB 자료를 이용한 장시간 실기 테스트는 별도로 해야 합니다. 실사용 전에 소수의 복제본으로 날짜·결과를 검사하세요. 테스트 코드는 Sony `M01.XML` 연결, 날짜 신뢰도 게이트, SHA-256 기반 복사 절차, 덮어쓰기 방지, 기본 파일명 중복 적용 방지를 점검합니다.

### ExifTool 라이선스

ExifTool by Phil Harvey, Copyright 2003–2026. ExifTool 라이브러리/명령행 프로그램은 Perl과 동일한 라이선스(Artistic License 또는 GPL)에 따라 배포됩니다. 공식 프로젝트: https://exiftool.org/. 소스는 https://github.com/exiftool/exiftool 에서 확인할 수 있습니다.
