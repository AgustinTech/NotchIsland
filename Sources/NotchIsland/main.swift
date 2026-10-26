import AppKit

UserDefaults.standard.register(defaults: [
    "hotkeyEnabled": true,
    "liveActivity": true,
    "showLyrics": true,
    "chargingPop": true,
    "haptics": true,
    "trackPeek": true,
    "devicePopup": true,
    "lowBatteryAlert": true,
    "swipeGesture": true,
    "downloadsActivity": true,
    "airdropActivity": true,
    "meetingAlerts": true,
    "clipboardHistory": true,
    "hudActivity": true,
    "hideSystemHUD": true
])

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
