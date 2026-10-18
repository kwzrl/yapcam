#!/bin/zsh
# Round 8: toolbar <-> editor switching selftest under the app lock.
# usage: scripts/qa/round8-switch.sh [runs]
# Needs the ui flag `--place-switch-selftest` (see docs/status/ui.md "From qa" R8). It must append these lines to probe.log, in order:
#   place-switch: launch place=toolbar
#   place-switch: shortcut -> home
#   place-switch: opened project <name>
#   place-switch: record button -> toolbar
#   place-switch: recording finished, editor reopened with new project
#   place-switch: ok
# Recordings the run creates are deleted afterwards (only packages that did not exist before).
set -u
root=${0:A:h:h:h}; app=$root/build/Yapcam.app; lock=~/Movies/Yapcam/QA/.app-lock
log=~/Library/Logs/Yapcam/probe.log; proj=~/Movies/Yapcam; diag=~/Library/Logs/DiagnosticReports
runs=${1:-3}; mkdir -p ~/Movies/Yapcam/QA/round8
[[ -e $lock ]] && { echo "lock held: $(cat $lock)"; exit 2 }
echo "qa-round8-switch $$ $(date +%H:%M)" > $lock
tmp=$(mktemp -d); trap 'rm -f $lock; rm -rf $tmp' EXIT
ls $diag > $tmp/ips.before
want=("launch place=toolbar" "shortcut -> home" "opened project" "record button -> toolbar" "recording finished, editor reopened with new project" "ok")
for i in $(seq 1 $runs); do
  ls $proj > $tmp/before; n=$(wc -l < $log)
  open -n -W $app --args --place-switch-selftest 8 --auto-confirm
  tail -n +$((n+1)) $log > ~/Movies/Yapcam/QA/round8/switch-$i.log
  res=PASS; for w in $want; do :; done
  for w in "${want[@]}"; do grep -q "place-switch: $w" ~/Movies/Yapcam/QA/round8/switch-$i.log || { res="FAIL(missing: $w)"; break }; done
  printf "%s\t%s\n" $i $res | tee -a ~/Movies/Yapcam/QA/round8/switch.tsv
  ls $proj > $tmp/after
  for p in ${(f)"$(comm -13 $tmp/before $tmp/after)"}; do [[ $p == Recording-*.yapcam ]] && rm -rf "$proj/$p"; done
done
ls $diag > $tmp/ips.after; echo "new crash reports:"; comm -13 $tmp/ips.before $tmp/ips.after
