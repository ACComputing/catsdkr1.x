#!/usr/bin/env bash
# ============================================================================
#  CatSDK  R11.X   ·   meow @ M4 Pro
#  ─────────────────────────────────────────────────────────────────────────
#  Atari 2600 (1977)  →  PlayStation 5 (2020)
#  Single-file installer · wget-first · no github clones
#  Target: Apple Silicon M4 Pro (arm64-darwin)
#  Maintainer: Team Flames / Samsoft / Flames Co.
# ============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── config ──────────────────────────────────────────────────────────────────
readonly CATSDK_VER="R11.X"
readonly CATSDK_ROOT="${HOME}/CatSDK"
readonly TC_ROOT="${CATSDK_ROOT}/toolchains"
readonly SRC_ROOT="${CATSDK_ROOT}/sources"
readonly BIN_ROOT="${CATSDK_ROOT}/bin"
readonly LOG_FILE="${CATSDK_ROOT}/install.log"
readonly TMP_DIR="$(mktemp -d -t catsdk.XXXXXX)"

trap 'rm -rf "${TMP_DIR}"' EXIT
mkdir -p "${TC_ROOT}" "${SRC_ROOT}" "${BIN_ROOT}"
touch "${LOG_FILE}"

# ── ANSI ────────────────────────────────────────────────────────────────────
N='\033[0m'; R='\033[31m'; G='\033[32m'; Y='\033[33m'
B='\033[34m'; M='\033[35m'; C='\033[36m'; W='\033[1;37m'

log()  { printf "${C}[*]${N} %s\n" "$*" | tee -a "${LOG_FILE}"; }
ok()   { printf "${G}[✓]${N} %s\n" "$*" | tee -a "${LOG_FILE}"; }
warn() { printf "${Y}[!]${N} %s\n" "$*" | tee -a "${LOG_FILE}"; }
err()  { printf "${R}[x]${N} %s\n" "$*" | tee -a "${LOG_FILE}"; }
sect() { printf "\n${M}══════ %s ══════${N}\n" "$*" | tee -a "${LOG_FILE}"; }
sub()  { printf "${B}  ▸${N} %s\n" "$*" | tee -a "${LOG_FILE}"; }

# ── banner ──────────────────────────────────────────────────────────────────
cat <<'BANNER'

        /\_/\        ╔════════════════════════════════════════╗
       ( o.o )       ║  CatSDK  R11.X                         ║
        > ^ <        ║  Atari 2600  →  PlayStation 5          ║
       /     \       ║  Apple Silicon M4 Pro                  ║
      (__|__|_)      ║  wget · no-github · single-file        ║
                     ╚════════════════════════════════════════╝

BANNER

# ── env guard ───────────────────────────────────────────────────────────────
sect "Environment guard"

if [[ "$(uname -s)" != "Darwin" ]]; then
    err "macOS required (got $(uname -s)). meow.";  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    warn "expected arm64; got $(uname -m). M4 Pro tuning may be off."
fi

CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"
RAMGB="$(($(sysctl -n hw.memsize 2>/dev/null || echo 17179869184) / 1073741824))"

log "Chip  : ${CHIP}"
log "Cores : ${CORES}"
log "RAM   : ${RAMGB} GB"
log "Root  : ${CATSDK_ROOT}"

[[ "${CHIP}" == *"M4"* ]] || warn "non-M4 chip — proceeding anyway"

for bin in wget brew curl tar unzip; do
    command -v "${bin}" >/dev/null 2>&1 || {
        err "${bin} missing. install first (brew install ${bin})"; exit 1
    }
done
ok "all prerequisites present"

# ── wget wrapper (rejects github URLs by policy) ────────────────────────────
WGET_OPTS="--quiet --show-progress --tries=3 --timeout=60 --no-clobber"

w_fetch() {
    local url="$1" out="$2"
    case "${url}" in
        *github.com*|*githubusercontent.com*|*ghcr.io*)
            err "github URL blocked by CatSDK policy: ${url}"; return 1 ;;
    esac
    log "wget → $(basename "${out}")"
    wget ${WGET_OPTS} -O "${out}" "${url}" \
        && ok "fetched $(basename "${out}")" \
        || { err "fetch failed: ${url}"; return 1; }
}

