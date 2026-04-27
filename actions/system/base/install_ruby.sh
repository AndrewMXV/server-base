#!/usr/bin/env bash
set -euo pipefail

VER="${1:-}"
BASE="https://rubies.travis-ci.org"
ARCH_RAW="${RUBY_ARCH:-$(uname -m)}"
INDEX_HTML=""
PLATFORM_CANDIDATES=()
ATTEMPTED_URLS=()
ATTEMPT_ERRORS=()

case "$ARCH_RAW" in
  x86_64|amd64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH="aarch64" ;;
  *)
    ARCH="$ARCH_RAW"
    ;;
esac

if [[ -z "$VER" ]]; then
  echo "Usage: $0 <ruby-version>"
  exit 1
fi

escape_regex() {
  printf '%s' "$1" | sed 's/[][\.^$*+?(){}|/]/\\&/g'
}

fetch_index() {
  [ -n "$INDEX_HTML" ] || INDEX_HTML="$(curl -fsSL --retry 2 --retry-delay 1 "$BASE/" 2>/dev/null || true)"
}

add_candidate() {
  local candidate="$1"
  [ -n "$candidate" ] || return
  local item
  for item in "${PLATFORM_CANDIDATES[@]}"; do
    [ "$item" = "$candidate" ] && return
  done
  PLATFORM_CANDIDATES+=("$candidate")
}

