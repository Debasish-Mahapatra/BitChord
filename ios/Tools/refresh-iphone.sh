#!/bin/zsh
# Apps signed with a free Apple account stop opening on the iPhone 7 days after they were signed. This keeps
# BitChord going: run every day by launchd, it re-signs the app with a fresh profile and reinstalls it once the
# installed copy has less than two days left, over Wi-Fi or a cable, whenever the iPhone is around.
#
#   Tools/refresh-iphone.sh            check, and refresh if it's due
#   Tools/refresh-iphone.sh --force    refresh now
#   Tools/refresh-iphone.sh install    run the check every day at noon (and at login)
#   Tools/refresh-iphone.sh uninstall  stop doing that

set -u
cd "${0:A:h}/.." || exit 1

LABEL=com.personal.bitchord-k4w7p.refresh
AGENT=~/Library/LaunchAgents/$LABEL.plist
LOG=~/Library/Logs/bitchord-iphone-refresh.log
APP=build/dd/Build/Products/Release-iphoneos/BitChord.app
# When the copy on the iPhone stops opening, in seconds since 1970.
STATE=build/installed-until
BUNDLES=(com.personal.bitchord-k4w7p)

case ${1:-} in
install)
    mkdir -p ~/Library/LaunchAgents ~/Library/Logs
    cat > $AGENT <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/zsh</string>
		<string>${0:A}</string>
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Hour</key>
		<integer>12</integer>
		<key>Minute</key>
		<integer>0</integer>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$LOG</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
</dict>
</plist>
EOF
    launchctl bootout gui/$UID/$LABEL 2>/dev/null
    launchctl bootstrap gui/$UID $AGENT && echo "Checking every day at noon and at login. Log: $LOG"
    exit
    ;;
uninstall)
    launchctl bootout gui/$UID/$LABEL 2>/dev/null
    rm -f $AGENT
    echo "Stopped."
    exit
    ;;
esac

say() { print -r -- "$(date '+%Y-%m-%d %H:%M') $*" }
notify() { osascript -e "display notification \"$1\" with title \"BitChord on your iPhone\"" 2>/dev/null }
expiry() { security cms -D -i "$1/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null }

now=$(date +%s)
until=$(cat $STATE 2>/dev/null || echo 0)
if [[ ${1:-} != --force ]] && (( until - now > 2 * 86400 )); then
    say "Fine until $(date -r $until '+%a %d %b %H:%M'), nothing to do."
    exit 0
fi

# The first paired iPhone; the Mac reaches it over Wi-Fi or a cable.
devices=$(mktemp)
xcrun devicectl list devices --json-output $devices >/dev/null 2>&1
device=$(python3 -I -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d["hardwareProperties"].get("platform") == "iOS" and d["hardwareProperties"].get("reality") == "physical" \
            and d["connectionProperties"].get("pairingState") == "paired":
        print(d["hardwareProperties"]["udid"]); break
' $devices 2>/dev/null)
rm -f $devices
if [[ -z $device ]]; then
    say "No paired iPhone found."
    exit 1
fi

# A fresh profile, not the cached one with its old expiry date: Xcode makes a new one when there's none.
for profile in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision(N) ~/Library/MobileDevice/Provisioning\ Profiles/*.mobileprovision(N); do
    id=$(security cms -D -i "$profile" 2>/dev/null | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null)
    for bundle in $BUNDLES; do
        [[ $id == *.$bundle ]] && rm -f "$profile"
    done
done

(( until > 0 )) && was=$(date -r $until '+%a %d %b %H:%M') || was="unknown"
say "Re-signing; the copy on the iPhone is good until $was..."
if ! xcodebuild -project BitChord.xcodeproj -scheme BitChord -configuration Release -destination 'generic/platform=iOS' \
        -derivedDataPath build/dd -allowProvisioningUpdates -quiet build; then
    say "Build failed."
    (( until - now < 86400 )) && notify "Couldn't re-sign the app; it stops opening soon. Open the project on the Mac to see why."
    exit 1
fi

if ! xcrun devicectl device install app --device $device $APP >/dev/null 2>&1; then
    say "Couldn't reach the iPhone; trying again next time."
    (( until - now < 86400 )) && notify "BitChord stops opening soon. Unlock the iPhone near this Mac, or plug it in, to keep it going."
    exit 1
fi

new=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(expiry $APP)" +%s 2>/dev/null)
print -r -- ${new:-0} > $STATE
say "Installed. Good until $(date -r ${new:-0} '+%a %d %b %H:%M')."