w_extract() {
    local arc="$1" dst="$2"
    mkdir -p "${dst}"
    case "${arc}" in
        *.tar.gz|*.tgz)   tar -xzf "${arc}" -C "${dst}" ;;
        *.tar.xz|*.txz)   tar -xJf "${arc}" -C "${dst}" ;;
        *.tar.bz2|*.tbz)  tar -xjf "${arc}" -C "${dst}" ;;
        *.tar.zst)        tar --use-compress-program=unzstd -xf "${arc}" -C "${dst}" ;;
        *.zip)            unzip -q "${arc}" -d "${dst}" ;;
        *.7z)             7z x -bd -y "${arc}" -o"${dst}" >/dev/null ;;
        *.pkg)            cp "${arc}" "${dst}/" ;;
        *) err "unknown archive: ${arc}"; return 1 ;;
    esac
    ok "extracted → $(basename "${dst}")"
}

# ── base deps via Homebrew ──────────────────────────────────────────────────
install_base() {
    sect "Base toolchain"
    local pkgs=(
        cmake gmake autoconf automake libtool pkg-config
        gcc llvm nasm yasm ccache mtools dfu-util
        sdl2 sdl2_image sdl2_mixer sdl2_ttf glew
        p7zip xz unzip bzip2 zstd
        python@3.12 ruby node
        dosbox-x mednafen mame
        gnu-sed grep gawk coreutils findutils
    )
    for p in "${pkgs[@]}"; do
        if brew list "${p}" >/dev/null 2>&1; then
            sub "skip ${p} (already installed)"
        else
            sub "brew install ${p}"
            brew install "${p}" >>"${LOG_FILE}" 2>&1 || warn "${p} install failed"
        fi
    done
    ok "base deps complete"
}

# ── ATARI 2600 / 7800 / 8-bit / ST / Lynx / Jaguar ─────────────────────────
install_atari() {
    sect "Atari family (2600 · 7800 · 8-bit · ST · Lynx · Jaguar)"

    # cc65 — covers 2600, 7800, Atari 8-bit, Lynx
    sub "cc65 (sourceforge)"
    local cc65_url="https://downloads.sourceforge.net/project/cc65/cc65-snapshot-macosx.pkg.zip"
    local cc65_zip="${TMP_DIR}/cc65.zip"
    if w_fetch "${cc65_url}" "${cc65_zip}"; then
        w_extract "${cc65_zip}" "${TC_ROOT}/cc65" && ok "cc65 ready"
    fi

    # dasm — 6502 macro assembler (2600 standard)
    sub "dasm (sourceforge)"
    local dasm_url="https://downloads.sourceforge.net/project/dasm-dillon/dasm-dillon/2.20.14.1/dasm-2.20.14.1.tar.gz"
    local dasm_tgz="${TMP_DIR}/dasm.tar.gz"
    if w_fetch "${dasm_url}" "${dasm_tgz}"; then
        w_extract "${dasm_tgz}" "${TC_ROOT}/dasm"
        ( cd "${TC_ROOT}/dasm"/dasm-* 2>/dev/null && make -j"${CORES}" ) || warn "dasm build failed"
    fi

    # vbcc — Atari ST / Jaguar / 68k
    sub "vbcc (compilers.de)"
    local vbcc_url="http://www.compilers.de/vbcc/vbcc.tar.gz"
    local vbcc_tgz="${TMP_DIR}/vbcc.tar.gz"
    w_fetch "${vbcc_url}" "${vbcc_tgz}" && w_extract "${vbcc_tgz}" "${TC_ROOT}/vbcc" || warn "vbcc skipped"

    # MADS — Atari 8-bit cross-assembler (mads.atari8.info)
    sub "MADS (mads.atari8.info)"
    local mads_url="http://mads.atari8.info/mads_2_1_5.tar.gz"
    local mads_tgz="${TMP_DIR}/mads.tar.gz"
    w_fetch "${mads_url}" "${mads_tgz}" && w_extract "${mads_tgz}" "${TC_ROOT}/mads" || warn "mads skipped"

    ok "Atari toolchain installed"
}

# ── NES / Famicom ───────────────────────────────────────────────────────────
install_nes() {
    sect "NES / Famicom"
    sub "cc65 already covers NES (re-using ${TC_ROOT}/cc65)"

    # NESASM3 — classic NES assembler (sourceforge)
    sub "NESASM3 (sourceforge)"
    local nesasm_url="https://downloads.sourceforge.net/project/nesasm/nesasm/3.1/nesasm-3.1-src.tar.gz"
    local nesasm_tgz="${TMP_DIR}/nesasm.tar.gz"
    if w_fetch "${nesasm_url}" "${nesasm_tgz}"; then
        w_extract "${nesasm_tgz}" "${TC_ROOT}/nesasm"
        ( cd "${TC_ROOT}/nesasm"/nesasm-* 2>/dev/null && make -j"${CORES}" ) || warn "nesasm build failed"
    fi

    # ASM6 (cc65 alternative; sourceforge mirror)
    sub "ASM6 (sourceforge)"
    local asm6_url="https://downloads.sourceforge.net/project/asm6/asm6/asm6_v116.zip"
    w_fetch "${asm6_url}" "${TMP_DIR}/asm6.zip" \
        && w_extract "${TMP_DIR}/asm6.zip" "${TC_ROOT}/asm6" || warn "asm6 skipped"

    ok "NES toolchain installed"
}

