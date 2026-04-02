#!/bin/sh

set -eu

log() {
  printf '\n[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

WORKSPACE="${WORKSPACE:-/workspace}"
SDK_ROOT="${SDK_ROOT:-/builder}"
PACKAGE_SOURCE_URL="${PACKAGE_SOURCE_URL:?PACKAGE_SOURCE_URL is required}"
PACKAGE_SOURCE_REF="${PACKAGE_SOURCE_REF:-Lede}"
OPENWRT_VERSION="${OPENWRT_VERSION:?OPENWRT_VERSION is required}"
OPENWRT_ARCH="${OPENWRT_ARCH:?OPENWRT_ARCH is required}"
SDK_IMAGE="${SDK_IMAGE:-unknown}"
TARGET_DEVICE_NAME="${TARGET_DEVICE_NAME:-}"
TARGET_BOARD_NAME="${TARGET_BOARD_NAME:-}"
TARGET_FIRMWARE_RELEASE="${TARGET_FIRMWARE_RELEASE:-}"
TARGET_FIRMWARE_REVISION="${TARGET_FIRMWARE_REVISION:-}"
TARGET_FIRMWARE_TARGET="${TARGET_FIRMWARE_TARGET:-}"
TARGET_FIRMWARE_ARCH="${TARGET_FIRMWARE_ARCH:-}"
TARGET_FIRMWARE_KERNEL="${TARGET_FIRMWARE_KERNEL:-}"
TARGET_FIREWALL_BACKEND="${TARGET_FIREWALL_BACKEND:-}"
TAB="$(printf '\t')"

STATE_DIR="${WORKSPACE}/.work"
DIST_DIR="${WORKSPACE}/dist"
PACKAGE_LIST_FILE="${WORKSPACE}/config/packages.txt"
PACKAGE_FILE="${STATE_DIR}/package-specs.tsv"
PACKAGE_RAW_FILE="${STATE_DIR}/package-specs.raw"
SOURCE_MAP_FILE="${STATE_DIR}/source-map.tsv"
SOURCE_ROOT="${STATE_DIR}/sources"

mkdir -p "${STATE_DIR}" "${DIST_DIR}" "${SOURCE_ROOT}"
rm -f "${PACKAGE_FILE}" "${PACKAGE_RAW_FILE}" "${SOURCE_MAP_FILE}"

validate_package_dir() {
  pkg_dir="$1"

  case "${pkg_dir}" in
    /*)
      fail "包路径不能是绝对路径：${pkg_dir}"
      ;;
    *..*)
      fail "包路径不能包含 .. ：${pkg_dir}"
      ;;
    *)
      :
      ;;
  esac

  printf '%s' "${pkg_dir}" | grep -Eq '^[A-Za-z0-9._/-]+$' ||
    fail "包路径包含非法字符：${pkg_dir}"
}

validate_source_url() {
  source_url="$1"
  printf '%s' "${source_url}" | grep -Eq '^[A-Za-z0-9:/._@+-]+$' ||
    fail "源码地址包含非法字符：${source_url}"
}

validate_source_ref() {
  source_ref="$1"
  printf '%s' "${source_ref}" | grep -Eq '^[A-Za-z0-9._/-]+$' ||
    fail "源码 Ref 包含非法字符：${source_ref}"
}

is_sdk_feed_source() {
  case "$1" in
    sdk://*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

sdk_feed_name() {
  source_url="$1"
  feed_name="${source_url#sdk://}"
  [ -n "${feed_name}" ] || fail "sdk:// 源缺少 feed 名称：${source_url}"
  printf '%s' "${feed_name}"
}

resolve_source_commit() {
  repo_dir="$1"

  if git -C "${repo_dir}" rev-parse HEAD >/dev/null 2>&1; then
    git -C "${repo_dir}" rev-parse HEAD
  else
    printf 'unknown'
  fi
}

collect_raw_specs() {
  input_source="$1"
  : > "${PACKAGE_RAW_FILE}"

  if [ "${input_source}" = "env" ]; then
    printf '%s\n' "${PACKAGE_DIRS:-}" | sed 's/\r$//' > "${PACKAGE_RAW_FILE}.input"
  else
    [ -f "${PACKAGE_LIST_FILE}" ] || fail "找不到包清单文件：${PACKAGE_LIST_FILE}"
    sed 's/\r$//' "${PACKAGE_LIST_FILE}" > "${PACKAGE_RAW_FILE}.input"
  fi

  while IFS= read -r raw_line || [ -n "${raw_line}" ]; do
    line="$(trim "${raw_line}")"
    [ -n "${line}" ] || continue

    case "${line}" in
      \#*)
        continue
        ;;
      *'|'*)
        printf '%s\n' "${line}" >> "${PACKAGE_RAW_FILE}"
        ;;
      *)
        printf '%s\n' "${line}" | tr ', \t' '\n\n\n' >> "${PACKAGE_RAW_FILE}"
        ;;
    esac
  done < "${PACKAGE_RAW_FILE}.input"

  rm -f "${PACKAGE_RAW_FILE}.input"
}

normalize_package_list() {
  input_source="$1"
  : > "${PACKAGE_FILE}.tmp"

  collect_raw_specs "${input_source}"

  while IFS= read -r raw_spec || [ -n "${raw_spec}" ]; do
    spec_line="$(trim "${raw_spec}")"
    [ -n "${spec_line}" ] || continue

    package_dir="${spec_line}"
    source_url="${PACKAGE_SOURCE_URL}"
    source_ref="${PACKAGE_SOURCE_REF}"

    case "${spec_line}" in
      *'|'*)
        IFS='|' read -r field1 field2 field3 field4 <<EOF
${spec_line}
EOF
        [ -z "${field4:-}" ] || fail "包清单格式错误（仅支持 package_dir|source_url|source_ref）：${spec_line}"
        package_dir="$(trim "${field1}")"
        [ -n "${field2:-}" ] && source_url="$(trim "${field2}")"
        [ -n "${field3:-}" ] && source_ref="$(trim "${field3}")"
        ;;
    esac

    validate_package_dir "${package_dir}"
    validate_source_url "${source_url}"
    validate_source_ref "${source_ref}"

    printf '%s\t%s\t%s\n' "${package_dir}" "${source_url}" "${source_ref}" >> "${PACKAGE_FILE}.tmp"
  done < "${PACKAGE_RAW_FILE}"

  awk '!seen[$0]++ { print }' "${PACKAGE_FILE}.tmp" > "${PACKAGE_FILE}"
  rm -f "${PACKAGE_FILE}.tmp"

  [ -s "${PACKAGE_FILE}" ] ||
    fail "未解析到任何待编译包，请维护 config/packages.txt 或在 workflow_dispatch 输入 packages"
}

prepare_sdk() {
  [ -d "${SDK_ROOT}" ] || fail "找不到 SDK 根目录：${SDK_ROOT}"
  cd "${SDK_ROOT}"

  if [ ! -d "./scripts" ]; then
    [ -x "./setup.sh" ] || fail "SDK 缺少 scripts 与 setup.sh，无法初始化"
    log "SDK 尚未初始化，执行 ./setup.sh"
    ./setup.sh
  fi
}

clone_source_repo() {
  source_url="$1"
  source_ref="$2"
  repo_dir="$3"

  rm -rf "${repo_dir}"
  mkdir -p "$(dirname "${repo_dir}")"

  log "克隆源码：${source_url} @ ${source_ref}"
  if ! git clone --filter=blob:none --depth 1 --branch "${source_ref}" "${source_url}" "${repo_dir}"; then
    git clone --filter=blob:none "${source_url}" "${repo_dir}"
    (
      cd "${repo_dir}"
      git fetch --depth 1 origin "${source_ref}"
      git checkout FETCH_HEAD
    )
  fi
}

lookup_source_mapping() {
  source_url="$1"
  source_ref="$2"

  awk -F '\t' -v source_url="${source_url}" -v source_ref="${source_ref}" '
    $1 == source_url && $2 == source_ref {
      print $0
      exit
    }
  ' "${SOURCE_MAP_FILE}"
}

prepare_sources() {
  : > "${SOURCE_MAP_FILE}"
  source_index=0

  while IFS="${TAB}" read -r package_dir source_url source_ref; do
    mapping="$(lookup_source_mapping "${source_url}" "${source_ref}")"
    if [ -n "${mapping}" ]; then
      continue
    fi

    if is_sdk_feed_source "${source_url}"; then
      feed_name="$(sdk_feed_name "${source_url}")"
      repo_dir="${SDK_ROOT}/feeds/${feed_name}"
      log "使用 SDK 官方 feed：${feed_name}"
      printf '%s\t%s\t%s\t%s\t%s\n' "${source_url}" "${source_ref}" "${feed_name}" "${repo_dir}" "sdkfeed" >> "${SOURCE_MAP_FILE}"
      continue
    fi

    source_index=$((source_index + 1))
    feed_name="custom${source_index}"
    repo_dir="${SOURCE_ROOT}/${feed_name}"

    clone_source_repo "${source_url}" "${source_ref}" "${repo_dir}"
    printf '%s\t%s\t%s\t%s\t%s\n' "${source_url}" "${source_ref}" "${feed_name}" "${repo_dir}" "git" >> "${SOURCE_MAP_FILE}"
  done < "${PACKAGE_FILE}"
}

prepare_local_tools() {
  BIN_DIR="${STATE_DIR}/bin"
  mkdir -p "${BIN_DIR}"

  export PATH="${BIN_DIR}:${SDK_ROOT}/staging_dir/host/bin:${SDK_ROOT}/staging_dir/hostpkg/bin:${PATH}"

  while IFS="${TAB}" read -r package_dir source_url source_ref; do
    mapping="$(lookup_source_mapping "${source_url}" "${source_ref}")"
    [ -n "${mapping}" ] || fail "未找到源码映射：${source_url} @ ${source_ref}"

    IFS="${TAB}" read -r _map_url _map_ref feed_name repo_dir source_kind <<EOF
${mapping}
EOF

    po2lmo_dir="${repo_dir}/${package_dir}/tools/po2lmo"
    if [ -f "${po2lmo_dir}/Makefile" ]; then
      log "构建本地 po2lmo 工具：${package_dir}"
      make -C "${po2lmo_dir}"
      install -m 0755 "${po2lmo_dir}/src/po2lmo" "${BIN_DIR}/po2lmo"
    fi
  done < "${PACKAGE_FILE}"
}

configure_feeds() {
  cd "${SDK_ROOT}"

  cp feeds.conf.default feeds.conf
  while IFS="${TAB}" read -r source_url source_ref feed_name repo_dir source_kind; do
    [ "${source_kind}" = "git" ] || continue
    printf '\nsrc-link %s %s\n' "${feed_name}" "${repo_dir}" >> feeds.conf
  done < "${SOURCE_MAP_FILE}"

  log "更新官方 feeds"
  ./scripts/feeds update -a

  log "安装官方 feeds"
  ./scripts/feeds install -a

  log "安装选定的自定义包"
  while IFS="${TAB}" read -r package_dir source_url source_ref; do
    mapping="$(lookup_source_mapping "${source_url}" "${source_ref}")"
    [ -n "${mapping}" ] || fail "未找到源码映射：${source_url} @ ${source_ref}"

    IFS="${TAB}" read -r _map_url _map_ref feed_name repo_dir source_kind <<EOF
${mapping}
EOF
    pkg_name="${package_dir##*/}"

    ./scripts/feeds install -f -p "${feed_name}" "${pkg_name}"
  done < "${PACKAGE_FILE}"

  log "生成 defconfig"
  make defconfig
}

