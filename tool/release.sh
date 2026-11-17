#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
: "${JAVA_HOME:?Set JAVA_HOME to a JDK 21 installation}"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-/usr/lib/android-sdk}"

java_settings=$(java -XshowSettings:properties -version 2>&1)
if [[ "$java_settings" != *"java.specification.version = 21"* ]]; then
    printf '%s\n' 'Release checks require JDK 21.' >&2
    exit 1
fi

fvm flutter pub get --enforce-lockfile
fvm flutter analyze --no-pub
fvm flutter test --no-pub
(
    cd android
    ./gradlew :app:exportReleaseDependencies -Ptarget-platform=android-arm64 --no-daemon --console=plain
)
python3 tool/collect_native_licenses.py --cache .dart_tool/release-sources/modules
python3 tool/collect_android_licenses.py
fvm flutter build apk --release --target-platform android-arm64 --no-pub
(
    cd android
    ./gradlew lintRelease -Ptarget-platform=android-arm64 --no-daemon --console=plain
)