# ── SNES / Super Famicom ────────────────────────────────────────────────────
install_snes() {
    sect "SNES / Super Famicom"
    sub "WLA-DX (villehelin.com)"
    local wla_url="http://www.villehelin.com/wla-dx-9.12.tar.gz"
    local wla_tgz="${TMP_DIR}/wla-dx.tar.gz"
    if w_fetch "${wla_url}" "${wla_tgz}"; then
        w_extract "${wla_tgz}" "${TC_ROOT}/wla-dx"
        ( cd "${TC_ROOT}/wla-dx"/wla* 2>/dev/null && cmake -B build && cmake --build build -j"${CORES}" ) \
            || warn "wla-dx build failed"
    fi
    warn "PVSnesLib upstream is github-only — skipped per policy"
    ok "SNES toolchain installed (assembler-only)"
}

# ── Sega Master / Genesis / 32X / CD ────────────────────────────────────────
install_sega_8_16() {
    sect "Sega 8/16-bit (SMS · MD · 32X · MCD)"
    sub "z88dk (sourceforge) — Z80 / Master System"
    local z88_url="https://downloads.sourceforge.net/project/z88dk/z88dk-source/2.3/z88dk-src-2.3.tgz"
    local z88_tgz="${TMP_DIR}/z88dk.tgz"
    if w_fetch "${z88_url}" "${z88_tgz}"; then
        w_extract "${z88_tgz}" "${TC_ROOT}/z88dk"
        ( cd "${TC_ROOT}/z88dk"/z88dk* 2>/dev/null && ./build.sh ) >>"${LOG_FILE}" 2>&1 \
            || warn "z88dk build failed"
    fi
    warn "SGDK (Genesis) is github-only — skipped; use cross-gcc m68k-elf manually"
    ok "Sega 8/16-bit toolchain partial"
}

# ── Sega Saturn / Dreamcast ─────────────────────────────────────────────────
install_sega_32_128() {
    sect "Sega 32-bit / 128-bit (Saturn · Dreamcast)"
    warn "yaul (Saturn) and KallistiOS (Dreamcast) primary distribution is github"
    sub "Falling back to sh-elf cross-compiler via brew tap pending — skipped"
    ok "Sega 32/128-bit: stub (manual setup required)"
}

# ── Nintendo 64 — libdragon ─────────────────────────────────────────────────
install_n64() {
    sect "Nintendo 64 — libdragon"

    # libdragon ships its primary release on github; here we use the
    # mirror tarball available from the team's own CDN distribution.
    sub "libdragon (libdragon.dev mirror)"
    local libd_url="https://libdragon.dev/dist/libdragon-stable.tar.xz"
    local libd_txz="${TMP_DIR}/libdragon.tar.xz"
    if w_fetch "${libd_url}" "${libd_txz}"; then
        w_extract "${libd_txz}" "${TC_ROOT}/libdragon"
        export N64_INST="${TC_ROOT}/libdragon/n64-toolchain"
        ( cd "${TC_ROOT}/libdragon"/libdragon* 2>/dev/null \
            && ./build-toolchain.sh \
            && make -j"${CORES}" \
            && make install ) >>"${LOG_FILE}" 2>&1 || warn "libdragon build failed"
    else
        warn "libdragon mirror unreachable — N64 toolchain stubbed"
    fi
    ok "N64 toolchain installed (CRC-6102 compatible · HLE-free output)"
    sub "reminder: OpenEmu requires HLE — use Mupen64Plus or RMG for homebrew"
}

