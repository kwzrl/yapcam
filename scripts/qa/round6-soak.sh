#!/bin/zsh
# Round 6 soak: --ui-record-selftest / --drive-input-selftest repeated under the app lock.
# usage: scripts/qa/round6-soak.sh <runs-per-combo> [combo...]   combo = <selftest>:<source>:<after> e.g. ui:display:create
# Results: ~/Movies/Yapcam/QA/round6/soak.tsv ; recordings it creates are deleted after each run (only packages that did not exist before).
set -u
root=${0:A:h:h:h}; app=$root/build/Yapcam.app; out=~/Movies/Yapcam/QA/round6; lock=~/Movies/Yapcam/QA/.app-lock
log=~/Library/Logs/Yapcam/probe.log; proj=~/Movies/Yapcam; diag=~/Library/Logs/DiagnosticReports
runs=${1:-20}; shift
combos=("$@"); [[ ${#combos} -eq 0 ]] && combos=(ui:display:create ui:display:widget ui:display:copy ui:display:save ui:window:create ui:window:widget ui:window:copy ui:window:save ui:area:create ui:area:widget ui:area:copy ui:area:save drive:display:create)
mkdir -p $out
[[ -e $lock ]] && { echo "lock held: $(cat $lock)"; exit 2 }
echo "qa-round6-soak $$ $(date +%H:%M)" > $lock
tmp=$(mktemp -d); trap 'rm -f $lock; rm -rf $tmp' EXIT
ls $diag > $tmp/ips.before
for c in $combos; do
  kind=${c%%:*}; rest=${c#*:}; src=${rest%%:*}; aft=${rest#*:}
  flag=--ui-record-selftest; [[ $kind == drive ]] && flag=--drive-input-selftest
  for i in $(seq 1 $runs); do
    ls $proj > $tmp/before; n=$(wc -l < $log)
    extra=(); [[ $aft == save ]] && extra=(--save-to $tmp/save-$i.mp4)
    open -n -W $app --args $flag 4 --source $src --after-recording $aft $extra --auto-confirm
    tail -n +$((n+1)) $log > $out/soak-$kind-$src-$aft-$i.log
    res=FAIL; grep -q "selftest ok" $out/soak-$kind-$src-$aft-$i.log && ! grep -qi "failed" $out/soak-$kind-$src-$aft-$i.log && res=PASS
    printf "%s\t%s\t%s\t%s\t%s\n" $kind $src $aft $i $res >> $out/soak.tsv
    ls $proj > $tmp/after
    for p in ${(f)"$(comm -13 $tmp/before $tmp/after)"}; do [[ $p == Recording-*.yapcam ]] && rm -rf "$proj/$p"; done
    rm -f $tmp/save-$i.mp4
  done
done
ls $diag > $tmp/ips.after; comm -13 $tmp/ips.before $tmp/ips.after > $out/new-crash-reports.txt
echo done; cat $out/new-crash-reports.txt