find_installed_package_dir() {
  feed_name="$1"
  source_dir="$2"
  feed_dir="${SDK_ROOT}/package/feeds/${feed_name}"
  result=""

  [ -d "${feed_dir}" ] || fail "未找到 feed 安装目录：${feed_dir}"

  while IFS= read -r installed_path; do
    real_path="$(readlink -f "${installed_path}")"
    [ "${real_path}" = "${source_dir}" ] || continue

    if [ -n "${result}" ]; then
      fail "检测到多个安装路径映射到同一源码目录：${source_dir}"
    fi

    result="${installed_path}"
  done <<EOF
$(find "${feed_dir}" -mindepth 1 -maxdepth 3 \( -type l -o -type d \) | sort)
EOF

  [ -n "${result}" ] || fail "未找到已安装的 feed 包目录：${source_dir}"
  printf '%s\n' "${result}"
}

compile_packages() {
  build_jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"

  while IFS="${TAB}" read -r package_dir source_url source_ref; do
    mapping="$(lookup_source_mapping "${source_url}" "${source_ref}")"
    [ -n "${mapping}" ] || fail "未找到源码映射：${source_url} @ ${source_ref}"

    IFS="${TAB}" read -r _map_url _map_ref feed_name repo_dir source_kind <<EOF
${mapping}
EOF

    source_dir="${repo_dir}/${package_dir}"
    [ -d "${source_dir}" ] || fail "源仓库 ${source_url}@${source_ref} 中不存在包目录：${package_dir}"

    installed_dir="$(find_installed_package_dir "${feed_name}" "${source_dir}")"
    target_path="${installed_dir#${SDK_ROOT}/}"

    log "编译 ${package_dir} (${feed_name}) -> ${target_path}"
    make -C "${SDK_ROOT}" "${target_path}/clean" V=s
    make -C "${SDK_ROOT}" "${target_path}/compile" V=s -j"${build_jobs}"
  done < "${PACKAGE_FILE}"
}

