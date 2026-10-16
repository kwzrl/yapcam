#!/bin/zsh
# Round 3 wrap-up: programmatic (NOT user-interaction) checks via the app's self-test launch flags.
# usage: scripts/qa/round3-wrapup.sh <block>   block: f11 | lowdisk | interrupt | flows
# Takes ~/Movies/Yapcam/QA/.app-lock (refuses if present); all outputs under ~/Movies/Yapcam/QA/round3/.
set -u
root=${0:A:h:h:h}; app=$root/build/Yapcam.app; out=~/Movies/Yapcam/QA/round3; lock=~/Movies/Yapcam/QA/.app-lock
log=~/Library/Logs/Yapcam/probe.log
mkdir -p $out
[[ -e $lock ]] && { echo "lock held: $(cat $lock)"; exit 2 }
echo "qa-round3 $$ $(date +%H:%M)" > $lock
trap 'rm -f $lock' EXIT
run() { # run <label> <args...>: launches via LaunchServices, prints new probe lines
  local label=$1; shift; local n=$(wc -l < $log 2>/dev/null || echo 0)
  open -n -W $app --args "$@"; tail -n +$((n+1)) $log > $out/$label.log; cat $out/$label.log | cut -c1-260
}
case $1 in
  f11) # programmatic: global hotkeys + Return/Escape posted from inside the app (not a person at the keyboard)
       for src in recordDisplay recordWindow recordArea; do for i in 1 2 3; do
         echo "== f11 $src run $i (Esc cancel, expect idle, pick again, Return, record, stop)"
         if [[ $src == recordArea ]]; then
           run f11-$src-$i-cancel --ui-record-selftest 6 --hotkey-script "$src,wait:1.5,escape,wait:1,expect:idle,startStop,wait:1,expect:idle" --auto-confirm
           echo "== f11 area run $i via --source area (confirm hook, no drag possible without real input)"
           run f11-area-$i-start --ui-record-selftest 4 --source area --auto-confirm
         else
           run f11-$src-$i --ui-record-selftest 6 --hotkey-script "$src,wait:1.5,escape,wait:1,expect:idle,$src,wait:1.5,return,wait:2,expect:recording,wait:2,startStop,wait:1,expect:idle" --auto-confirm
         fi
       done; done ;;
  flows) # Flow A/B/C equivalents (programmatic): record with pause, edit via menu actions, save, reopen, export
       pk=$out/pkgs; rm -rf $pk; mkdir -p $pk
       tc=~/yapcam-ref-local/round3/timecode; [[ -x $tc ]] || swiftc -O $root/scripts/qa/timecode.swift -o $tc
       $tc 40 & tcpid=$!; sleep 1
       echo "== record 24 s display (timecode window on screen), pause after 9 s"
       run flows-record --capture-selftest 24 --target display --pause-after 9 --out $pk
       pkg=$(ls -d $pk/*.yapcam | head -1); echo "package $pkg"
       kill $tcpid 2>/dev/null
       rm -rf $out/original.yapcam; cp -R $pkg $out/original.yapcam
       echo "== export original (before edits)"; run flows-export-before --editor-export-selftest $pkg $out/before.mp4
       echo "== edit (split/delete/zoom/padding/undo/redo), autosave"; run flows-edit --editor-selftest $pkg
       echo "== reopen check"; run flows-reopen --editor-reopen-check $pkg
       echo "== export edited"; run flows-export-after --editor-export-selftest $pkg $out/after.mp4
       echo "== edit again + crash after autosave, then reopen"; run flows-crash --editor-selftest $pkg --crash-after-autosave
       run flows-crash-reopen --editor-reopen-check $pkg ;;
  interrupt) # kill -9 of the app PID I started during a recording, then recover
       pk=$out/kill; rm -rf $pk; mkdir -p $pk
       before=$(pgrep -x Yapcam | sort | tr '\n' ' ')
       open -n $app --args --capture-selftest 40 --target display --out $pk
       for i in {1..20}; do sleep 1; mine=$(pgrep -x Yapcam | sort | tr '\n' ' '); [[ $mine != $before ]] && break; done
       pid=$(comm -13 <(print -l ${=before}|sort) <(print -l ${=mine}|sort) | head -1); echo "my pid $pid"
       sleep 8; kill -9 $pid; sleep 2; ls $pk
       scripts/qa/run-recover-check.sh $(ls -d $pk/*.yapcam | head -1) 2>&1 | tail -15 ;;
  f11-display-repeat) for i in {1..6}; do echo "== display repeat $i"; run f11-disp-rep-$i --ui-record-selftest 6 --hotkey-script "recordDisplay,wait:1.5,return,wait:2,expect:recording,wait:1,startStop,wait:1,expect:idle" --auto-confirm; done ;;
  src-display) run f11-srcdisplay --ui-record-selftest 5 --source display --auto-confirm ;;
  cap-display) mkdir -p $out/capd; run f11-capdisplay --capture-selftest 4 --target display --out $out/capd ;;
  *) echo "unknown block"; exit 1 ;;
esac
