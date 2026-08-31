# OrbitKVM for iPhone, iPad and Mac

**Disclaimer: This is an independent, third-party application and is not affiliated with, endorsed by, or associated with BuildJet.**

A native iOS, iPadOS and macOS client for connecting to JetKVM devices, providing remote video, keyboard, and mouse control. The iPhone interface includes trackpad-style pointer control, scrolling, right-click, click-drag, and cursor-following pinch zoom.

![Screenshot](screenshot.png)

## Features

-	Input Support: Sends touches, clicks, and keystrokes to the remote machine. Supports both on-screen and external hardware keyboards.

-	macOS Keyboard Capture: Routes system-level shortcuts (like ⌘ Space) to the remote machine instead of the local Mac. This requires Accessibility permissions (System Settings → Privacy & Security → Accessibility).

-	Custom Shortcuts: Maps key combinations (e.g., Ctrl+Alt+Del) to toolbar buttons. Shortcuts are configurable per device via the sidebar.

-	Native UI: Built with SwiftUI to support standard iPadOS multitasking and macOS windowing.

## Building from Source

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project from `project.yml`.

```bash
# Install XcodeGen if you don't have it
brew install xcodegen

# Download the pinned WebRTC binary and verify its SHA-256 checksum
./scripts/bootstrap-webrtc.sh

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open JetKVM.xcodeproj
```

Then build and run for your target (iPad or macOS) from Xcode.

The iPhone build uses the same SwiftUI and WebRTC implementation with a compact interface. Add a JetKVM by entering its hostname or IP address and port. Port 443 uses HTTPS/WSS; other ports use HTTP/WS.

Signed builds available for macos from the releases tab. 

Appstore for ipad pending review.

## License

MIT — see [LICENSE](LICENSE) for details.