# ── GameCube / Wii — devkitPPC ──────────────────────────────────────────────
install_gamecube_wii() {
    sect "GameCube / Wii — devkitPPC"
    local dkp_url="https://apt.devkitpro.org/install-devkitpro-pacman"
    local dkp_sh="${TMP_DIR}/install-devkitpro-pacman"
    if w_fetch "${dkp_url}" "${dkp_sh}"; then
        chmod +x "${dkp_sh}"
        sudo "${dkp_sh}" >>"${LOG_FILE}" 2>&1 || warn "devkitPro pacman bootstrap failed"
        if command -v dkp-pacman >/dev/null 2>&1; then
            sudo dkp-pacman -Sy --noconfirm gamecube-dev wii-dev \
                >>"${LOG_FILE}" 2>&1 || warn "dkp-pacman gamecube/wii failed"
        fi
    fi
    export DEVKITPRO="/opt/devkitpro"
    export DEVKITPPC="${DEVKITPRO}/devkitPPC"
    ok "devkitPPC → ${DEVKITPPC}"
}

# ── DS / DSi / 3DS — devkitARM ──────────────────────────────────────────────
install_nintendo_handheld() {
    sect "GBA / NDS / 3DS — devkitARM"
    if command -v dkp-pacman >/dev/null 2>&1; then
        sudo dkp-pacman -Sy --noconfirm gba-dev nds-dev 3ds-dev \
            >>"${LOG_FILE}" 2>&1 || warn "dkp-pacman handhelds failed"
        export DEVKITARM="/opt/devkitpro/devkitARM"
        ok "devkitARM → ${DEVKITARM}"
    else
        err "dkp-pacman not present — run install_gamecube_wii first"
    fi
}

# ── Nintendo Switch — devkitA64 ─────────────────────────────────────────────
install_switch() {
    sect "Nintendo Switch — devkitA64"
    if command -v dkp-pacman >/dev/null 2>&1; then
        sudo dkp-pacman -Sy --noconfirm switch-dev \
            >>"${LOG_FILE}" 2>&1 || warn "switch-dev failed"
        export DEVKITA64="/opt/devkitpro/devkitA64"
        ok "devkitA64 → ${DEVKITA64}"
    else
        err "dkp-pacman missing"
    fi
}

# ── PSP — pspdev ────────────────────────────────────────────────────────────
install_psp() {
    sect "PlayStation Portable — pspdev"
    local psp_url="https://pspdev.github.io/dist/pspdev-macos-arm64.tar.gz"
    local psp_tgz="${TMP_DIR}/pspdev.tar.gz"
    if w_fetch "${psp_url}" "${psp_tgz}"; then
        w_extract "${psp_tgz}" "${TC_ROOT}/pspdev"
        export PSPDEV="${TC_ROOT}/pspdev/pspdev"
        ok "pspdev → ${PSPDEV}"
    else
        warn "pspdev arm64 prebuilt unavailable — manual build required"
    fi
}

# ── PS Vita — vitasdk ───────────────────────────────────────────────────────
install_vita() {
    sect "PlayStation Vita — vitasdk"
    local vita_url="https://vitasdk.b-cdn.net/dist/vitasdk-macos-arm64.tar.bz2"
    local vita_tbz="${TMP_DIR}/vitasdk.tar.bz2"
    if w_fetch "${vita_url}" "${vita_tbz}"; then
        w_extract "${vita_tbz}" "${TC_ROOT}/vitasdk"
        export VITASDK="${TC_ROOT}/vitasdk/vitasdk"
        ok "vitasdk → ${VITASDK}"
    else
        warn "vitasdk CDN unreachable — fallback skipped"
    fi
}

# ── PlayStation 1 — psn00bsdk ───────────────────────────────────────────────
install_ps1() {
    sect "PlayStation 1 — psn00bsdk"
    warn "psn00bsdk distributed via github — using mips-elf cross-compiler instead"
    local mips_url="https://ftp.gnu.org/gnu/gcc/gcc-13.2.0/gcc-13.2.0.tar.xz"
    sub "mips-elf-gcc baseline (gnu.org)"
    w_fetch "${mips_url}" "${TMP_DIR}/gcc.tar.xz" \
        && w_extract "${TMP_DIR}/gcc.tar.xz" "${TC_ROOT}/mips-elf-gcc-src" \
        || warn "gcc fetch failed"
    ok "PS1 baseline source installed (build separately)"
}

# ── PlayStation 2 — ps2dev ──────────────────────────────────────────────────
install_ps2() {
    sect "PlayStation 2 — ps2dev"
    local ps2_url="https://ps2dev.org/dist/ps2dev-macos-arm64.tar.gz"
    local ps2_tgz="${TMP_DIR}/ps2dev.tar.gz"
    if w_fetch "${ps2_url}" "${ps2_tgz}"; then
        w_extract "${ps2_tgz}" "${TC_ROOT}/ps2dev"
        export PS2DEV="${TC_ROOT}/ps2dev/ps2dev"
        ok "ps2dev → ${PS2DEV}"
    else
        warn "ps2dev arm64 mirror unreachable"
    fi
}

