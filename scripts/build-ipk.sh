#!/bin/sh

set -eu

log() {
  printf '\n[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

WORKSPACE="${WORKSPACE:-/workspace}"
SDK_ROOT="${SDK_ROOT:-/builder}"
PACKAGE_SOURCE_URL="${PACKAGE_SOURCE_URL:?PACKAGE_SOURCE_URL is required}"
PACKAGE_SOURCE_REF="${PACKAGE_SOURCE_REF:-Lede}"
OPENWRT_VERSION="${OPENWRT_VERSION:?OPENWRT_VERSION is required}"
OPENWRT_ARCH="${OPENWRT_ARCH:?OPENWRT_ARCH is required}"
CUSTOM_FEED_NAME="${CUSTOM_FEED_NAME:-shidahuilang}"
SDK_IMAGE="${SDK_IMAGE:-unknown}"

STATE_DIR="${WORKSPACE}/.work"
DIST_DIR="${WORKSPACE}/dist"
UPSTREAM_DIR="${STATE_DIR}/upstream/openwrt-package"
PACKAGE_LIST_FILE="${WORKSPACE}/config/packages.txt"
PACKAGE_FILE="${STATE_DIR}/package-dirs.txt"

mkdir -p "${STATE_DIR}" "${DIST_DIR}"
rm -f "${PACKAGE_FILE}"

normalize_package_list() {
  input_source="$1"

  if [ "${input_source}" = "env" ]; then
    printf '%s\n' "${PACKAGE_DIRS:-}" |
      tr ', \t' '\n\n\n' |
      sed 's/\r$//' |
      sed '/^[[:space:]]*$/d' > "${PACKAGE_FILE}"
  else
    if [ ! -f "${PACKAGE_LIST_FILE}" ]; then
      fail "找不到包清单文件：${PACKAGE_LIST_FILE}"
    fi

    sed 's/#.*$//' "${PACKAGE_LIST_FILE}" |
      tr ', \t' '\n\n\n' |
      sed 's/\r$//' |
      sed '/^[[:space:]]*$/d' > "${PACKAGE_FILE}"
  fi

  awk '!seen[$0]++ { print }' "${PACKAGE_FILE}" > "${PACKAGE_FILE}.tmp"
  mv "${PACKAGE_FILE}.tmp" "${PACKAGE_FILE}"

  if [ ! -s "${PACKAGE_FILE}" ]; then
    fail "未解析到任何待编译包，请在 workflow_dispatch 输入 packages，或维护 config/packages.txt"
  fi

  while IFS= read -r pkg_dir; do
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
  done < "${PACKAGE_FILE}"
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

clone_upstream_repo() {
  rm -rf "${UPSTREAM_DIR}"
  mkdir -p "$(dirname "${UPSTREAM_DIR}")"

  log "克隆上游源码：${PACKAGE_SOURCE_URL} @ ${PACKAGE_SOURCE_REF}"
  if ! git clone --filter=blob:none --depth 1 --branch "${PACKAGE_SOURCE_REF}" "${PACKAGE_SOURCE_URL}" "${UPSTREAM_DIR}"; then
    git clone --filter=blob:none "${PACKAGE_SOURCE_URL}" "${UPSTREAM_DIR}"
    (
      cd "${UPSTREAM_DIR}"
      git fetch --depth 1 origin "${PACKAGE_SOURCE_REF}"
      git checkout FETCH_HEAD
    )
  fi
}

configure_feeds() {
  cd "${SDK_ROOT}"

  cp feeds.conf.default feeds.conf
  printf '\nsrc-link %s %s\n' "${CUSTOM_FEED_NAME}" "${UPSTREAM_DIR}" >> feeds.conf

  log "更新官方 feeds"
  ./scripts/feeds update -a

  log "安装官方 feeds"
  ./scripts/feeds install -a

  log "安装自定义 feed 目标包：${CUSTOM_FEED_NAME}"
  while IFS= read -r pkg_dir; do
    pkg_name="${pkg_dir##*/}"
    ./scripts/feeds install -f -p "${CUSTOM_FEED_NAME}" "${pkg_name}"
  done < "${PACKAGE_FILE}"

  log "生成 defconfig"
  make defconfig
}

find_installed_package_dir() {
  source_dir="$1"
  result=""

  [ -d "${SDK_ROOT}/package/feeds/${CUSTOM_FEED_NAME}" ] ||
    fail "未找到自定义 feed 安装目录：${SDK_ROOT}/package/feeds/${CUSTOM_FEED_NAME}"

  while IFS= read -r installed_path; do
    real_path="$(readlink -f "${installed_path}")"
    [ "${real_path}" = "${source_dir}" ] || continue

    if [ -n "${result}" ]; then
      fail "检测到多个安装路径映射到同一源码目录：${source_dir}"
    fi

    result="${installed_path}"
  done <<EOF
$(find "${SDK_ROOT}/package/feeds/${CUSTOM_FEED_NAME}" -mindepth 1 -maxdepth 3 \( -type l -o -type d \) | sort)
EOF

  [ -n "${result}" ] || fail "未找到已安装的 feed 包目录：${source_dir}"
  printf '%s\n' "${result}"
}

compile_packages() {
  build_jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"

  while IFS= read -r pkg_dir; do
    source_dir="${UPSTREAM_DIR}/${pkg_dir}"
    [ -d "${source_dir}" ] || fail "上游仓库中不存在包目录：${pkg_dir}"

    installed_dir="$(find_installed_package_dir "${source_dir}")"
    target_path="${installed_dir#${SDK_ROOT}/}"

    log "编译 ${pkg_dir} -> ${target_path}"
    make -C "${SDK_ROOT}" "${target_path}/clean" V=s
    make -C "${SDK_ROOT}" "${target_path}/compile" V=s -j"${build_jobs}"
  done < "${PACKAGE_FILE}"
}

render_release_notes() {
  build_time="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  upstream_commit="$(git -C "${UPSTREAM_DIR}" rev-parse HEAD)"

  {
    echo "OpenWrt Version: ${OPENWRT_VERSION}"
    echo "OpenWrt Arch: ${OPENWRT_ARCH}"
    echo "SDK Image: ${SDK_IMAGE}"
    echo "Package Source URL: ${PACKAGE_SOURCE_URL}"
    echo "Package Source Ref: ${PACKAGE_SOURCE_REF}"
    echo "Package Source Commit: ${upstream_commit}"
    echo "Custom Feed Name: ${CUSTOM_FEED_NAME}"
    echo "Build Time (UTC): ${build_time}"
    echo "Selected Package Directories:"
    sed 's/^/- /' "${PACKAGE_FILE}"
  } > "${DIST_DIR}/BUILD_INFO.txt"

  {
    echo "# OpenWrt IPK Build"
    echo
    echo "- OpenWrt: \`${OPENWRT_VERSION}\`"
    echo "- 架构: \`${OPENWRT_ARCH}\`"
    echo "- SDK 镜像: \`${SDK_IMAGE}\`"
    echo "- 上游仓库: \`${PACKAGE_SOURCE_URL}\`"
    echo "- 上游 Ref: \`${PACKAGE_SOURCE_REF}\`"
    echo "- 上游 Commit: \`${upstream_commit}\`"
    echo "- 自定义 Feed: \`${CUSTOM_FEED_NAME}\`"
    echo "- 构建时间(UTC): \`${build_time}\`"
    echo
    echo "## Selected package directories"
    sed 's/^/- `&`/' "${PACKAGE_FILE}"
  } > "${DIST_DIR}/RELEASE_NOTES.md"
}

collect_artifacts() {
  package_output_dir="${SDK_ROOT}/bin/packages/${OPENWRT_ARCH}/${CUSTOM_FEED_NAME}"

  [ -d "${package_output_dir}" ] || fail "未找到编译产物目录：${package_output_dir}"

  find "${DIST_DIR}" -mindepth 1 -maxdepth 1 -type f ! -name 'BUILD_INFO.txt' ! -name 'RELEASE_NOTES.md' -delete
  set -- "${package_output_dir}"/*.ipk
  [ -e "$1" ] || fail "自定义 feed 没有生成任何 .ipk 文件：${package_output_dir}"
  cp "$@" "${DIST_DIR}/"

  (
    cd "${DIST_DIR}"
    "${SDK_ROOT}/scripts/ipkg-make-index.sh" . > Packages
    gzip -n -9c Packages > Packages.gz
    sha256sum ./*.ipk Packages Packages.gz > SHA256SUMS
  )

  render_release_notes
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
  clone_upstream_repo
  configure_feeds
  compile_packages
  collect_artifacts

  log "构建完成，产物目录：${DIST_DIR}"
}

main "$@"
