#!/usr/bin/env bash
# OSD disk safety checks (used by add-osds.sh; unit-tested by tests/test-disk-safety.sh).
#
#   disk-safety.sh probe <by-id path>...          # run ON the target host: print a snapshot
#   disk-safety.sh classify <snapshot> <host> [--fsid F] <by-id path>...
#        -> one line per path: ACTION|host|path|kname|size|model|serial|rota|detail
#           ACTION = CREATE | NEEDS-ZAP | SKIP | REFUSE
#
# Hard rules (no flag can override): only /dev/disk/by-id/* paths; must resolve to a whole
# disk (TYPE=disk); never the disk backing / /boot /boot/efi or swap (followed through
# LVM / md / dm-crypt via `lsblk -s`); never a disk with any mounted child, md member,
# swap, non-Ceph LVM PV, LVM of another Ceph cluster, LUKS; no duplicates.
set -euo pipefail

ds_probe() {
  local p mp src
  echo "@@LSBLK"
  lsblk -J -b -o NAME,KNAME,PATH,SIZE,MODEL,SERIAL,ROTA,TYPE,FSTYPE,MOUNTPOINTS,PKNAME
  echo "@@ROOTDISKS"
  {
    for mp in / /boot /boot/efi; do
      src=$(findmnt -n -o SOURCE --target "$mp" 2>/dev/null | head -n1 || true)
      [ -n "$src" ] && [ -b "$src" ] && lsblk -n -s -o KNAME,TYPE "$src" 2>/dev/null | awk '$2=="disk"{print $1}'
    done
    awk 'NR>1 && $2=="partition"{print $1} NR>1 && $2=="file"{print "FILE:"$1}' /proc/swaps 2>/dev/null |
      while read -r src; do
        case $src in
          FILE:*) src=$(findmnt -n -o SOURCE --target "${src#FILE:}" | head -n1 || true);;
        esac
        [ -n "$src" ] && [ -b "$src" ] && lsblk -n -s -o KNAME,TYPE "$src" 2>/dev/null | awk '$2=="disk"{print $1}'
      done
    true
  } | sort -u
  echo "@@PVS"
  pvs --noheadings --separator '|' -o pv_name,vg_name 2>/dev/null | sed 's/^ *//' || true
  echo "@@LVS"
  lvs --noheadings --separator '|' -o vg_name,lv_tags 2>/dev/null | sed 's/^ *//' || true
  echo "@@RESOLVE"
  for p in "$@"; do echo "$p|$(readlink -e "$p" 2>/dev/null || true)"; done
  echo "@@SIG"
  for p in "$@"; do
    src=$(readlink -e "$p" 2>/dev/null || true)
    [ -n "$src" ] || continue
    echo "$(basename "$src")|$(wipefs -n -p "$src" 2>/dev/null | awk -F, 'NR>1 && $0!~/^#/{printf "%s@%s ", $4, $1}')"
  done
  echo "@@END"
}

# section <file> <name>  -> lines of that section
ds_section() { awk -v s="@@$2" '/^@@/{on=($0==s); next} on' "$1"; }