render_release_notes() {
  build_time="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  {
    echo "OpenWrt Version: ${OPENWRT_VERSION}"
    echo "OpenWrt Arch: ${OPENWRT_ARCH}"
    echo "SDK Image: ${SDK_IMAGE}"
    [ -n "${TARGET_DEVICE_NAME}" ] && echo "Target Device: ${TARGET_DEVICE_NAME}"
    [ -n "${TARGET_BOARD_NAME}" ] && echo "Target Board: ${TARGET_BOARD_NAME}"
    [ -n "${TARGET_FIRMWARE_RELEASE}" ] && echo "Target Firmware Release: ${TARGET_FIRMWARE_RELEASE}"
    [ -n "${TARGET_FIRMWARE_REVISION}" ] && echo "Target Firmware Revision: ${TARGET_FIRMWARE_REVISION}"
    [ -n "${TARGET_FIRMWARE_TARGET}" ] && echo "Target Firmware Target: ${TARGET_FIRMWARE_TARGET}"
    [ -n "${TARGET_FIRMWARE_ARCH}" ] && echo "Target Firmware Arch: ${TARGET_FIRMWARE_ARCH}"
    [ -n "${TARGET_FIRMWARE_KERNEL}" ] && echo "Target Firmware Kernel: ${TARGET_FIRMWARE_KERNEL}"
    [ -n "${TARGET_FIREWALL_BACKEND}" ] && echo "Target Firewall Backend: ${TARGET_FIREWALL_BACKEND}"
    echo "Default Source URL: ${PACKAGE_SOURCE_URL}"
    echo "Default Source Ref: ${PACKAGE_SOURCE_REF}"
    echo "Build Time (UTC): ${build_time}"
    echo "Selected Packages:"
    while IFS="${TAB}" read -r package_dir source_url source_ref; do
      echo "- ${package_dir} | ${source_url} @ ${source_ref}"
    done < "${PACKAGE_FILE}"
    echo "Resolved Source Commits:"
    while IFS="${TAB}" read -r source_url source_ref feed_name repo_dir source_kind; do
      source_commit="$(resolve_source_commit "${repo_dir}")"
      echo "- ${feed_name} | ${source_url} @ ${source_ref} | ${source_commit}"
    done < "${SOURCE_MAP_FILE}"
  } > "${DIST_DIR}/BUILD_INFO.txt"

  {
    echo "# OpenWrt IPK Build"
    echo
    echo "- OpenWrt: \`${OPENWRT_VERSION}\`"
    echo "- 架构: \`${OPENWRT_ARCH}\`"
    echo "- SDK 镜像: \`${SDK_IMAGE}\`"
    [ -n "${TARGET_DEVICE_NAME}" ] && echo "- 目标设备: \`${TARGET_DEVICE_NAME}\`"
    [ -n "${TARGET_BOARD_NAME}" ] && echo "- 目标板型: \`${TARGET_BOARD_NAME}\`"
    [ -n "${TARGET_FIRMWARE_RELEASE}" ] && echo "- 目标固件版本: \`${TARGET_FIRMWARE_RELEASE}\`"
    [ -n "${TARGET_FIRMWARE_REVISION}" ] && echo "- 目标固件修订: \`${TARGET_FIRMWARE_REVISION}\`"
    [ -n "${TARGET_FIRMWARE_TARGET}" ] && echo "- 目标固件 Target: \`${TARGET_FIRMWARE_TARGET}\`"
    [ -n "${TARGET_FIRMWARE_ARCH}" ] && echo "- 目标固件架构: \`${TARGET_FIRMWARE_ARCH}\`"
    [ -n "${TARGET_FIRMWARE_KERNEL}" ] && echo "- 目标内核: \`${TARGET_FIRMWARE_KERNEL}\`"
    [ -n "${TARGET_FIREWALL_BACKEND}" ] && echo "- 目标防火墙后端: \`${TARGET_FIREWALL_BACKEND}\`"
    echo "- 默认源码仓库: \`${PACKAGE_SOURCE_URL}\`"
    echo "- 默认源码 Ref: \`${PACKAGE_SOURCE_REF}\`"
    echo "- 构建时间(UTC): \`${build_time}\`"
    echo
    echo "## Selected packages"
    while IFS="${TAB}" read -r package_dir source_url source_ref; do
      echo "- \`${package_dir}\` from \`${source_url}\` @ \`${source_ref}\`"
    done < "${PACKAGE_FILE}"
    echo
    echo "## Resolved source commits"
    while IFS="${TAB}" read -r source_url source_ref feed_name repo_dir source_kind; do
      source_commit="$(resolve_source_commit "${repo_dir}")"
      echo "- \`${feed_name}\`: \`${source_url}\` @ \`${source_ref}\` -> \`${source_commit}\`"
    done < "${SOURCE_MAP_FILE}"
  } > "${DIST_DIR}/RELEASE_NOTES.md"
}

