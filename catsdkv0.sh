#!/usr/bin/env bash
# catsdk.sh — CatSDK 0.1 compiler recognizer/bootstrap for Apple Silicon macOS.
# Purpose: set up a broad, legal console/dev cross-compiler surface on an M4/M4 Pro Mac.
# It uses Apple CLT, MacPorts, optional local devkitPro pkg, and SDK detection hooks.
# It does not install proprietary console SDKs; it only recognizes them if already licensed/installed.

set -Eeuo pipefail
IFS=$'\n\t'

CATSDK_VERSION="0.1.0"
CATSDK_HOME="${CATSDK_HOME:-$HOME/.catsdk}"
CATSDK_BIN="$CATSDK_HOME/bin"
CATSDK_LOG="$CATSDK_HOME/catsdk-install.log"
MACPORTS_VERSION="${CATSDK_MACPORTS_VERSION:-2.12.5}"
MACPORTS_PREFIX="${MACPORTS_PREFIX:-/opt/local}"
DEVKITPRO_PREFIX="${DEVKITPRO:-/opt/devkitpro}"
DEVKITPRO_PKG="${CATSDK_DEVKITPRO_PKG:-}"
BINARY_ONLY="${CATSDK_BINARY_ONLY:-1}"
INSTALL_DEVKITPRO="${CATSDK_INSTALL_DEVKITPRO:-1}"
INSTALL_MACPORTS="${CATSDK_INSTALL_MACPORTS:-1}"
INSTALL_PORTS="${CATSDK_INSTALL_PORTS:-1}"
DRY_RUN="${CATSDK_DRY_RUN:-0}"
YES="${CATSDK_YES:-0}"
SOURCE_BUILDS_ALLOWED="${CATSDK_ALLOW_SOURCE_BUILDS:-0}"

mkdir -p "$CATSDK_HOME" "$CATSDK_BIN"
: > "$CATSDK_LOG"

say()  { printf '%s\n' "$*" | tee -a "$CATSDK_LOG"; }
warn() { printf 'WARN: %s\n' "$*" | tee -a "$CATSDK_LOG" >&2; }
fail() { printf 'ERROR: %s\n' "$*" | tee -a "$CATSDK_LOG" >&2; exit 1; }

usage() {
  cat <<'USAGE'
CatSDK 0.1 — catsdk.sh

Install/recognize broad legal compiler toolchains on Apple Silicon macOS.

Usage:
  chmod +x catsdk.sh
  ./catsdk.sh
  ./catsdk.sh --doctor
  ./catsdk.sh --dry-run

Options:
  --doctor                 Only install/update CatSDK registry command, then scan tools.
  --no-macports            Do not install MacPorts if missing.
  --no-ports               Do not install MacPorts compiler ports.
  --no-devkitpro           Do not install/use devkitPro package groups.
  --devkitpro-pkg PATH     Use a local official devkitPro pacman installer .pkg.
  --allow-source-builds    Let MacPorts build from upstream source if no binary is available.
                           Default is binary-only to avoid random upstream fetches.
  --binary-only            Force MacPorts binary-only installs. Default.
  --yes                    Non-interactive where supported.
  --dry-run                Print actions without changing the system.
  --help                   Show this help.

Useful environment variables:
  CATSDK_DEVKITPRO_PKG=/path/to/devkitpro-pacman-installer.pkg ./catsdk.sh
  CATSDK_BINARY_ONLY=0 CATSDK_ALLOW_SOURCE_BUILDS=1 ./catsdk.sh
  PS5_SDK_DIR=/path/to/official/ps5/sdk ./catsdk.sh --doctor
  SWITCH_SDK_DIR=/path/to/official/switch/sdk ./catsdk.sh --doctor
  XBOX_GDK_DIR=/path/to/Microsoft/GDK ./catsdk.sh --doctor
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --doctor) INSTALL_MACPORTS=0; INSTALL_PORTS=0; INSTALL_DEVKITPRO=0; DOCTOR_ONLY=1; shift ;;
    --no-macports) INSTALL_MACPORTS=0; shift ;;
    --no-ports) INSTALL_PORTS=0; shift ;;
    --no-devkitpro) INSTALL_DEVKITPRO=0; shift ;;
    --devkitpro-pkg) DEVKITPRO_PKG="${2:-}"; [[ -n "$DEVKITPRO_PKG" ]] || fail "--devkitpro-pkg needs a path"; shift 2 ;;
    --allow-source-builds) SOURCE_BUILDS_ALLOWED=1; BINARY_ONLY=0; shift ;;
    --binary-only) BINARY_ONLY=1; SOURCE_BUILDS_ALLOWED=0; shift ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