detect_platform() {
  local os="${RUBY_PLATFORM_OS:-}" ver="${RUBY_PLATFORM_VER:-}"
  if [[ ( -z "$os" || -z "$ver" ) && -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os="${os:-${ID:-}}"
    ver="${ver:-${VERSION_ID:-}}"
  fi
  os="${os:-ubuntu}"
  ver="${ver:-20.04}"
  printf '%s %s\n' "$os" "$ver"
}

list_available_versions() {
  local os="$1" ver="$2"
  local files versions prefix escaped_prefix
  prefix="${BASE}/${os}/${ver}/${ARCH}/ruby-"
  escaped_prefix="$(escape_regex "$prefix")"
  fetch_index
  [ -n "$INDEX_HTML" ] || {
    echo "  (unable to fetch index: $BASE/)"
    return
  }

  files="$(printf '%s' "$INDEX_HTML" | grep -oE "${escaped_prefix}[0-9]+\\.[0-9]+\\.[0-9]+" || true)"
  versions="$(printf '%s\n' "$files" | sed -E "s#^${escaped_prefix}##" | sort -Vu)"
  [ -n "$versions" ] || {
    echo "  (no versions listed for ${os}/${ver}/${ARCH})"
    return
  }

  printf '%s\n' "$versions" | tail -n 20 | sed 's/^/  - /'
}

url_for() {
  local os="$1" ver="$2"
  echo "${BASE}/${os}/${ver}/${ARCH}/ruby-${VER}.tar.bz2"
}

url_exists() {
  curl -fsSI --retry 2 --retry-delay 1 "$1" >/dev/null 2>&1
}

ensure_bzip2() {
  command -v bzip2 >/dev/null 2>&1
}

extract_tarball() {
  local archive="$1" dest="$2"

  if ensure_bzip2; then
    tar -xjf "$archive" -C "$dest" --strip-components=1
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    echo "[*] bzip2 not found, extracting archive via python3"
    python3 - "$archive" <<'PY' | tar -x -C "$dest" --strip-components=1 -f -
import bz2
import sys

with bz2.open(sys.argv[1], "rb") as src:
    out = sys.stdout.buffer
    while True:
        chunk = src.read(1024 * 1024)
        if not chunk:
            break
        out.write(chunk)
PY
    return
  fi

  echo "[ERROR] Cannot extract Ruby archive: need 'bzip2' or 'python3'" >&2
  exit 1
}

missing_libs() {
  local ruby_bin="$1"
  if ! command -v ldd >/dev/null 2>&1; then
    return 0
  fi
  ldd "$ruby_bin" 2>/dev/null | awk '/=> not found/{print $1}' || true
}

missing_openssl_ext_libs() {
  local stage_dir="$1" ext_so
  ext_so="$(find "$stage_dir/lib/ruby" -type f -name openssl.so 2>/dev/null | head -n 1 || true)"
  [ -n "$ext_so" ] || return 0
  ldd "$ext_so" 2>/dev/null | awk '/=> not found/{print $1}' || true
}

install_compat_for_missing_libs() {
  local missing="$1"
  [ -n "$missing" ] || return 0

  if printf '%s\n' "$missing" | grep -qx 'libcrypt.so.1'; then
    if command -v dnf >/dev/null 2>&1; then
      echo "[*] Installing libxcrypt-compat (required by libcrypt.so.1)"
      dnf install -y libxcrypt-compat || dnf install -y libxcrypt-compat.x86_64 || true
    elif command -v apt-get >/dev/null 2>&1; then
      echo "[*] Installing libxcrypt1 (required by libcrypt.so.1)"
      apt-get update -y || true
      apt-get install -y libxcrypt1 || true
    fi
  fi

  if printf '%s\n' "$missing" | grep -Eq '^(libssl\.so\.1\.1|libcrypto\.so\.1\.1)$'; then
    if [ "${HOST_OPENSSL_SONAME:-unknown}" = "3" ] && [ "${DETECTED_OS:-}" = "redos" ]; then
      echo "[*] Host uses OpenSSL 3 (libssl.so.3); skipping OpenSSL 1.1 compatibility installation attempt"
      return 0
    fi
    if command -v dnf >/dev/null 2>&1; then
      echo "[*] Installing OpenSSL 1.1 compatibility libs"
      dnf install -y compat-openssl11 || dnf install -y openssl11-libs || dnf install -y openssl11 || true
    elif command -v apt-get >/dev/null 2>&1; then
      echo "[*] Installing OpenSSL 1.1 compatibility libs"
      apt-get update -y || true
      apt-get install -y libssl1.1 || true
    fi
  fi
}

detect_glibc_version() {
  if command -v getconf >/dev/null 2>&1; then
    local v
    v="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)"
    [ -n "$v" ] && { echo "$v"; return; }
  fi
  if command -v ldd >/dev/null 2>&1; then
    local v
    v="$(ldd --version 2>/dev/null | head -n 1 | sed -E 's/.* ([0-9]+\.[0-9]+).*/\1/' || true)"
    [ -n "$v" ] && { echo "$v"; return; }
  fi
  echo "unknown"
}

detect_openssl_soname() {
  if command -v ldconfig >/dev/null 2>&1; then
    if ldconfig -p 2>/dev/null | grep -q 'libssl\.so\.3'; then
      echo "3"
      return
    fi
    if ldconfig -p 2>/dev/null | grep -q 'libssl\.so\.1\.1'; then
      echo "1.1"
      return
    fi
  fi
  if [ -e /usr/lib64/libssl.so.3 ] || [ -e /lib64/libssl.so.3 ]; then
    echo "3"
    return
  fi
  if [ -e /usr/lib64/libssl.so.1.1 ] || [ -e /lib64/libssl.so.1.1 ]; then
    echo "1.1"
    return
  fi
  echo "unknown"
}

runtime_check_error() {
  local stage_dir="$1" ruby_bin ruby_out gem_out openssl_out
  ruby_bin="$stage_dir/bin/ruby"
  ruby_out="$("$ruby_bin" -v 2>&1 || true)"
  gem_out="$(PATH="$stage_dir/bin:$PATH" "$stage_dir/bin/gem" -v 2>&1 || true)"
  openssl_out="$("$ruby_bin" -ropenssl -e 'puts OpenSSL::OPENSSL_VERSION' 2>&1 || true)"

  if [ -z "$ruby_out" ] || [ -z "$gem_out" ] || printf '%s\n%s\n' "$ruby_out" "$gem_out" | grep -qiE '(not found|error while loading shared libraries|GLIBC_|no such file or directory)'; then
    echo "runtime check failed: ruby='${ruby_out%%$'\n'*}' gem='${gem_out%%$'\n'*}'"
    return 0
  fi

  if [ -z "$openssl_out" ] || printf '%s\n' "$openssl_out" | grep -qiE '(loaderror|not found|error while loading shared libraries|cannot open shared object file|no such file or directory)'; then
    echo "openssl check failed: ${openssl_out%%$'\n'*}"
    return 0
  fi

  return 1
}

try_install_redos_ruby33_repo() {
  [ "$DETECTED_OS" = "redos" ] || return 1
  case "$DETECTED_VER" in
    7|7.*) ;;
    *) return 1 ;;
  esac
  case "$VER" in
    3.*) ;;
    *) return 1 ;;
  esac
  command -v dnf >/dev/null 2>&1 || return 1

  echo "[*] Trying RedOS Ruby 3.3 repository (ruby33-release)"
  if ! dnf install -y ruby33-release; then
    echo "[*] ruby33-release is unavailable, falling back to binary tarballs"
    return 1
  fi

  # rubypick owns /usr/bin/ruby on some RedOS 7 images and blocks ruby33 transaction.
  if rpm -q rubypick >/dev/null 2>&1; then
    dnf remove -y rubypick || true
  fi

  if ! dnf install -y --enablerepo=ruby33 --disablerepo=base,updates --best --allowerasing ruby ruby-libs rubygems rubygem-bundler; then
    echo "[*] failed to install Ruby from ruby33 repo, falling back to binary tarballs"
    return 1
  fi

  ruby -e 'exit(RUBY_VERSION.split(".").first.to_i >= 3 ? 0 : 1)' >/dev/null 2>&1 || {
    echo "[*] ruby33 repo install did not provide Ruby >= 3, falling back to binary tarballs"
    return 1
  }
  ruby -ropenssl -e 'puts OpenSSL::OPENSSL_VERSION' >/dev/null 2>&1 || {
    echo "[*] ruby33 repo install has broken OpenSSL extension, falling back to binary tarballs"
    return 1
  }

  [ -x /usr/bin/ruby ] && ln -sf /usr/bin/ruby /usr/local/bin/ruby
  [ -x /usr/bin/gem ] && ln -sf /usr/bin/gem /usr/local/bin/gem
  [ -x /usr/bin/irb ] && ln -sf /usr/bin/irb /usr/local/bin/irb
  if [ -x /usr/bin/bundle ]; then
    ln -sf /usr/bin/bundle /usr/local/bin/bundle
  else
    rm -f /usr/local/bin/bundle
  fi

  echo "[*] Ruby installed from ruby33 repo:"
  ruby -v
  gem -v
  ruby -ropenssl -e 'puts OpenSSL::OPENSSL_VERSION'
  return 0
}