collect_artifacts() {
  package_root="${SDK_ROOT}/bin/packages/${OPENWRT_ARCH}"

  [ -d "${package_root}" ] || fail "未找到编译产物目录：${package_root}"

  find "${DIST_DIR}" -mindepth 1 -maxdepth 1 -type f \
    ! -name 'BUILD_INFO.txt' \
    ! -name 'RELEASE_NOTES.md' \
    ! -name 'build.log' -delete

  while IFS="${TAB}" read -r package_dir source_url source_ref; do
    pkg_name="${package_dir##*/}"
    matches="$(find "${package_root}" -type f -name "${pkg_name}_*.ipk" | sort)"
    [ -n "${matches}" ] || fail "未找到目标包产物：${pkg_name}"

    printf '%s\n' "${matches}" | while IFS= read -r artifact; do
      [ -n "${artifact}" ] || continue
      cp "${artifact}" "${DIST_DIR}/"
    done
  done < "${PACKAGE_FILE}"

  render_release_notes

  (
    cd "${DIST_DIR}"
    set -- ./*.ipk
    [ -e "$1" ] || fail "dist 目录中没有可索引的 .ipk 文件"
    "${SDK_ROOT}/scripts/ipkg-make-index.sh" . > Packages
    gzip -n -9c Packages > Packages.gz
    sha256sum ./*.ipk Packages Packages.gz > SHA256SUMS
  )
}

main() {
  if [ -n "${PACKAGE_DIRS:-}" ]; then
    log "使用 workflow_dispatch 输入的包列表"
    normalize_package_list env
  else
    log "使用仓库中的 config/packages.txt"
    normalize_package_list file
  fi

  prepare_sdk
  prepare_sources
  prepare_local_tools
  configure_feeds
  compile_packages
  collect_artifacts

  log "构建完成，产物目录：${DIST_DIR}"
}

main "$@"