run() {
  say "+ $*"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  "$@"
}

run_sudo() {
  say "+ sudo $*"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  sudo "$@"
}

fetch() {
  local url="$1" out="$2"
  case "$url" in
    http://*) fail "Refusing non-HTTPS URL: $url" ;;
  esac
  say "+ curl -fL $url -> $out"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  /usr/bin/curl -fL --retry 3 --connect-timeout 20 --proto '=https' --tlsv1.2 "$url" -o "$out"
}

require_not_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    fail "Run this as your normal macOS user, not with sudo. The script will ask for sudo only when needed."
  fi
}

check_platform() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "This script is for macOS/Darwin."
  local arch
  arch="$(uname -m)"
  if [[ "$arch" != "arm64" ]]; then
    warn "This is written for Apple Silicon/M4 Pro. Current arch is '$arch'; continuing anyway."
  fi
  say "CatSDK $CATSDK_VERSION on macOS $(sw_vers -productVersion 2>/dev/null || echo unknown) / $arch"
}

ensure_clt() {
  if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    say "Apple Command Line Tools are missing. Opening the Apple installer now."
    if [[ "$DRY_RUN" != "1" ]]; then
      /usr/bin/xcode-select --install || true
    fi
    fail "Finish the Command Line Tools installer, then rerun ./catsdk.sh."
  fi
  if ! /usr/bin/clang --version >/dev/null 2>&1; then
    fail "clang was not found after Command Line Tools check. Install/update Xcode Command Line Tools and rerun."
  fi
}

port_cmd() {
  if command -v port >/dev/null 2>&1; then
    command -v port
  elif [[ -x "$MACPORTS_PREFIX/bin/port" ]]; then
    printf '%s\n' "$MACPORTS_PREFIX/bin/port"
  else
    return 1
  fi
}

install_macports_from_distfile() {
  if port_cmd >/dev/null 2>&1; then
    say "MacPorts already present at $(port_cmd)."
    return 0
  fi
  [[ "$INSTALL_MACPORTS" == "1" ]] || fail "MacPorts is missing and --no-macports was used."

  ensure_clt
  local srcdir tarball checksums workdir expected actual jobs
  workdir="$CATSDK_HOME/src"
  mkdir -p "$workdir"
  tarball="$workdir/MacPorts-$MACPORTS_VERSION.tar.bz2"
  checksums="$workdir/MacPorts-$MACPORTS_VERSION.chk.txt"
  srcdir="$workdir/MacPorts-$MACPORTS_VERSION"

  fetch "https://distfiles.macports.org/MacPorts/MacPorts-$MACPORTS_VERSION.tar.bz2" "$tarball"
  fetch "https://distfiles.macports.org/MacPorts/MacPorts-$MACPORTS_VERSION.chk.txt" "$checksums" || warn "Checksum file was unavailable; continuing without checksum verification."

  if [[ -s "$checksums" ]]; then
    expected="$(awk -v f="MacPorts-$MACPORTS_VERSION.tar.bz2" '
      $0 ~ f && toupper($0) ~ /SHA256/ {
        for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-fA-F]{64}$/) { print tolower($i); exit }
      }' "$checksums")"
    if [[ -n "$expected" ]]; then
      actual="$(/usr/bin/shasum -a 256 "$tarball" | awk '{print tolower($1)}')"
      [[ "$expected" == "$actual" ]] || fail "MacPorts tarball checksum mismatch."
      say "MacPorts tarball checksum OK."
    else
      warn "Could not parse SHA256 from checksum file; continuing."
    fi
  fi

  rm -rf "$srcdir"
  run /usr/bin/tar -xjf "$tarball" -C "$workdir"
  jobs="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  (
    cd "$srcdir"
    run ./configure --prefix="$MACPORTS_PREFIX" --with-applications-dir=/Applications/MacPorts
    run /usr/bin/make -j"$jobs"
    run_sudo /usr/bin/make install
  )
  export PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:$PATH"
  say "MacPorts installed."
}