read -r DETECTED_OS DETECTED_VER <<<"$(detect_platform)"
HOST_GLIBC="$(detect_glibc_version)"
HOST_OPENSSL_SONAME="$(detect_openssl_soname)"
echo "[*] Host platform: ${DETECTED_OS}/${DETECTED_VER}/${ARCH}"
echo "[*] Host GLIBC: ${HOST_GLIBC}"
echo "[*] Host OpenSSL SONAME: libssl.so.${HOST_OPENSSL_SONAME}"
add_candidate "${DETECTED_OS}/${DETECTED_VER}"
[ "${DETECTED_VER%%.*}" != "$DETECTED_VER" ] && add_candidate "${DETECTED_OS}/${DETECTED_VER%%.*}"
DEST="/opt/ruby-${VER}"
if [ "$DETECTED_OS" = "redos" ]; then
  add_candidate "redos/8.0"
  add_candidate "centos/8"
  add_candidate "centos/7"
fi
add_candidate "ubuntu/18.04"
add_candidate "ubuntu/20.04"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

if try_install_redos_ruby33_repo; then
  echo "[OK] Installed Ruby ${VER} via ruby33-release path"
  exit 0
fi

SELECTED_OS=""
SELECTED_VER=""
SELECTED_URL=""
for candidate in "${PLATFORM_CANDIDATES[@]}"; do
  os="${candidate%/*}"
  ver="${candidate#*/}"
  candidate_url="$(url_for "$os" "$ver")"
  ATTEMPTED_URLS+=("$candidate_url")
  url_exists "$candidate_url" || continue

  echo "[*] Trying Ruby platform: ${os}/${ver}/${ARCH}"
  tarball="${TMP_ROOT}/$(basename "$candidate_url")"
  if ! curl -fsSL --retry 3 --retry-delay 1 "$candidate_url" -o "$tarball"; then
    ATTEMPT_ERRORS+=("${candidate_url} :: download failed")
    continue
  fi

  stage="${TMP_ROOT}/stage-${os//\//-}-${ver//\//-}"
  rm -rf "$stage"
  mkdir -p "$stage"
  if ! extract_tarball "$tarball" "$stage"; then
    ATTEMPT_ERRORS+=("${candidate_url} :: extract failed")
    continue
  fi

  missing="$( { missing_libs "$stage/bin/ruby"; missing_openssl_ext_libs "$stage"; } | sort -u )"
  if [ -n "$missing" ]; then
    echo "[*] Missing runtime libs detected:"
    printf '  - %s\n' $missing
    install_compat_for_missing_libs "$missing"
  fi
  missing_after="$( { missing_libs "$stage/bin/ruby"; missing_openssl_ext_libs "$stage"; } | sort -u )"
  if [ -n "$missing_after" ]; then
    ATTEMPT_ERRORS+=("${candidate_url} :: unresolved libs: $(printf '%s' "$missing_after" | tr '\n' ',' | sed 's/,$//')")
    continue
  fi

  runtime_error="$(runtime_check_error "$stage" || true)"
  if [ -n "$runtime_error" ]; then
    ATTEMPT_ERRORS+=("${candidate_url} :: ${runtime_error}")
    continue
  fi

  echo "[*] Installing to: $DEST"
  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp -a "$stage/." "$DEST/"

  SELECTED_OS="$os"
  SELECTED_VER="$ver"
  SELECTED_URL="$candidate_url"
  break
