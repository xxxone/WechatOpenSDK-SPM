#!/usr/bin/env bash
set -euo pipefail

# 将腾讯官方 WechatOpenSDK (Pay 版) 静态 xcframework 重新打包为真正的 Dynamic xcframework
# 解决 Xcode/SPM 在 App 构建阶段现场转动态库导致的 LC_BUILD_VERSION 与 Info.plist 不一致问题 (ITMS-90208)

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_XCFRAMEWORK="${SOURCE_XCFRAMEWORK:-${PACKAGE_DIR}/WechatOpenSDK.xcframework}"
OUTPUT_XCFRAMEWORK="${OUTPUT_XCFRAMEWORK:-${PACKAGE_DIR}/WechatOpenSDK-Dynamic.xcframework}"
BUILD_DIR="${BUILD_DIR:-${PACKAGE_DIR}/.build/dynamic-xcframework}"
MIN_IOS_VERSION="${MIN_IOS_VERSION:-15.0}"
FRAMEWORK_NAME="WechatOpenSDK"
FRAMEWORK="${FRAMEWORK_NAME}.framework"
BINARY="${FRAMEWORK_NAME}"

DEVICE_SOURCE="${SOURCE_XCFRAMEWORK}/ios-arm64/${FRAMEWORK}"
SIMULATOR_SOURCE="${SOURCE_XCFRAMEWORK}/ios-arm64_x86_64-simulator/${FRAMEWORK}"

if [[ ! -f "${DEVICE_SOURCE}/${BINARY}" ]]; then
    echo "错误: 找不到真机静态库: ${DEVICE_SOURCE}/${BINARY}" >&2
    exit 1
fi

if [[ ! -f "${SIMULATOR_SOURCE}/${BINARY}" ]]; then
    echo "错误: 找不到模拟器静态库: ${SIMULATOR_SOURCE}/${BINARY}" >&2
    exit 1
fi

IPHONEOS_SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
IPHONEOS_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
SIMULATOR_SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SIMULATOR_SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"

LINKED_SYSTEM_LIBRARIES=(
  -framework Foundation
  -framework UIKit
  -framework CoreGraphics
  -framework Security
  -framework WebKit
  -lc++
)

set_plist_string() {
    local plist="$1"
    local key="$2"
    local value="$3"
    if /usr/libexec/PlistBuddy -c "Print :${key}" "${plist}" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${plist}"
    else
        /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "${plist}"
    fi
}

prepare_framework() {
    local source_framework="$1"
    local output_framework="$2"
    local platform="$3"

    rm -rf "${output_framework}"
    mkdir -p "${output_framework}"

    cp -R "${source_framework}/." "${output_framework}/"

    local plist="${output_framework}/Info.plist"
    if [[ -f "${plist}" ]]; then
        /usr/libexec/PlistBuddy -c "Delete :CFBundleSupportedPlatforms" "${plist}" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" "${plist}"
        if [[ "${platform}" == "iPhoneOS" ]]; then
            /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms:0 string iPhoneOS" "${plist}"
        else
            /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms:0 string iPhoneSimulator" "${plist}"
        fi
        set_plist_string "${plist}" "CFBundlePackageType" "FMWK"
        set_plist_string "${plist}" "MinimumOSVersion" "${MIN_IOS_VERSION}"
    fi

    if [[ -f "${source_framework}/PrivacyInfo.xcprivacy" ]]; then
        cp "${source_framework}/PrivacyInfo.xcprivacy" "${output_framework}/PrivacyInfo.xcprivacy"
    fi
}

patch_build_version() {
    local binary="$1"
    local platform="$2"
    local minos="$3"
    local sdk="$4"

    xcrun vtool \
        -set-build-version "${platform}" "${minos}" "${sdk}" \
        -replace \
        -output "${binary}" \
        "${binary}"
}

link_device_framework() {
    local output_framework="$1"
    echo "==> 链接真机动态库..."
    xcrun clang \
        -dynamiclib \
        -arch arm64 \
        -isysroot "${IPHONEOS_SDK_PATH}" \
        -miphoneos-version-min="${MIN_IOS_VERSION}" \
        -install_name "@rpath/${FRAMEWORK}/${BINARY}" \
        -Wl,-force_load,"${DEVICE_SOURCE}/${BINARY}" \
        "${LINKED_SYSTEM_LIBRARIES[@]}" \
        -o "${output_framework}/${BINARY}"
    patch_build_version "${output_framework}/${BINARY}" ios "${MIN_IOS_VERSION}" "${IPHONEOS_SDK_VERSION}"
}

link_simulator_framework() {
    local output_framework="$1"
    echo "==> 链接模拟器动态库..."
    xcrun clang \
        -dynamiclib \
        -arch arm64 \
        -arch x86_64 \
        -isysroot "${SIMULATOR_SDK_PATH}" \
        -mios-simulator-version-min="${MIN_IOS_VERSION}" \
        -install_name "@rpath/${FRAMEWORK}/${BINARY}" \
        -Wl,-force_load,"${SIMULATOR_SOURCE}/${BINARY}" \
        "${LINKED_SYSTEM_LIBRARIES[@]}" \
        -o "${output_framework}/${BINARY}"
    patch_build_version "${output_framework}/${BINARY}" iossim "${MIN_IOS_VERSION}" "${SIMULATOR_SDK_VERSION}"
}

echo "源静态库: ${SOURCE_XCFRAMEWORK}"
echo "输出动态库: ${OUTPUT_XCFRAMEWORK}"
echo "最低 iOS 版本: ${MIN_IOS_VERSION}"

rm -rf "${BUILD_DIR}" "${OUTPUT_XCFRAMEWORK}"
mkdir -p "${BUILD_DIR}/ios-arm64" "${BUILD_DIR}/ios-arm64_x86_64-simulator"

DEVICE_OUTPUT="${BUILD_DIR}/ios-arm64/${FRAMEWORK}"
SIMULATOR_OUTPUT="${BUILD_DIR}/ios-arm64_x86_64-simulator/${FRAMEWORK}"

prepare_framework "${DEVICE_SOURCE}" "${DEVICE_OUTPUT}" "iPhoneOS"
prepare_framework "${SIMULATOR_SOURCE}" "${SIMULATOR_OUTPUT}" "iPhoneSimulator"

link_device_framework "${DEVICE_OUTPUT}"
link_simulator_framework "${SIMULATOR_OUTPUT}"

echo "==> 创建 xcframework..."
xcodebuild -create-xcframework \
    -framework "${DEVICE_OUTPUT}" \
    -framework "${SIMULATOR_OUTPUT}" \
    -output "${OUTPUT_XCFRAMEWORK}"

if [[ -f "${SOURCE_XCFRAMEWORK}/PrivacyInfo.xcprivacy" ]]; then
    cp "${SOURCE_XCFRAMEWORK}/PrivacyInfo.xcprivacy" "${OUTPUT_XCFRAMEWORK}/PrivacyInfo.xcprivacy"
fi

echo "==> 完成: ${OUTPUT_XCFRAMEWORK}"