ensure_macports_updated() {
  local p
  p="$(port_cmd)" || return 1
  say "Updating MacPorts ports tree."
  run_sudo "$p" -N selfupdate
}

port_is_installed() {
  local p pkg="$1"
  p="$(port_cmd)" || return 1
  "$p" installed "$pkg" 2>/dev/null | grep -q '@'
}

install_one_port() {
  local pkg="$1" p flags=()
  p="$(port_cmd)" || fail "MacPorts command not found."
  if port_is_installed "$pkg"; then
    say "MacPorts port already installed: $pkg"
    return 0
  fi
  flags=(-N)
  if [[ "$BINARY_ONLY" == "1" ]]; then
    flags+=(-b)
  fi
  if run_sudo "$p" "${flags[@]}" install "$pkg"; then
    return 0
  fi
  if [[ "$SOURCE_BUILDS_ALLOWED" == "1" && "$BINARY_ONLY" != "1" ]]; then
    warn "Binary install failed for $pkg; trying source build because --allow-source-builds was set."
    run_sudo "$p" -N install "$pkg"
  else
    warn "Skipped/failed: $pkg. Binary archive may be unavailable for this macOS/arch, or a dependency failed."
    return 1
  fi
}

install_macports_compilers() {
  [[ "$INSTALL_PORTS" == "1" ]] || return 0
  local base_ports cross_ports emulator_ports failed=() pkg
  base_ports=(
    cmake ninja pkgconfig gmake autoconf automake libtool texinfo python312
  )
  cross_ports=(
    cc65 sdcc
    arm-none-eabi-gcc arm-none-eabi-gdb
    m68k-elf-gcc mips-elf-gcc
    avr-gcc avr-libc avrdude
    i386-elf-gcc
    x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc
  )
  emulator_ports=(
    mame qemu
  )

  say "Installing MacPorts tool ports. Binary-only mode: $BINARY_ONLY"
  for pkg in "${base_ports[@]}" "${cross_ports[@]}" "${emulator_ports[@]}"; do
    install_one_port "$pkg" || failed+=("$pkg")
  done

  if [[ ${#failed[@]} -gt 0 ]]; then
    warn "Some ports did not install: ${failed[*]}"
    warn "Rerun with --allow-source-builds if you accept source builds from upstream mirrors."
  fi
}

find_dkp_pacman() {
  if command -v dkp-pacman >/dev/null 2>&1; then
    command -v dkp-pacman
  elif [[ -x "$DEVKITPRO_PREFIX/pacman/bin/dkp-pacman" ]]; then
    printf '%s\n' "$DEVKITPRO_PREFIX/pacman/bin/dkp-pacman"
  elif [[ -x "$DEVKITPRO_PREFIX/tools/bin/dkp-pacman" ]]; then
    printf '%s\n' "$DEVKITPRO_PREFIX/tools/bin/dkp-pacman"
  else
    return 1
  fi
}

install_devkitpro_if_available() {
  [[ "$INSTALL_DEVKITPRO" == "1" ]] || return 0

  if ! find_dkp_pacman >/dev/null 2>&1; then
    if [[ -n "$DEVKITPRO_PKG" ]]; then
      [[ -f "$DEVKITPRO_PKG" ]] || fail "devkitPro pkg not found: $DEVKITPRO_PKG"
      say "Installing local devkitPro pacman package: $DEVKITPRO_PKG"
      run_sudo /usr/sbin/installer -pkg "$DEVKITPRO_PKG" -target /
    else
      warn "devkitPro pacman was not found. For no external git-host fetches, download the official macOS .pkg yourself and rerun:"
      warn "  CATSDK_DEVKITPRO_PKG=/path/to/devkitpro-pacman-installer.pkg ./catsdk.sh"
      return 0
    fi
  fi

  local dkp groups failed=() g
  dkp="$(find_dkp_pacman)" || { warn "devkitPro pacman still not found after pkg install."; return 0; }
  groups=(
    devkit-env
    gba-dev nds-dev 3ds-dev
    gamecube-dev wii-dev wiiu-dev
    switch-dev
  )

  say "Updating devkitPro pacman database."
  run_sudo "$dkp" -Syu --needed --noconfirm || warn "devkitPro full update failed; continuing with package-group installs."
  for g in "${groups[@]}"; do
    run_sudo "$dkp" -S --needed --noconfirm "$g" || failed+=("$g")
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    warn "Some devkitPro groups did not install: ${failed[*]}"
  fi
}

write_env_file() {
  local envfile="$CATSDK_HOME/env.sh"
  cat > "$envfile" <<'ENVEOF'
# CatSDK 0.1 environment. Source this file from zsh/bash.
export CATSDK_HOME="${CATSDK_HOME:-$HOME/.catsdk}"
_catsdk_path_prepend() {
  [ -d "$1" ] || return 0
  case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac
}
_catsdk_path_prepend "$CATSDK_HOME/bin"
_catsdk_path_prepend "/opt/local/sbin"
_catsdk_path_prepend "/opt/local/bin"

export DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
if [ -d "$DEVKITPRO" ]; then
  export DEVKITARM="${DEVKITARM:-$DEVKITPRO/devkitARM}"
  export DEVKITPPC="${DEVKITPPC:-$DEVKITPRO/devkitPPC}"
  export DEVKITA64="${DEVKITA64:-$DEVKITPRO/devkitA64}"
  _catsdk_path_prepend "$DEVKITPRO/tools/bin"
  _catsdk_path_prepend "$DEVKITARM/bin"
  _catsdk_path_prepend "$DEVKITPPC/bin"
  _catsdk_path_prepend "$DEVKITA64/bin"
fi

# Optional official/commercial SDK roots. Set these only if you are licensed and have installed them.
[ -n "${PS5_SDK_DIR:-}" ] && _catsdk_path_prepend "$PS5_SDK_DIR/bin"
[ -n "${PLAYSTATION_SDK_DIR:-}" ] && _catsdk_path_prepend "$PLAYSTATION_SDK_DIR/bin"
[ -n "${SWITCH_SDK_DIR:-}" ] && _catsdk_path_prepend "$SWITCH_SDK_DIR/bin"
[ -n "${NINTENDO_SDK_ROOT:-}" ] && _catsdk_path_prepend "$NINTENDO_SDK_ROOT/bin"
[ -n "${XBOX_GDK_DIR:-}" ] && _catsdk_path_prepend "$XBOX_GDK_DIR/bin"
export PATH
ENVEOF
  say "Wrote $envfile"
}

install_catsdk_command() {
  local cmd="$CATSDK_BIN/catsdk"
  cat > "$cmd" <<'CMDEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

CATSDK_HOME="${CATSDK_HOME:-$HOME/.catsdk}"
[ -f "$CATSDK_HOME/env.sh" ] && . "$CATSDK_HOME/env.sh"

have() { command -v "$1" >/dev/null 2>&1; }
pathof() { command -v "$1" 2>/dev/null || true; }
status_tool() {
  local label="$1" tool="$2" note="${3:-}"
  if have "$tool"; then
    printf 'OK\t%s\t%s\t%s\n' "$label" "$tool" "$(pathof "$tool")"
  else
    printf 'MISS\t%s\t%s\t%s\n' "$label" "$tool" "$note"
  fi
}
status_dir() {
  local label="$1" dir="$2" note="${3:-}"
  if [[ -n "$dir" && -d "$dir" ]]; then
    printf 'OK\t%s\tdir\t%s\n' "$label" "$dir"
  else
    printf 'MISS\t%s\tdir\t%s\n' "$label" "$note"
  fi
}

print_header() {
  printf 'CatSDK 0.1 doctor\n'
  printf 'macOS: %s | arch: %s\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)" "$(uname -m)"
  printf 'home: %s\n\n' "$CATSDK_HOME"
  printf 'STATUS\tTARGET/FAMILY\tTOOL\tPATH/NOTE\n'
}

doctor() {
  print_header
  status_tool "Apple/macOS/iOS/tvOS/visionOS" clang "Install Apple Command Line Tools"
  status_tool "CMake build system" cmake "MacPorts/Homebrew/manual install"
  status_tool "Ninja build system" ninja "MacPorts/Homebrew/manual install"
  status_tool "Atari 8-bit/2600/5200, C64, NES-class 6502" cc65 "MacPorts: cc65"
  status_tool "6502 assembler/linker" ca65 "MacPorts: cc65"
  status_tool "6502 linker" ld65 "MacPorts: cc65"
  status_tool "Game Boy/MSX/Coleco/Z80/8051/PIC-ish" sdcc "MacPorts: sdcc"
  status_tool "Sega Genesis/Mega Drive, Amiga, Atari ST-class m68k" m68k-elf-gcc "MacPorts: m68k-elf-gcc"
  status_tool "PS1/PS2/PSP-style generic MIPS ELF" mips-elf-gcc "MacPorts: mips-elf-gcc; SDK/libs are separate"
  status_tool "GBA/NDS/3DS generic ARM bare-metal" arm-none-eabi-gcc "MacPorts or devkitARM"
  status_tool "devkitARM Nintendo homebrew" arm-none-eabi-gcc "devkitPro gba-dev/nds-dev/3ds-dev"
  status_tool "GameCube/Wii/Wii U PowerPC homebrew" powerpc-eabi-gcc "devkitPro gamecube-dev/wii-dev/wiiu-dev"
  status_tool "Nintendo Switch homebrew AArch64" aarch64-none-elf-gcc "devkitPro switch-dev/devkitA64"
  status_tool "AVR/microcontroller" avr-gcc "MacPorts: avr-gcc avr-libc"
  status_tool "32-bit x86 ELF" i386-elf-gcc "MacPorts: i386-elf-gcc"
  status_tool "Windows 64-bit cross" x86_64-w64-mingw32-gcc "MacPorts: x86_64-w64-mingw32-gcc"
  status_tool "Windows 32-bit cross" i686-w64-mingw32-gcc "MacPorts: i686-w64-mingw32-gcc"
  status_tool "MAME test/preservation emulator" mame "MacPorts: mame"
  status_tool "QEMU architecture emulator" qemu-system-aarch64 "MacPorts: qemu"

  status_dir "devkitPro root" "${DEVKITPRO:-/opt/devkitpro}" "Install official devkitPro pacman package"
  status_dir "Official Nintendo SDK root" "${SWITCH_SDK_DIR:-${NINTENDO_SDK_ROOT:-}}" "Set SWITCH_SDK_DIR or NINTENDO_SDK_ROOT if licensed/installed"
  status_dir "Official PlayStation/PS5 SDK root" "${PS5_SDK_DIR:-${PLAYSTATION_SDK_DIR:-}}" "Set PS5_SDK_DIR or PLAYSTATION_SDK_DIR if licensed/installed"
  status_dir "Microsoft Xbox/GDK root" "${XBOX_GDK_DIR:-${GameDKLatest:-${GXDKLatest:-}}}" "Install GDK on Windows/VM or set XBOX_GDK_DIR"

  printf '\nNotes:\n'
  printf -- '- PS5, commercial Nintendo Switch SDK, and Xbox console publishing SDKs are not public macOS packages. CatSDK only detects licensed installs.\n'
  printf -- '- devkitPro Switch support is for homebrew-style builds, not Nintendo commercial SDK replacement.\n'
  printf -- '- Generic CPU cross-compilers are not complete console SDKs; you still need platform headers, libraries, link scripts, and legal publishing access.\n'
}

list_targets() {
  cat <<'LISTEOF'
CatSDK target map:
  atari-6502      -> cc65/ca65/ld65
  commodore-6502  -> cc65/ca65/ld65
  nes-6502        -> cc65/ca65/ld65
  gameboy-z80     -> sdcc
  msx-z80         -> sdcc
  genesis-m68k    -> m68k-elf-gcc plus platform libs
  ps1-mips        -> mips-elf-gcc plus PS1 SDK/libs
  ps2-mips        -> mips-elf-gcc plus PS2 SDK/libs
  psp-mips        -> mips-elf-gcc plus PSP SDK/libs
  gba-arm         -> devkitARM or arm-none-eabi-gcc plus libgba
  nds-arm         -> devkitARM plus libnds
  3ds-arm         -> devkitARM plus libctru
  gamecube-ppc    -> devkitPPC plus libogc
  wii-ppc         -> devkitPPC plus libogc
  wiiu-ppc        -> devkitPPC plus wut/libogc ecosystem
  switch-aarch64  -> devkitA64/libnx for homebrew; official SDK requires Nintendo access
  xbox-gdk        -> Microsoft GDK on Windows/VM; detected via env root
  ps5-official    -> detected via env root; install only through PlayStation partner access
LISTEOF
}

case "${1:-doctor}" in
  doctor) doctor ;;
  list|targets) list_targets ;;
  env) printf '. "%s/env.sh"\n' "$CATSDK_HOME" ;;
  *) printf 'Usage: catsdk [doctor|list|targets|env]\n' >&2; exit 2 ;;