done

if [ -z "$SELECTED_URL" ]; then
  echo "[ERROR] Requested Ruby is unavailable or incompatible for ${DETECTED_OS}/${DETECTED_VER}/${ARCH}: ${VER}" >&2
  echo "[INFO] Host GLIBC: ${HOST_GLIBC}" >&2
  echo "[INFO] Checked URLs:" >&2
  printf '  - %s\n' "${ATTEMPTED_URLS[@]}" >&2
  if [ "${#ATTEMPT_ERRORS[@]}" -gt 0 ]; then
    echo "[INFO] Attempt errors:" >&2
    printf '  - %s\n' "${ATTEMPT_ERRORS[@]}" >&2
  fi
  echo "[INFO] Last available versions for ${DETECTED_OS}/${DETECTED_VER}/${ARCH}:" >&2
  list_available_versions "$DETECTED_OS" "$DETECTED_VER" >&2
  exit 1
fi

if [ "${SELECTED_OS}/${SELECTED_VER}" != "${DETECTED_OS}/${DETECTED_VER}" ]; then
  echo "[*] Using fallback Ruby platform: ${SELECTED_OS}/${SELECTED_VER}/${ARCH}"
fi

echo "[*] Download source: $SELECTED_URL"
echo "[*] Verifying extracted Ruby binary"
"$DEST/bin/ruby" -v
PATH="$DEST/bin:$PATH" "$DEST/bin/gem" -v
"$DEST/bin/ruby" -ropenssl -e 'puts OpenSSL::OPENSSL_VERSION'

echo "[*] Symlinking binaries into /usr/local/bin"
ln -sf "$DEST/bin/ruby" /usr/local/bin/ruby
ln -sf "$DEST/bin/gem" /usr/local/bin/gem
ln -sf "$DEST/bin/irb" /usr/local/bin/irb
ln -sf "$DEST/bin/bundle" /usr/local/bin/bundle || true

echo "[*] Checking:"
ruby -v
gem -v

echo "[*] Dynamic deps (should be minimal):"
ldd "$DEST/bin/ruby" || true

echo "[OK] Installed Ruby ${VER}"
