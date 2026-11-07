#!/usr/bin/env bash
#
# gpupt — GPU passthrough helper for Proxmox VE (Intel & AMD hosts)
#
#   gpupt list                     GPUs, IOMMU groups, bound drivers
#   gpupt check [node|vm <vmid>]   verify the configuration (exit 1 on failures)
#   gpupt configure node           fix host config (cmdline, vfio, initramfs, bootloader)
#   gpupt configure vm <vmid>      fix VM config (OVMF, q35, EFI disk, hostpci, ...)
#   gpupt backups                  list rollback points
#   gpupt rollback [id|last|all]   undo changes made by gpupt
#   gpupt report                   diagnostic dump (handy for forum posts)
#
set -uo pipefail

VERSION="1.0.0"
PROG="gpupt"
STATE_DIR="${GPUPT_STATE_DIR:-/var/lib/gpupt}"
BACKUP_DIR="$STATE_DIR/backups"
ROLLED_DIR="$STATE_DIR/rolled-back"
STATE_FILE="$STATE_DIR/state"
LOG_FILE="${GPUPT_LOG:-/var/log/gpupt.log}"
PVE_QEMU_DIR="/etc/pve/qemu-server"

# Files owned by this tool (kept separate from any hand-made config so rollback is clean)
F_MODLOAD="/etc/modules-load.d/gpupt-vfio.conf"
F_VFIO="/etc/modprobe.d/gpupt-vfio.conf"
F_BLACKLIST="/etc/modprobe.d/gpupt-blacklist.conf"
F_KVM="/etc/modprobe.d/gpupt-kvm.conf"
F_UNSAFE="/etc/modprobe.d/gpupt-unsafe-interrupts.conf"

# ---------------------------------------------------------------- options
ASSUME_YES=0
DRY_RUN=0
GPU_ARG=""
XVGA=""
EFI_STORAGE=""
SECURE_BOOT=0
UNSAFE_INT=0
IGNORE_MSRS=""
QUIET=0
R="" G="" Y="" B="" C="" D="" N="" BOLD=""

setup_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; C=$'\e[36m'
    D=$'\e[2m'; N=$'\e[0m'; BOLD=$'\e[1m'
  fi
}

# ---------------------------------------------------------------- output helpers
die()     { printf '%s\n' "${R}ERROR:${N} $*" >&2; exit 1; }
info()    { printf '%s\n' "${B}==>${N} $*"; }
ok()      { printf '%s\n' "${G}✔${N} $*"; }
warn()    { printf '%s\n' "${Y}▲${N} $*"; }
section() { [[ $QUIET -eq 1 ]] || printf '\n%s\n' "${BOLD}$*${N}"; }
log()     { [[ $DRY_RUN -eq 1 ]] && return 0; mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null; return 0; }

P=0; W=0; F=0
c_ok()   { P=$((P+1)); [[ $QUIET -eq 1 ]] || printf '  %s %s\n' "${G}✔${N}" "$*"; return 0; }
c_warn() { W=$((W+1)); [[ $QUIET -eq 1 ]] || printf '  %s %s\n' "${Y}▲${N}" "$*"; return 0; }
c_fail() { F=$((F+1)); printf '  %s %s\n' "${R}✘${N}" "$*"; return 0; }
c_info() { [[ $QUIET -eq 1 ]] || printf '  %s %s\n' "${B}i${N}" "$*"; return 0; }
c_hint() { [[ $QUIET -eq 1 ]] || printf '    %s\n' "${D}→ $*${N}"; return 0; }

color_diff() {
  local l
  while IFS= read -r l; do
    case "$l" in
      ---*|+++*) printf '%s\n' "${BOLD}$l${N}";;
      @@*)       printf '%s\n' "${C}$l${N}";;
      +*)        printf '%s\n' "${G}$l${N}";;
      -*)        printf '%s\n' "${R}$l${N}";;
      *)         printf '%s\n' "$l";;
    esac
  done
}

# ---------------------------------------------------------------- prompts
# confirm: honours --yes and --dry-run
confirm() {
  local prompt="$1" ans
  if [[ $DRY_RUN -eq 1 ]]; then printf '%s\n' "${D}[dry-run] would ask: $prompt — nothing is changed${N}"; return 1; fi
  if [[ $ASSUME_YES -eq 1 ]]; then printf '%s %s\n' "${Y}?${N} $prompt" "${D}[auto-yes]${N}"; return 0; fi
  [[ -t 0 ]] || die "Confirmation needed but stdin is not a TTY (use --yes to auto-approve)."
  while true; do
    read -r -p "${Y}?${N} $prompt [y/N] " ans
    case "${ans,,}" in y|yes) return 0;; n|no|"") return 1;; esac
  done
}

# ask_always: never auto-approved by --yes (used for risky decisions)
ask_always() {
  local prompt="$1" ans
  if [[ $DRY_RUN -eq 1 ]]; then printf '%s\n' "${D}[dry-run] would ask: $prompt${N}"; return 1; fi
  [[ -t 0 ]] || return 1
  read -r -p "${Y}?${N} $prompt [y/N] " ans
  [[ "${ans,,}" == y || "${ans,,}" == yes ]]
}

# ---------------------------------------------------------------- environment detection
CPU=""; CPU_NAME=""; BOOTLOADER=""; CMDLINE_FILE=""
GPU_SLOT=""; FB_RELEASE=0

require_root() { [[ $EUID -eq 0 ]] || die "Run as root."; }
require_qm()   { command -v qm >/dev/null 2>&1 || die "Proxmox VE tools (qm) not found — VM commands must run on a PVE node."; }

detect_cpu() {
  local v
  v=$(grep -m1 -E '^vendor_id' /proc/cpuinfo | awk '{print $3}')
  case "$v" in
    GenuineIntel) CPU=intel;;
    AuthenticAMD) CPU=amd;;
    *) die "Unsupported CPU vendor: '$v'";;
  esac
  CPU_NAME=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')
}

detect_bootloader() {
  BOOTLOADER=grub
  if command -v proxmox-boot-tool >/dev/null 2>&1 && [[ -e /etc/kernel/proxmox-boot-uuids ]] \
     && proxmox-boot-tool status 2>/dev/null | grep -q 'configured with: uefi'; then
    BOOTLOADER=systemd-boot
  fi
  if [[ $BOOTLOADER == grub ]]; then CMDLINE_FILE=/etc/default/grub; else CMDLINE_FILE=/etc/kernel/cmdline; fi
}

# ---------------------------------------------------------------- PCI helpers
list_gpus() { lspci -Dnn 2>/dev/null | grep -E '\[(0300|0302|0380)\]'; }

norm_slot() {  # 01:00 / 01:00.0 / 0000:01:00.0  ->  0000:01:00
  local a="${1,,}"
  a="${a%.[0-7]}"
  [[ $a =~ ^[0-9a-f]{2}:[0-9a-f]{2}$ ]] && a="0000:$a"
  printf '%s' "$a"
}

pci_id() { local v d; v=$(<"/sys/bus/pci/devices/$1/vendor"); d=$(<"/sys/bus/pci/devices/$1/device"); printf '%s:%s' "${v#0x}" "${d#0x}"; }

