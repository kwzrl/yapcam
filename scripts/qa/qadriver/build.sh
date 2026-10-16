#!/bin/zsh
# Builds ~/yapcam-ref-local/QADriver.app (outside the repo; ad-hoc signed, stable path so TCC grants persist).
set -e
here=${0:A:h}; app=~/yapcam-ref-local/QADriver.app
mkdir -p $app/Contents/MacOS
swiftc -O $here/main.swift -o $app/Contents/MacOS/QADriver
cat > $app/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>mov.yapcam.qadriver</string><key>CFBundleName</key><string>QADriver</string><key>CFBundleExecutable</key><string>QADriver</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
P
codesign -s - --force $app
echo built $app