ds_classify() {
  local snap=$1 host=$2; shift 2
  local fsid=""
  if [ "${1:-}" = --fsid ]; then fsid=$2; shift 2; fi
  local lsblk rootdisks pvs lvs
  lsblk=$(ds_section "$snap" LSBLK)
  rootdisks=$(ds_section "$snap" ROOTDISKS)
  pvs=$(ds_section "$snap" PVS)
  lvs=$(ds_section "$snap" LVS)
  # count kname occurrences to detect duplicates
  declare -A seen=()
  local p real kn
  for p in "$@"; do
    real=$(ds_section "$snap" RESOLVE | awk -F'|' -v p="$p" '$1==p{print $2}')
    [ -n "$real" ] && { kn=$(basename "$real"); seen[$kn]=$(( ${seen[$kn]:-0} + 1 )); }
  done
  for p in "$@"; do
    local action="" detail="" size="-" model="-" serial="-" rota="-" node typ
    kn="-"
    real=$(ds_section "$snap" RESOLVE | awk -F'|' -v p="$p" '$1==p{print $2}')
    if [[ $p != /dev/disk/by-id/* ]]; then
      action=REFUSE; detail="not a /dev/disk/by-id path"
    elif [[ $p == *-part[0-9]* ]]; then
      action=REFUSE; detail="by-id path is a partition"
    elif [ -z "$real" ]; then
      action=REFUSE; detail="does not resolve on $host"
    fi
    if [ -n "$real" ]; then kn=$(basename "$real"); fi
    if [ -z "$action" ]; then
      node=$(jq -c --arg k "$kn" '[.blockdevices[] | select(.kname==$k)][0] // empty' <<<"$lsblk")
      if [ -z "$node" ]; then
        typ=$(jq -r --arg k "$kn" '[.. | objects | select(.kname?==$k) | .type][0] // "missing"' <<<"$lsblk")
        action=REFUSE; detail="$kn is not a whole disk (type=$typ)"
      else
        size=$(jq -r '.size' <<<"$node"); model=$(jq -r '.model // "-" | gsub(" ";"_")' <<<"$node")
        serial=$(jq -r '.serial // "-"' <<<"$node"); rota=$(jq -r '.rota' <<<"$node")
        typ=$(jq -r '.type' <<<"$node")
        local all mnts fstypes ptypes
        all=$(jq -c '[.. | objects | select(has("kname"))]' <<<"$node")
        mnts=$(jq -r '[.[] | ((.mountpoints // []) + [.mountpoint // empty]) | .[] | select(. != null and . != "")] | unique | join(",")' <<<"$all")
        fstypes=$(jq -r '[.[] | .fstype // empty] | unique | join(",")' <<<"$all")
        ptypes=$(jq -r '[.[] | .type] | unique | join(",")' <<<"$all")
        if [ "$typ" != disk ]; then
          action=REFUSE; detail="type=$typ, not a disk"
        elif grep -qx "$kn" <<<"$rootdisks"; then
          action=REFUSE; detail="backs / /boot /boot/efi or swap"
        elif [ "${seen[$kn]:-0}" -gt 1 ]; then
          action=REFUSE; detail="listed more than once (same physical disk)"
        elif [ -n "$mnts" ]; then
          action=REFUSE; detail="mounted: $mnts"
        elif [[ ,$fstypes, == *,linux_raid_member,* || ,$ptypes, == *,raid* ]]; then
          action=REFUSE; detail="md RAID member"
        elif [[ ,$fstypes, == *,swap,* ]]; then
          action=REFUSE; detail="swap signature"
        elif [[ ,$fstypes, == *,crypto_LUKS,* || ,$ptypes, == *,crypt,* ]]; then
          action=REFUSE; detail="LUKS / dm-crypt"
        elif [[ ,$fstypes, == *,LVM2_member,* ]]; then
          local members vgs vg tags cf ceph_own=0 other=0 nonceph=0
          members=$(jq -r '.[] | select(.fstype=="LVM2_member") | .path // ("/dev/" + .kname)' <<<"$all")
          vgs=$(while read -r m; do awk -F'|' -v m="$m" '$1==m{print $2}' <<<"$pvs"; done <<<"$members" | sort -u)
          if [ -z "$(tr -d '[:space:]' <<<"$vgs")" ]; then
            nonceph=1
          else
            while read -r vg; do
              [ -n "$vg" ] || continue
              tags=$(awk -F'|' -v v="$vg" '$1==v{print $2}' <<<"$lvs" | tr '\n' ',')
              if [[ $tags == *ceph.osd_fsid=* ]]; then
                cf=$(tr ',' '\n' <<<"$tags" | sed -n 's/^ceph.cluster_fsid=//p' | head -n1)
                if [ -n "$fsid" ] && [ "$cf" = "$fsid" ]; then ceph_own=1; else other=1; fi
              else
                nonceph=1
              fi
            done <<<"$vgs"
          fi
          if [ "$nonceph" = 1 ]; then action=REFUSE; detail="non-Ceph LVM (vg: $(tr '\n' ' ' <<<"$vgs"))"
          elif [ "$other" = 1 ]; then action=REFUSE; detail="Ceph LVM of another/unknown cluster (handle manually)"
          elif [ "$ceph_own" = 1 ]; then action=SKIP; detail="already an OSD of this cluster"
          fi
        fi
        if [ -z "$action" ]; then
          local sig children
          sig=$(ds_section "$snap" SIG | awk -F'|' -v k="$kn" '$1==k{print $2}' | sed 's/ *$//')
          children=$(jq -r 'length' <<<"$all")
          if [ "$children" -gt 1 ] || [ -n "$fstypes" ] || [ -n "$sig" ]; then
            action=NEEDS-ZAP; detail="old data: ${fstypes:-} ${sig:-} parts=$((children-1))"
          else
            action=CREATE; detail="clean"
          fi
        fi
      fi
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$action" "$host" "$p" "$kn" "$size" "$model" "$serial" "$rota" "$detail"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd=${1:-}; shift || true
  case $cmd in
    probe) ds_probe "$@";;
    classify) ds_classify "$@";;
    *) echo "usage: $0 probe <path>... | classify <snapshot> <host> [--fsid F] <path>..." >&2; exit 2;;
  esac
fi