slot_funcs() { local f; for f in /sys/bus/pci/devices/"$1".*; do [[ -e $f ]] && basename "$f"; done; }

gpu_ids() {  # comma separated vendor:device list for every function of the selected slot
  local f
  for f in $(slot_funcs "$GPU_SLOT"); do pci_id "$f"; echo; done | sort -u | paste -sd, -
}

gpu_name()   { lspci -Dnn -s "${1}.0" 2>/dev/null | cut -d' ' -f2-; }
gpu_vendor() { local v; v=$(<"/sys/bus/pci/devices/${1}.0/vendor"); printf '%s' "${v#0x}"; }
gpu_is_boot(){ [[ -r /sys/bus/pci/devices/${1}.0/boot_vga && "$(<"/sys/bus/pci/devices/${1}.0/boot_vga")" == 1 ]]; }
gpu_group()  { local g="/sys/bus/pci/devices/${1}.0/iommu_group"; [[ -e $g ]] && basename "$(readlink -f "$g")"; }
dev_driver() { local d="/sys/bus/pci/devices/$1/driver"; [[ -e $d ]] && basename "$(readlink -f "$d")" || echo none; }

group_foreign() {  # non-bridge devices sharing the IOMMU group with slot $1 (other slots only)
  local g="/sys/bus/pci/devices/${1}.0/iommu_group/devices" d a cls
  [[ -d $g ]] || return 0
  for d in "$g"/*; do
    a=$(basename "$d")
    [[ ${a%.*} == "$1" ]] && continue
    cls=$(<"$d/class")
    [[ $cls == 0x0604* || $cls == 0x0600* ]] && continue
    printf '%s|%s\n' "$a" "$(lspci -Dnn -s "$a" | cut -d' ' -f2-)"
  done
}

gpu_slots() { list_gpus | awk '{print $1}' | sed 's/\.[0-7]$//' | sort -u; }

select_gpu() {  # $1 = interactive | soft
  local mode="${1:-interactive}" cand=() s i ans
  if [[ -n $GPU_ARG ]]; then
    GPU_SLOT=$(norm_slot "$GPU_ARG")
  elif [[ -r $STATE_FILE ]] && GPU_SLOT=$(sed -n 's/^GPU_SLOT=//p' "$STATE_FILE") && [[ -n $GPU_SLOT ]]; then
    :
  else
    mapfile -t cand < <(gpu_slots)
    case ${#cand[@]} in
      0) [[ $mode == soft ]] && return 1; die "No GPU found (lspci shows no VGA/3D/Display device).";;
      1) GPU_SLOT="${cand[0]}";;
      *)
        [[ $mode == soft ]] && return 1
        [[ -t 0 && $ASSUME_YES -eq 0 ]] || die "Multiple GPUs found — choose one with --gpu <addr> (see: $PROG list)."
        echo "Multiple GPUs found:"
        i=1; for s in "${cand[@]}"; do printf '  %d) %s  %s\n' "$i" "$s" "$(gpu_name "$s")"; i=$((i+1)); done
        read -r -p "Select the GPU to pass through [1-${#cand[@]}]: " ans
        [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#cand[@]} )) || die "Invalid selection."
        GPU_SLOT="${cand[$((ans-1))]}";;
    esac
  fi
  [[ -e /sys/bus/pci/devices/${GPU_SLOT}.0 ]] || { [[ $mode == soft ]] && return 1; die "PCI device ${GPU_SLOT}.0 does not exist."; }
  return 0
}

save_state() { [[ $DRY_RUN -eq 1 ]] && return 0; mkdir -p "$STATE_DIR"; printf 'GPU_SLOT=%s\n' "$GPU_SLOT" >"$STATE_FILE"; }

banner() {
  echo
  info "CPU:        $CPU_NAME  → ${BOLD}$CPU${N}"
  info "Bootloader: ${BOLD}$BOOTLOADER${N}  (cmdline file: $CMDLINE_FILE)"
  if [[ -n $GPU_SLOT ]]; then
    info "GPU:        ${BOLD}$(gpu_name "$GPU_SLOT")${N}"
    info "            slot $GPU_SLOT  ids $(gpu_ids)  driver $(dev_driver "${GPU_SLOT}.0")  IOMMU group $(gpu_group "$GPU_SLOT" || echo '?')$(gpu_is_boot "$GPU_SLOT" && echo '  [HOST BOOT GPU]')"
  fi
}

# ---------------------------------------------------------------- kernel cmdline logic
wanted_tokens() {
  local -a want_list=()
  [[ $CPU == intel ]] && want_list+=(intel_iommu=on)
  want_list+=(iommu=pt)
  if [[ $FB_RELEASE -eq 1 ]]; then want_list+=(video=efifb:off video=vesafb:off video=simplefb:off initcall_blacklist=sysfb_init); fi
  echo "${want_list[*]}"
}

cmdline_current() {
  if [[ $BOOTLOADER == grub ]]; then
    [[ -r /etc/default/grub ]] && grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | tail -1 \
      | sed -E "s/^[^=]+=//; s/^[\"']//; s/[\"']\$//"
  else
    [[ -r /etc/kernel/cmdline ]] && tr '\n' ' ' </etc/kernel/cmdline | sed 's/ *$//'
  fi
  return 0
}

# cmdline_merge "<current>" tok1 tok2 ...  -> new cmdline (existing tokens keep their order)
cmdline_merge() {
  local cur="$1"; shift
  local -a out=() toks=() keep=()
  local tok key w present
  read -ra toks <<<"$cur"
  out=("${toks[@]}")
  for w in "$@"; do
    present=0
    for tok in "${out[@]}"; do [[ $tok == "$w" ]] && present=1; done
    (( present )) && continue
    if [[ $w != video=* && $w != initcall_blacklist=* ]]; then
      key="${w%%=*}"; keep=()
      for tok in "${out[@]}"; do [[ $tok == "$key" || $tok == "$key="* ]] || keep+=("$tok"); done
      out=("${keep[@]}")
    fi
    out+=("$w")
  done
  echo "${out[*]}"
}

build_cmdline_file() {  # $1 = output path
  local cur new
  cur="$(cmdline_current)"
  read -ra want <<<"$(wanted_tokens)"
  new="$(cmdline_merge "$cur" "${want[@]}")"
  if [[ $BOOTLOADER == grub ]]; then
    [[ -r /etc/default/grub ]] || die "/etc/default/grub not found."
    awk -v new="$new" '
      /^GRUB_CMDLINE_LINUX_DEFAULT=/ { if (!done) { print "GRUB_CMDLINE_LINUX_DEFAULT=\"" new "\""; done=1 } ; next }
      { print }
      END { if (!done) print "GRUB_CMDLINE_LINUX_DEFAULT=\"" new "\"" }' /etc/default/grub >"$1"
  else
    printf '%s\n' "$new" >"$1"
  fi
}

# ---------------------------------------------------------------- transactions / rollback points
TXN_ID=""; TXN_DIR=""
enc() { printf '%s' "$1" | sed 's#/#%#g'; }

txn_begin() {  # $1 label, $2 description
  TXN_ID="$(date +%Y%m%d-%H%M%S)-$1"; TXN_DIR="$BACKUP_DIR/$TXN_ID"
  [[ $DRY_RUN -eq 1 ]] && return 0
  mkdir -p "$TXN_DIR/files"; : >"$TXN_DIR/manifest"; printf '%s\n' "$2" >"$TXN_DIR/description"
}
txn_backup_file() {
  local f="$1"
  [[ $DRY_RUN -eq 1 ]] && return 0
  grep -qF "FILE|$f|" "$TXN_DIR/manifest" && return 0
  if [[ -e $f ]]; then cp -a -- "$f" "$TXN_DIR/files/$(enc "$f")"; echo "FILE|$f|1" >>"$TXN_DIR/manifest"
  else echo "FILE|$f|0" >>"$TXN_DIR/manifest"; fi
}
txn_note() { [[ $DRY_RUN -eq 1 ]] && return 0; grep -qxF "$1" "$TXN_DIR/manifest" || echo "$1" >>"$TXN_DIR/manifest"; }
txn_end() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  if [[ -s $TXN_DIR/manifest ]]; then
    echo; info "Rollback point saved: ${BOLD}$TXN_ID${N}   (undo with: $PROG rollback $TXN_ID)"
  else
    rm -rf "$TXN_DIR"
  fi
}

# ---------------------------------------------------------------- show before/after & apply files
print_block() {  # label colour file
  local label="$1" col="$2" f="$3" l
  printf '%s\n' "${col}${label}${N}"
  if [[ -e $f ]]; then
    if [[ -s $f ]]; then while IFS= read -r l; do printf '%s\n' "${col}    $l${N}"; done <"$f"
    else echo "    (empty file)"; fi
  else echo "    (file does not exist)"; fi
}

show_change() {  # $1 current path (BEFORE) $2 new content file (AFTER)
  local t="$1" n="$2" total src="$1"
  echo; echo "${BOLD}━━ $t ━━${N}"
  total=$(wc -l <"$n"); [[ -e $t ]] && total=$(( total + $(wc -l <"$t") ))
  if (( total <= 60 )); then
    print_block "BEFORE:" "$R" "$t"
    print_block "AFTER:"  "$G" "$n"
  else
    echo "${D}(large file — showing unified diff)${N}"
    [[ -e $t ]] || src=/dev/null
    diff -u --label "BEFORE: $t" --label "AFTER:  $t" "$src" "$n" | color_diff
  fi
}

CHG_BOOT=0; CHG_MOD=0
# apply_file path newfile -> 0 applied, 1 declined, 2 already correct
apply_file() {
  local t="$1" n="$2" mode
  if [[ -e $t ]] && cmp -s "$t" "$n"; then ok "$t is already correct"; return 2; fi
  show_change "$t" "$n"
  if ! confirm "Write these changes to $t?"; then warn "Skipped $t"; return 1; fi
  txn_backup_file "$t"
  mode=$(stat -c %a "$t" 2>/dev/null || echo 644)
  mkdir -p "$(dirname "$t")"
  install -m "$mode" "$n" "$t" || die "Could not write $t"
  log "wrote $t (txn $TXN_ID)"
  ok "Updated $t"
  return 0
}

# ---------------------------------------------------------------- post-change hooks (all ask first)
hook_initramfs() {
  echo
  echo "${BOLD}update-initramfs -u -k all${N} will:"
  echo "  • rebuild the initramfs of every installed kernel (takes ~1 min per kernel)"
  echo "  • embed the vfio modules and the modprobe options written above, so vfio-pci"
  echo "    claims the GPU before any host GPU driver can load"
  echo "  • not change anything at runtime — effective after the next reboot"
  if confirm "Run update-initramfs now?"; then
    log "RUN update-initramfs -u -k all"
    update-initramfs -u -k all && ok "initramfs rebuilt" || warn "update-initramfs reported errors"
  else warn "Skipped. Run it yourself: update-initramfs -u -k all"; fi
}

hook_grub() {
  local pv
  echo
  echo "${BOLD}update-grub${N} will:"
  echo "  • read /etc/default/grub  (GRUB_CMDLINE_LINUX_DEFAULT=\"$(cmdline_current)\")"
  echo "  • regenerate /boot/grub/grub.cfg so that every kernel entry uses that command line"
  echo "  • not change anything at runtime — effective after the next reboot"
  if command -v grub-mkconfig >/dev/null 2>&1 && [[ -r /boot/grub/grub.cfg ]]; then
    pv=$(grub-mkconfig 2>/dev/null | diff -u /boot/grub/grub.cfg - 2>/dev/null)
    if [[ -z $pv ]]; then ok "/boot/grub/grub.cfg is already up to date — nothing for update-grub to change"; return 0; fi
    echo "Preview of the changes to /boot/grub/grub.cfg (first 40 lines):"
    printf '%s\n' "$pv" | head -n 40 | color_diff
  fi
  if confirm "Run update-grub now?"; then
    log "RUN update-grub"
    update-grub && ok "grub.cfg regenerated" || warn "update-grub reported errors"
  else warn "Skipped. Run it yourself: update-grub"; fi
}

hook_bootrefresh() {
  echo
  echo "${BOLD}proxmox-boot-tool refresh${N} will:"
  echo "  • read /etc/kernel/cmdline  (\"$(cmdline_current)\")"
  echo "  • copy kernels + initrds to every configured ESP and rewrite the systemd-boot entries"
  echo "    so each entry uses that command line"
  echo "  • not change anything at runtime — effective after the next reboot"
  if confirm "Run proxmox-boot-tool refresh now?"; then
    log "RUN proxmox-boot-tool refresh"
    proxmox-boot-tool refresh && ok "boot entries refreshed" || warn "proxmox-boot-tool reported errors"
  else warn "Skipped. Run it yourself: proxmox-boot-tool refresh"; fi
}

hook_boot() { if [[ $BOOTLOADER == grub ]]; then hook_grub; else hook_bootrefresh; fi; }

offer_reboot() {
  echo
  warn "A reboot is required for the node changes to take effect."
  if ask_always "Reboot now?"; then log "RUN reboot"; systemctl reboot; fi
}

# ---------------------------------------------------------------- list
cmd_list() {
  local s a g any=0
  while read -r s; do
    [[ -z $s ]] && continue
    any=1
    echo
    echo "${BOLD}$s${N}  $(gpu_name "$s")$(gpu_is_boot "$s" && echo "  ${Y}[host boot GPU]${N}")"
    for a in $(slot_funcs "$s"); do
      printf '    %s  id %s  driver: %s\n' "$a" "$(pci_id "$a")" "$(dev_driver "$a")"
    done
    g=$(gpu_group "$s" || true)
    if [[ -n $g ]]; then
      echo "    IOMMU group $g"
      group_foreign "$s" | while IFS='|' read -r a d; do echo "      ${Y}shares group with${N} $a $d"; done
    else
      echo "    IOMMU group: ${R}none (IOMMU inactive)${N}"
    fi
  done < <(gpu_slots)
  [[ $any -eq 1 ]] || echo "No GPU found."
}

# ---------------------------------------------------------------- check: node
check_node() {
  local tok cfg run ng m miss id ids_cfg f drv foreign line
  section "Node"
  detect_cpu; detect_bootloader
  c_info "CPU: $CPU_NAME ($CPU)"
  command -v pveversion >/dev/null 2>&1 && c_info "$(pveversion | head -1), kernel $(uname -r)"
  [[ -d /sys/firmware/efi ]] && c_info "Booted in UEFI mode" || c_info "Booted in legacy BIOS mode"
  c_info "Bootloader: $BOOTLOADER ($CMDLINE_FILE)"

  if grep -qE '\b(vmx|svm)\b' /proc/cpuinfo; then c_ok "CPU virtualization extensions present"
  else c_fail "No vmx/svm CPU flag"; c_hint "Enable Intel VT-x / AMD SVM in the BIOS"; fi

  local gpu_known=0
  if select_gpu soft; then gpu_known=1; c_info "GPU: $(gpu_name "$GPU_SLOT") @ $GPU_SLOT"
  else c_info "No single GPU selected — GPU-specific checks skipped (use --gpu <addr>)"; fi

  FB_RELEASE=0
  if [[ $gpu_known -eq 1 ]] && gpu_is_boot "$GPU_SLOT"; then
    c_warn "Selected GPU is the host's boot GPU — host console will be lost when it is passed through"
    FB_RELEASE=1
  fi

  # kernel command line
  cfg=" $(cmdline_current) "; run=" $(cat /proc/cmdline) "
  for tok in $(wanted_tokens); do
    if [[ $run == *" $tok "* ]]; then
      if [[ $cfg == *" $tok "* ]]; then c_ok "cmdline: $tok (active)"
      else c_warn "cmdline: $tok is active now but missing from $CMDLINE_FILE (lost on next boot)"; fi
    elif [[ $cfg == *" $tok "* ]]; then
      c_warn "cmdline: $tok is set in $CMDLINE_FILE but not active yet"
      c_hint "reboot required"
      if [[ $BOOTLOADER == grub && -r /boot/grub/grub.cfg ]] && ! grep -q -- "$tok" /boot/grub/grub.cfg; then
        c_hint "grub.cfg does not contain it yet — update-grub has not been run"
      fi
    else
      c_fail "cmdline: $tok missing"; c_hint "run: $PROG configure node"
    fi
  done

  # IOMMU
  ng=$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
  if (( ng > 0 )); then c_ok "IOMMU active ($ng groups)"
  else c_fail "IOMMU not active (no groups in /sys/kernel/iommu_groups)"; c_hint "Enable VT-d / AMD-Vi (IOMMU) in the BIOS, fix the cmdline, reboot"; fi

  if dmesg 2>/dev/null | grep -qiE 'Enabled IRQ remapping|Interrupt remapping enabled'; then c_ok "Interrupt remapping enabled"
  elif (( ng > 0 )); then
    if [[ -e $F_UNSAFE ]]; then c_warn "No interrupt remapping — allow_unsafe_interrupts is enabled (less safe)"
    else c_warn "Interrupt remapping not reported by dmesg"; c_hint "If VMs fail to start with 'interrupt remapping' errors: $PROG configure node --unsafe-interrupts"; fi
  fi

  # modules
  miss=()
  for m in vfio vfio_iommu_type1 vfio_pci; do [[ -d /sys/module/$m ]] || miss+=("$m"); done
  if (( ${#miss[@]} == 0 )); then c_ok "vfio modules loaded"
  else c_warn "vfio modules not loaded: ${miss[*]}"; fi
  if grep -qshE '^[[:space:]]*vfio[_-]pci' /etc/modules /etc/modules-load.d/*.conf; then c_ok "vfio modules load at boot"
  else c_fail "vfio modules not configured to load at boot"; c_hint "run: $PROG configure node"; fi

  # manual leftovers
  local manual
  manual=$(grep -lsE 'options[[:space:]]+vfio[-_]pci' /etc/modprobe.d/*.conf 2>/dev/null | grep -v '/gpupt-' || true)
  [[ -n $manual ]] && c_warn "Hand-written vfio-pci options found (may duplicate gpupt's): $(echo $manual)"

  if [[ $gpu_known -eq 1 ]]; then
    # vfio ids
    ids_cfg=$(grep -rhsE '^[[:space:]]*options[[:space:]]+vfio[-_]pci' /etc/modprobe.d/ | grep -oE 'ids=[^[:space:]]+' | cut -d= -f2 | tr ',' '\n' | sort -u)
    miss=()
    for id in $(gpu_ids | tr ',' ' '); do grep -qx "$id" <<<"$ids_cfg" || miss+=("$id"); done
    if (( ${#miss[@]} == 0 )); then c_ok "vfio-pci ids cover every GPU function ($(gpu_ids))"
    else c_fail "vfio-pci ids missing: ${miss[*]}"; c_hint "run: $PROG configure node"; fi

    # driver binding
    for f in $(slot_funcs "$GPU_SLOT"); do
      drv=$(dev_driver "$f")
      case $drv in
        vfio-pci) c_ok "$f bound to vfio-pci";;
        none)     c_warn "$f has no driver (Proxmox binds vfio-pci when the VM starts)";;
        *)        c_fail "$f is bound to '$drv' (expected vfio-pci)"; c_hint "after configuring, reboot so vfio-pci claims it before $drv";;
      esac
    done

    # IOMMU group isolation
    foreign=$(group_foreign "$GPU_SLOT")
    if (( ng > 0 )); then
      if [[ -z $foreign ]]; then c_ok "IOMMU group $(gpu_group "$GPU_SLOT") contains only the GPU (and bridges)"
      else
        c_warn "IOMMU group $(gpu_group "$GPU_SLOT") is shared with other devices:"
        while IFS='|' read -r a d; do c_hint "$a $d"; done <<<"$foreign"
        c_hint "all devices in a group must be passed through together; try another PCIe slot"
      fi
    fi

    # initramfs
    if command -v lsinitramfs >/dev/null 2>&1 && [[ -r /boot/initrd.img-$(uname -r) ]]; then
      if lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -q vfio; then c_ok "vfio present in the initramfs of the running kernel"
      else c_warn "vfio not found in the running kernel's initramfs"; c_hint "update-initramfs -u -k all (configure node does this)"; fi
    fi

    # vendor specifics
    case "$(gpu_vendor "$GPU_SLOT")" in
      10de)
        if [[ "$(cat /sys/module/kvm/parameters/ignore_msrs 2>/dev/null)" == Y ]]; then c_ok "kvm ignore_msrs=1 (avoids Windows guest BSODs on NVIDIA)"
        else c_warn "kvm ignore_msrs is off — Windows guests with NVIDIA GPUs can crash with MSR errors"; c_hint "run: $PROG configure node"; fi;;
      1002)
        if lspci -Dvv -s "${GPU_SLOT}.0" 2>/dev/null | grep -q 'FLReset+'; then c_ok "GPU advertises function-level reset (FLR)"
        else c_warn "AMD GPU without FLR — it may not reset cleanly between VM boots (reset bug)"; c_hint "consider the 'vendor-reset' DKMS module"; fi;;
    esac
  fi
}

# ---------------------------------------------------------------- check: vm
vm_main() { sed '/^\[/,$d' "$PVE_QEMU_DIR/$1.conf"; }
vm_get()  { vm_main "$1" | sed -n "s/^$2: *//p" | head -1; }

check_vm() {
  local vmid="$1" v line idx short
  [[ -r $PVE_QEMU_DIR/$vmid.conf ]] || die "VM $vmid not found on this node."
  section "VM $vmid ($(vm_get "$vmid" name))"

  v=$(vm_get "$vmid" bios)
  if [[ $v == ovmf ]]; then c_ok "bios: ovmf"; else c_fail "bios is '${v:-seabios}' (need ovmf for PCIe passthrough)"; c_hint "run: $PROG configure vm $vmid"; fi

  v=$(vm_get "$vmid" machine)
  if [[ $v == q35 || $v == pc-q35-* ]]; then c_ok "machine: $v"; else c_fail "machine is '${v:-i440fx}' (need q35 for pcie=1)"; c_hint "run: $PROG configure vm $vmid"; fi

  if [[ -n $(vm_get "$vmid" efidisk0) ]]; then c_ok "efidisk0 present"; else c_fail "efidisk0 missing (OVMF needs it to store UEFI variables)"; c_hint "run: $PROG configure vm $vmid"; fi

  v=$(vm_get "$vmid" cpu)
  if [[ $v == host || $v == host,* ]]; then c_ok "cpu: $v"; else c_warn "cpu is '${v:-kvm64}' — 'host' is recommended"; fi

  v=$(vm_get "$vmid" balloon)
  if [[ $v == 0 ]]; then c_ok "ballooning disabled"; else c_warn "ballooning enabled — passthrough pins guest RAM, set balloon: 0"; fi

  if select_gpu soft; then
    short="${GPU_SLOT#0000:}"
    line=$(vm_main "$vmid" | grep -E "^hostpci[0-9]+: *(0000:)?${short}(\.[0-7])?(,|\$)" | head -1)
    if [[ -z $line ]]; then
      c_fail "No hostpci entry for GPU $GPU_SLOT"; c_hint "run: $PROG configure vm $vmid"
    else
      idx="${line%%:*}"; v="${line#*: }"
      c_ok "$idx: $v"
      [[ $v == *pcie=1* ]] && c_ok "hostpci uses pcie=1" || c_warn "hostpci without pcie=1 (needs q35)"
      [[ ${v%%,*} == *.[0-7] ]] && c_warn "only one function passed — the GPU's audio function is left behind (use ${GPU_SLOT} without .N)"
      if [[ $v == *x-vga=1* ]]; then
        [[ $(vm_get "$vmid" vga) == none ]] && c_ok "x-vga=1 with vga: none" || c_info "x-vga=1 set; consider 'vga: none' if the GPU is the only display"
      fi
    fi
    # conflicts with other VMs
    local f id st
    for f in "$PVE_QEMU_DIR"/*.conf; do
      id=$(basename "$f" .conf); [[ $id == "$vmid" ]] && continue
      if sed '/^\[/,$d' "$f" | grep -qE "^hostpci[0-9]+: *(0000:)?${short}(\.[0-7])?(,|\$)"; then
        st=$(qm status "$id" 2>/dev/null | awk '{print $2}')
        c_warn "GPU is also assigned to VM $id ($st) — only one of them can run at a time"
      fi
    done
  else
    c_info "No single GPU selected — hostpci checks skipped (use --gpu <addr>)"
  fi
}

cmd_check() {
  local scope="${1:-node}" vmid="${2:-}"
  require_root
  P=0; W=0; F=0
  case "$scope" in
    node) check_node;;
    vm)   [[ $vmid =~ ^[0-9]+$ ]] || die "Usage: $PROG check vm <vmid>"; detect_cpu; detect_bootloader; check_vm "$vmid";;
    *)    die "Usage: $PROG check [node|vm <vmid>]";;
  esac
  echo
  printf '%s\n' "${BOLD}Summary:${N} ${G}$P passed${N}, ${Y}$W warnings${N}, ${R}$F failures${N}"
  if (( F > 0 )); then
    [[ $scope == node ]] && echo "Fix with: $PROG configure node" || echo "Fix with: $PROG configure vm $vmid"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- configure node
other_same_vendor_gpus() {
  local s v n=0
  v=$(gpu_vendor "$GPU_SLOT")
  while read -r s; do [[ -z $s || $s == "$GPU_SLOT" ]] && continue; [[ $(gpu_vendor "$s") == "$v" ]] && n=$((n+1)); done < <(gpu_slots)
  echo "$n"
}

configure_node() {
  local tmp vend drivers=() d id dev f other
  require_root; detect_cpu; select_gpu interactive; detect_bootloader
  banner

  # ---- safety warnings
  if gpu_is_boot "$GPU_SLOT"; then
    echo
    warn "This is the host's boot GPU. Passing it through means the host console/monitor goes dark."
    warn "Make sure you can reach the node over SSH or the web UI (https://<ip>:8006)."
    if [[ $(gpu_slots | wc -l) -eq 1 ]]; then warn "It is also the ONLY GPU in this machine."; fi
    confirm "Continue configuring this GPU for passthrough?" || { echo "Aborted."; exit 1; }
    if ask_always "Also release the boot framebuffer (video=efifb:off, video=vesafb:off, initcall_blacklist=sysfb_init)? Needed for boot-GPU passthrough"; then FB_RELEASE=1; fi
  fi

  # same-ID duplicates would be bound too
  for id in $(gpu_ids | tr ',' ' '); do
    for dev in /sys/bus/pci/devices/*; do
      f=$(basename "$dev"); [[ ${f%.*} == "$GPU_SLOT" ]] && continue
      [[ "$(pci_id "$f")" == "$id" ]] && warn "Device $f has the same PCI id ($id) and will ALSO be bound to vfio-pci."
    done
  done

  tmp="$TMP/node"; mkdir -p "$tmp"
  txn_begin node "configure node: GPU $GPU_SLOT ($(gpu_name "$GPU_SLOT")), $CPU, $BOOTLOADER"
  CHG_BOOT=0; CHG_MOD=0
  local rc

  # 1) kernel command line
  section "1/6  Kernel command line"
  build_cmdline_file "$tmp/cmdline"
  apply_file "$CMDLINE_FILE" "$tmp/cmdline"; rc=$?; [[ $rc -eq 0 ]] && CHG_BOOT=1

  # 2) modules to load at boot
  section "2/6  VFIO modules at boot"
  { echo "# Managed by gpupt — VFIO modules for GPU passthrough"
    echo vfio; echo vfio_iommu_type1; echo vfio_pci
    if modinfo vfio_virqfd >/dev/null 2>&1; then echo vfio_virqfd; fi; } >"$tmp/modload"
  apply_file "$F_MODLOAD" "$tmp/modload"; rc=$?; [[ $rc -eq 0 ]] && CHG_MOD=1

  # 3) bind GPU to vfio-pci
  section "3/6  Bind GPU to vfio-pci"
  { echo "# Managed by gpupt — bind $(gpu_name "$GPU_SLOT") to vfio-pci"
    echo "options vfio-pci ids=$(gpu_ids)"; } >"$tmp/vfio"
  apply_file "$F_VFIO" "$tmp/vfio"; rc=$?; [[ $rc -eq 0 ]] && CHG_MOD=1

  # 4) keep host GPU drivers away
  section "4/6  Host GPU driver handling"
  vend=$(gpu_vendor "$GPU_SLOT")
  case $vend in
    10de) drivers=(nouveau nvidia nvidiafb nvidia_drm);;
    1002) drivers=(radeon amdgpu);;
    8086) drivers=(i915);;
    *)    drivers=();;
  esac
  other=$(other_same_vendor_gpus)
  if (( ${#drivers[@]} == 0 )); then
    ok "No host driver handling needed for vendor $vend"
  else
    { echo "# Managed by gpupt — make vfio-pci load before the host GPU driver"
      for d in "${drivers[@]}"; do echo "softdep $d pre: vfio-pci"; done
      if (( other == 0 )); then for d in "${drivers[@]}"; do echo "blacklist $d"; done
      else echo "# NOTE: another GPU of the same vendor exists on this host -> drivers are NOT blacklisted"; fi
    } >"$tmp/blacklist"
    (( other > 0 )) && warn "Another GPU from the same vendor is present: using softdep only (no blacklist) so the host keeps its GPU."
    apply_file "$F_BLACKLIST" "$tmp/blacklist"; rc=$?; [[ $rc -eq 0 ]] && CHG_MOD=1
  fi

  # 5) KVM MSR handling (NVIDIA / Windows guests)
  section "5/6  KVM MSR handling"
  if [[ $IGNORE_MSRS == 1 || ( -z $IGNORE_MSRS && $vend == 10de ) ]]; then
    printf '%s\n' "# Managed by gpupt — avoid MSR-related BSODs in Windows guests (NVIDIA)" \
      "options kvm ignore_msrs=1 report_ignored_msrs=0" >"$tmp/kvm"
    apply_file "$F_KVM" "$tmp/kvm"; rc=$?; [[ $rc -eq 0 ]] && CHG_MOD=1
  else ok "Not needed for this GPU vendor (force with --ignore-msrs)"; fi

  # 6) unsafe interrupts (opt-in)
  section "6/6  Interrupt remapping fallback"
  if [[ $UNSAFE_INT -eq 1 ]]; then
    warn "allow_unsafe_interrupts weakens isolation between VMs and the host. Only use it if remapping is unsupported."
    printf '%s\n' "# Managed by gpupt — platform lacks interrupt remapping" \
      "options vfio_iommu_type1 allow_unsafe_interrupts=1" >"$tmp/unsafe"
    apply_file "$F_UNSAFE" "$tmp/unsafe"; rc=$?; [[ $rc -eq 0 ]] && CHG_MOD=1
  else ok "Skipped (opt-in with --unsafe-interrupts)"; fi

  # ---- hooks
  (( CHG_BOOT )) && txn_note "HOOK|boot"
  (( CHG_MOD ))  && txn_note "HOOK|initramfs"
  save_state
  section "Post-change steps"
  if (( CHG_MOD )); then hook_initramfs; else ok "initramfs: no module/modprobe changes — nothing to rebuild"; fi
  if (( CHG_BOOT )); then hook_boot; else ok "bootloader: command line unchanged — nothing to refresh"; fi
  txn_end

  if (( CHG_BOOT || CHG_MOD )); then
    offer_reboot
    echo; echo "After the reboot: ${BOLD}$PROG check${N}, then ${BOLD}$PROG configure vm <vmid>${N}"
  else
    echo; ok "Node already configured. Run: $PROG check"
  fi
}

# ---------------------------------------------------------------- configure vm
conf_set() {  # file key value — set key inside the main (non-snapshot) section
  awk -v k="$2" -v v="$3" '
    BEGIN { done=0; insec=0 }
    /^\[/ && !insec { if (!done) { print k ": " v; done=1 } insec=1 }
    !insec && index($0, k ":") == 1 { if (!done) { print k ": " v; done=1 } ; next }
    { print }
    END { if (!done) print k ": " v }' "$1" >"$1.new" && mv "$1.new" "$1"
}

build_hostpci_value() {  # $1 = existing value (may be empty)
  local old="$1" rest="" o v
  local -a parts=() opts=()
  [[ $old == *,* ]] && rest="${old#*,}"
  IFS=',' read -ra parts <<<"$rest"
  for o in "${parts[@]}"; do [[ -z $o || $o == pcie=* || $o == x-vga=* ]] && continue; opts+=("$o"); done
  v="$GPU_SLOT,pcie=1"
  [[ $XVGA == 1 ]] && v+=",x-vga=1"
  for o in "${opts[@]}"; do v+=",$o"; done
  printf '%s' "$v"
}

configure_vm() {
  local vmid="$1" conf new status v idx cur short line efi_new=0 sf sp sw pf f
  [[ $vmid =~ ^[0-9]+$ ]] || die "Usage: $PROG configure vm <vmid>"
  require_root; require_qm
  conf="$PVE_QEMU_DIR/$vmid.conf"
  [[ -r $conf ]] || die "VM $vmid not found on this node."
  detect_cpu; detect_bootloader; select_gpu interactive
  banner
  short="${GPU_SLOT#0000:}"

  # node readiness (only failures are printed)
  sf=$F; sp=$P; sw=$W; P=0; W=0; F=0
  QUIET=1 check_node >"$TMP/preflight.out" 2>&1; pf=$F; P=$sp; W=$sw; F=$sf
  QUIET=0
  if (( pf > 0 )); then
    echo; warn "The node is not fully configured yet ($pf failing check(s)):"
    grep '✘' "$TMP/preflight.out" || true
    confirm "Configure the VM anyway? (recommended: run '$PROG configure node' first)" || { echo "Aborted."; exit 1; }
  fi

  status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
  [[ $status == running ]] && warn "VM $vmid is running. Changes are staged; a full stop → start (not a guest reboot) is needed."

  for f in "$PVE_QEMU_DIR"/*.conf; do
    v=$(basename "$f" .conf); [[ $v == "$vmid" ]] && continue
    sed '/^\[/,$d' "$f" | grep -qE "^hostpci[0-9]+: *(0000:)?${short}(\.[0-7])?(,|\$)" \
      && warn "GPU is already assigned to VM $v ($(qm status "$v" 2>/dev/null | awk '{print $2}')) — they cannot run simultaneously."
  done

  # x-vga decision
  if [[ -z $XVGA ]]; then
    if [[ $ASSUME_YES -eq 1 ]]; then XVGA=0
    elif confirm "Use this GPU as the VM's primary display (x-vga=1, vga: none)? Choose 'no' for compute-only or if you still use the noVNC console"; then XVGA=1
    else XVGA=0; fi
  fi

  new="$TMP/vm.new"; cp "$conf" "$new"
  local -a qm_args=()

  # bios
  cur=$(vm_get "$vmid" bios)
  if [[ $cur != ovmf ]]; then
    warn "Switching BIOS from ${cur:-seabios} to OVMF: the guest OS must be installed in UEFI (GPT) mode, otherwise it will not boot."
    conf_set "$new" bios ovmf; qm_args+=(--bios ovmf)
  fi
  # machine
  cur=$(vm_get "$vmid" machine)
  if [[ ! ( $cur == q35 || $cur == pc-q35-* ) ]]; then
    warn "Switching machine type from ${cur:-i440fx} to q35: Windows may re-detect devices (NIC settings, activation); Linux NIC names can change."
    conf_set "$new" machine q35; qm_args+=(--machine q35)
  fi
  # efidisk
  if [[ -z $(vm_get "$vmid" efidisk0) ]]; then
    if [[ -z $EFI_STORAGE ]]; then
      EFI_STORAGE=$(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}' | grep -x 'local-lvm' || true)
      [[ -n $EFI_STORAGE ]] || EFI_STORAGE=$(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active"{print $1; exit}')
      [[ -n $EFI_STORAGE ]] || die "No active image storage found — pass --efi-storage <name>."
      info "EFI disk will be created on storage '$EFI_STORAGE' (change with --efi-storage)"
    fi
    local keys=0; [[ $SECURE_BOOT -eq 1 ]] && keys=1
    conf_set "$new" efidisk0 "$EFI_STORAGE:vm-$vmid-disk-N,efitype=4m,pre-enrolled-keys=$keys,size=4M"
    qm_args+=(--efidisk0 "$EFI_STORAGE:1,efitype=4m,pre-enrolled-keys=$keys"); efi_new=1
  fi
  # cpu
  cur=$(vm_get "$vmid" cpu)
  if [[ ! ( $cur == host || $cur == host,* ) ]]; then conf_set "$new" cpu host; qm_args+=(--cpu host); fi
  # balloon
  cur=$(vm_get "$vmid" balloon)
  if [[ $cur != 0 ]]; then conf_set "$new" balloon 0; qm_args+=(--balloon 0); fi
  # hostpci
  line=$(vm_main "$vmid" | grep -E "^hostpci[0-9]+: *(0000:)?${short}(\.[0-7])?(,|\$)" | head -1)
  if [[ -n $line ]]; then idx="${line%%:*}"; idx="${idx#hostpci}"; cur="${line#*: }"
  else
    idx=""; for v in $(seq 0 15); do vm_main "$vmid" | grep -q "^hostpci$v:" || { idx=$v; break; }; done
    [[ -n $idx ]] || die "All 16 hostpci slots are used."
    cur=""
  fi
  v=$(build_hostpci_value "$cur")
  if [[ $v != "$cur" ]]; then conf_set "$new" "hostpci$idx" "$v"; qm_args+=("--hostpci$idx" "$v"); fi
  # vga
  if [[ $XVGA == 1 && $(vm_get "$vmid" vga) != none ]]; then conf_set "$new" vga none; qm_args+=(--vga none); fi

  if cmp -s "$conf" "$new"; then
    ok "VM $vmid is already configured."
    QUIET=0; P=0; W=0; F=0; check_vm "$vmid"; return 0
  fi

  show_change "$conf" "$new"
  (( efi_new )) && echo "${D}(the EFI disk volume name is assigned by Proxmox when it is allocated)${N}"
  echo; echo "This will run:"; echo "  ${BOLD}qm set $vmid ${qm_args[*]}${N}"
  if ! confirm "Apply these changes to VM $vmid?"; then warn "Nothing changed."; return 0; fi

  txn_begin "vm$vmid" "configure vm $vmid: GPU $GPU_SLOT"
  txn_backup_file "$conf"; txn_note "VM|$vmid"
  log "RUN qm set $vmid ${qm_args[*]}"
  if ! qm set "$vmid" "${qm_args[@]}"; then
    warn "qm set failed — restoring the original VM config."
    cat "$TXN_DIR/files/$(enc "$conf")" >"$conf"
    txn_end; die "Aborted; VM $vmid config restored."
  fi
  if (( efi_new )); then
    v=$(vm_get "$vmid" efidisk0); [[ -n $v ]] && txn_note "VOL|${v%%,*}"
  fi
  txn_end
  ok "VM $vmid updated"
  save_state
  QUIET=0; P=0; W=0; F=0; check_vm "$vmid"
  echo
  echo "Next: fully stop and start the VM (${BOLD}qm stop $vmid && qm start $vmid${N}), then install the GPU driver in the guest."
}

# ---------------------------------------------------------------- backups / rollback
txn_ids() { [[ -d $BACKUP_DIR ]] && ls -1 "$BACKUP_DIR" 2>/dev/null | sort; return 0; }

cmd_backups() {
  local id d n
  [[ -n $(txn_ids) ]] || { echo "No rollback points."; return 0; }
  printf '%s\n' "${BOLD}Rollback points (oldest → newest):${N}"
  for id in $(txn_ids); do
    d="$BACKUP_DIR/$id"; n=$(grep -c '^FILE|' "$d/manifest")
    printf '  %s  %s  %s\n' "${C}$id${N}" "($n files)" "$(cat "$d/description" 2>/dev/null)"
  done
}

restore_path() {  # path existed saved
  if [[ $2 == 1 ]]; then
    if [[ $1 == /etc/pve/* ]]; then cat "$3" >"$1"; else mkdir -p "$(dirname "$1")"; cp -a -- "$3" "$1"; fi
  else rm -f -- "$1"; fi
}

rollback_txn() {
  local id="$1" d="$BACKUP_DIR/$1" kind a b saved n=0 newer
  local -a plan=() vols=() hooks=()
  [[ -d $d ]] || die "No such rollback point: $id"
  echo; info "Rollback point ${BOLD}$id${N} — $(cat "$d/description")"

  newer=$(txn_ids | awk -v id="$id" '$0 > id')
  if [[ -n $newer ]]; then
    warn "Newer rollback points exist (later changes may depend on this one):"; echo "$newer" | sed 's/^/    /'
    confirm "Roll back $id anyway (out of order)?" || { echo "Skipped."; return 1; }
  fi

  while IFS='|' read -r kind a b; do
    case $kind in
      FILE)
        saved="$d/files/$(enc "$a")"
        if [[ $b == 1 ]]; then
          if [[ -e $a ]] && cmp -s "$a" "$saved"; then ok "$a already matches the backup"; continue; fi
          show_change "$a" "$saved"
        else
          [[ -e $a ]] || { ok "$a already absent"; continue; }
          echo; echo "${BOLD}━━ $a ━━${N}"
          print_block "BEFORE (current):" "$R" "$a"
          echo "${G}AFTER:${N}"; echo "    (file will be deleted — it did not exist before gpupt created it)"
        fi
        plan+=("$a|$b|$saved"); n=$((n+1));;
      VOL) vols+=("$a");;
      HOOK) hooks+=("$a");;
    esac
  done <"$d/manifest"

  if (( n > 0 )); then
    if ! confirm "Restore these $n file(s) to their previous state?"; then warn "Rollback of $id cancelled."; return 1; fi
    for a in "${plan[@]}"; do
      IFS='|' read -r p ex sv <<<"$a"
      if restore_path "$p" "$ex" "$sv"; then
        [[ $ex == 1 ]] && ok "Restored $p" || ok "Removed $p"
      else warn "Could not restore $p"; fi
      log "rollback $id: restored $p"
    done
  fi

  local h
  for h in "${hooks[@]:-}"; do
    case $h in
      initramfs) hook_initramfs;;
      boot)      hook_boot;;
    esac
  done
  for a in "${vols[@]:-}"; do
    [[ -z $a ]] && continue
    echo; echo "The EFI disk ${BOLD}$a${N} was created by gpupt and is no longer referenced by any VM."
    if confirm "Delete it with 'pvesm free $a'?"; then pvesm free "$a" && ok "Freed $a" || warn "Could not free $a"; fi
  done

  mkdir -p "$ROLLED_DIR"; mv "$d" "$ROLLED_DIR/" 2>/dev/null
  ok "Rolled back $id"
  return 0
}

cmd_rollback() {
  local arg="${1:-}" id ids pick
  require_root; detect_bootloader
  ids=$(txn_ids)
  [[ -n $ids ]] || { echo "Nothing to roll back."; return 0; }
  if [[ -z $arg ]]; then
    cmd_backups
    echo
    [[ -t 0 ]] || die "Specify a rollback point: $PROG rollback <id|last|all>"
    read -r -p "Roll back which one? (id / last / all / q) " pick
    arg="$pick"
  fi
  case "$arg" in
    q|"") return 0;;
    last) rollback_txn "$(tail -n1 <<<"$ids")";;
    all)
      echo; warn "This undoes EVERY gpupt change, newest first, and returns the system to its pre-gpupt state."
      confirm "Roll back all $(wc -l <<<"$ids") rollback point(s)?" || { echo "Cancelled."; return 0; }
      for id in $(tac <<<"$ids"); do rollback_txn "$id" || { warn "Stopped at $id."; return 1; }; done
      echo; warn "Reboot to fully unload vfio/cmdline changes."
      ;;
    *) rollback_txn "$arg";;
  esac
  echo; warn "Reboot the node for host-side rollbacks to take full effect."
}

# ---------------------------------------------------------------- report
cmd_report() {
  require_root; detect_cpu; detect_bootloader
  echo "== gpupt $VERSION report $(date -Is) =="
  command -v pveversion >/dev/null 2>&1 && pveversion
  echo "kernel: $(uname -r)"; echo "cpu: $CPU_NAME"; echo "bootloader: $BOOTLOADER"
  echo "-- /proc/cmdline"; cat /proc/cmdline
  echo "-- $CMDLINE_FILE"; grep -v '^#' "$CMDLINE_FILE" 2>/dev/null | grep -E 'CMDLINE|^[a-z]' || true
  echo "-- IOMMU dmesg"; dmesg 2>/dev/null | grep -iE 'DMAR|IOMMU|AMD-Vi|remapping' | head -30
  echo "-- IOMMU groups: $(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
  echo "-- GPUs"; lspci -Dnnk | grep -A3 -E '\[(0300|0302|0380|0403)\]'
  echo "-- modprobe.d / modules-load.d"
  grep -rHsvE '^\s*(#|$)' /etc/modprobe.d /etc/modules-load.d /etc/modules 2>/dev/null
  echo "-- loaded modules"; lsmod | grep -E '^(vfio|kvm|nvidia|nouveau|amdgpu|radeon|i915)' || true
  echo "-- rollback points"; txn_ids
}

# ---------------------------------------------------------------- usage / main
usage() {
cat <<EOF
${BOLD}$PROG $VERSION${N} — GPU passthrough helper for Proxmox VE (Intel & AMD hosts)

${BOLD}USAGE${N}
  $PROG <command> [options]

${BOLD}COMMANDS${N}
  list                      Show GPUs, drivers and IOMMU groups
  check [node]              Verify host configuration
  check vm <vmid>           Verify a VM's configuration
  configure node            Fix everything required on the host
  configure vm <vmid>       Fix everything required on a VM
  backups                   List rollback points
  rollback [id|last|all]    Undo changes (interactive when no argument)
  report                    Diagnostic dump to paste into a forum post

${BOLD}OPTIONS${N}
  --gpu <addr>              GPU to use, e.g. 01:00 or 0000:01:00.0 (remembered afterwards)
  -n, --dry-run             Show what would change; write nothing, run nothing
  -y, --yes                 Auto-approve prompts (diffs are still printed;
                            boot-GPU framebuffer release and reboot are always asked)
  --x-vga / --no-x-vga      VM: primary display GPU (x-vga=1 + vga: none) or not
  --efi-storage <name>      VM: storage for the EFI disk
  --secure-boot             VM: create the EFI disk with pre-enrolled keys (Windows 11)
  --ignore-msrs / --no-ignore-msrs
                            Node: force / skip kvm ignore_msrs (default: on for NVIDIA)
  --unsafe-interrupts       Node: allow_unsafe_interrupts=1 (only if remapping is unsupported)
  --no-color                Disable colours
  -h, --help / -V, --version

${BOLD}TYPICAL FLOW${N}
  $PROG list
  $PROG check
  $PROG configure node        # then reboot
  $PROG configure vm 101      # then: qm stop 101 && qm start 101
  $PROG rollback last         # if anything went wrong

State & rollback points live in $STATE_DIR, log in $LOG_FILE.
EOF
}

main() {
  local -a POS=()
  while (($#)); do
    case "$1" in
      -y|--yes)            ASSUME_YES=1;;
      -n|--dry-run)        DRY_RUN=1;;
      --gpu)               GPU_ARG="${2:-}"; shift;;
      --gpu=*)             GPU_ARG="${1#*=}";;
      --x-vga)             XVGA=1;;
      --no-x-vga)          XVGA=0;;
      --efi-storage)       EFI_STORAGE="${2:-}"; shift;;
      --secure-boot)       SECURE_BOOT=1;;
      --unsafe-interrupts) UNSAFE_INT=1;;
      --ignore-msrs)       IGNORE_MSRS=1;;
      --no-ignore-msrs)    IGNORE_MSRS=0;;
      --no-color)          NO_COLOR=1;;
      -h|--help)           setup_colors; usage; exit 0;;
      -V|--version)        echo "$PROG $VERSION"; exit 0;;
      --)                  shift; POS+=("$@"); break;;
      -*)                  die "Unknown option: $1 (see --help)";;
      *)                   POS+=("$1");;
    esac
    shift
  done
  setup_colors
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

  case "${POS[0]:-help}" in
    list)      cmd_list;;
    check)     cmd_check "${POS[1]:-node}" "${POS[2]:-}"; exit $?;;
    configure) case "${POS[1]:-}" in
                 node) configure_node;;
                 vm)   configure_vm "${POS[2]:-}";;
                 *)    die "Usage: $PROG configure node | configure vm <vmid>";;
               esac;;
    backups)   cmd_backups;;
    rollback)  cmd_rollback "${POS[1]:-}";;
    report)    cmd_report;;
    help)      usage;;
    *)         die "Unknown command: ${POS[0]} (see --help)";;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