esac
CMDEOF
  chmod +x "$cmd"
  say "Installed CatSDK command: $cmd"
}

ensure_profile_source() {
  local line profile changed=0
  line='[ -f "$HOME/.catsdk/env.sh" ] && . "$HOME/.catsdk/env.sh"'
  for profile in "$HOME/.zprofile" "$HOME/.bash_profile"; do
    touch "$profile"
    if ! grep -Fq '.catsdk/env.sh' "$profile"; then
      printf '\n# CatSDK compiler paths\n%s\n' "$line" >> "$profile"
      changed=1
      say "Added CatSDK env source to $profile"
    fi
  done
  [[ "$changed" == "1" ]] && say "Open a new Terminal or run: . \"$CATSDK_HOME/env.sh\""
}

run_doctor_now() {
  if [[ -x "$CATSDK_BIN/catsdk" ]]; then
    PATH="$CATSDK_BIN:$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:$PATH" "$CATSDK_BIN/catsdk" doctor | tee -a "$CATSDK_LOG"
  fi
}

main() {
  require_not_root
  check_platform
  ensure_clt
  write_env_file
  install_catsdk_command
  ensure_profile_source

  if [[ "${DOCTOR_ONLY:-0}" == "1" ]]; then
    run_doctor_now
    exit 0
  fi

  install_macports_from_distfile
  ensure_macports_updated
  install_macports_compilers
  install_devkitpro_if_available
  write_env_file
  install_catsdk_command
  run_doctor_now

  say "Done. Log: $CATSDK_LOG"
  say "Next shell: open a new Terminal, or run: . \"$CATSDK_HOME/env.sh\""
}

main "$@"