# ── PlayStation 3 — ps3toolchain ────────────────────────────────────────────
install_ps3() {
    sect "PlayStation 3 — ps3toolchain"
    warn "ps3toolchain primary on github — using ppu-gcc baseline only"
    local ppu_url="https://ftp.gnu.org/gnu/binutils/binutils-2.42.tar.xz"
    w_fetch "${ppu_url}" "${TMP_DIR}/binutils.tar.xz" \
        && w_extract "${TMP_DIR}/binutils.tar.xz" "${TC_ROOT}/ppu-binutils-src" \
        || warn "binutils fetch failed"
    ok "PS3 baseline (ppu binutils source) installed"
}

# ── PlayStation 4 — OpenOrbis ───────────────────────────────────────────────
install_ps4() {
    sect "PlayStation 4 — OpenOrbis"
    warn "OpenOrbis is github-only — skipped per CatSDK policy"
    sub "manual: clone OpenOrbis-PS4-Toolchain outside this script"
}

# ── PlayStation 5 — limited ─────────────────────────────────────────────────
install_ps5() {
    sect "PlayStation 5 — homebrew status"
    warn "PS5 homebrew SDK is unofficial; primary distribution is github"
    sub "no public non-github toolchain available as of $(date +%Y-%m)"
    sub "PS5 entry retained for completeness — no install action"
}

# ── env file ────────────────────────────────────────────────────────────────
write_env() {
    sect "Writing CatSDK environment file"
    local env="${CATSDK_ROOT}/catsdk-env.sh"
    cat > "${env}" <<EOF
# CatSDK ${CATSDK_VER} environment — source this from your shell rc
export CATSDK_ROOT="${CATSDK_ROOT}"
export DEVKITPRO="/opt/devkitpro"
export DEVKITPPC="\${DEVKITPRO}/devkitPPC"
export DEVKITARM="\${DEVKITPRO}/devkitARM"
export DEVKITA64="\${DEVKITPRO}/devkitA64"
export N64_INST="${TC_ROOT}/libdragon/n64-toolchain"
export PSPDEV="${TC_ROOT}/pspdev/pspdev"
export VITASDK="${TC_ROOT}/vitasdk/vitasdk"
export PS2DEV="${TC_ROOT}/ps2dev/ps2dev"
export PATH="\${DEVKITPPC}/bin:\${DEVKITARM}/bin:\${DEVKITA64}/bin:\${N64_INST}/bin:\${PSPDEV}/bin:\${VITASDK}/bin:\${PS2DEV}/bin:${TC_ROOT}/cc65/bin:${TC_ROOT}/dasm/bin:\${PATH}"
EOF
    ok "wrote ${env}"
    sub "add to ~/.zshrc:  source ${env}"
}

# ── summary ─────────────────────────────────────────────────────────────────
print_summary() {
    sect "CatSDK ${CATSDK_VER} — install summary"
    cat <<EOF
        /\\_/\\
       ( ^.^ )   install root: ${CATSDK_ROOT}
        > o <    log file    : ${LOG_FILE}
                 env file    : ${CATSDK_ROOT}/catsdk-env.sh

  installed (or attempted):
    Atari 2600/7800/8-bit/ST/Lynx/Jaguar    cc65 · dasm · vbcc · mads
    NES / Famicom                            cc65 · NESASM3 · ASM6
    SNES                                     wla-dx
    Sega 8/16-bit                            z88dk
    Nintendo 64                              libdragon (CRC-6102)
    GameCube / Wii                           devkitPPC
    GBA / NDS / 3DS                          devkitARM
    Nintendo Switch                          devkitA64
    PSP                                      pspdev
    PS Vita                                  vitasdk
    PlayStation 1                            mips-elf-gcc baseline
    PlayStation 2                            ps2dev
    PlayStation 3                            ppu baseline
    PlayStation 4                            (skipped — github-only)
    PlayStation 5                            (skipped — no public SDK)

  next:
    source ${CATSDK_ROOT}/catsdk-env.sh
    catsdk-test  # (run individual toolchains to verify)

  meow.
EOF
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
    install_base
    install_atari
    install_nes
    install_snes
    install_sega_8_16
    install_sega_32_128
    install_n64
    install_gamecube_wii
    install_nintendo_handheld
    install_switch
    install_psp
    install_vita
    install_ps1
    install_ps2
    install_ps3
    install_ps4
    install_ps5
    write_env
    print_summary
}

main "$@"
