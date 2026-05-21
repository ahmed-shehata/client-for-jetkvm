import Foundation

/// Maps printable characters to USB HID key codes and modifier bytes for a US keyboard layout.
///
/// Each entry returns the HID keycode and modifier byte needed to type that character.
/// Used by the paste feature to convert clipboard text into keyboard macro steps.
extension KeyMapping {

    struct HIDCharInfo {
        let keycode: UInt8
        let modifier: UInt8
    }

    /// Look up the HID keycode and modifier needed to type a character on a US keyboard layout.
    static func hidInfo(for character: Character) -> HIDCharInfo? {
        return usCharacterMap[character]
    }

    // MARK: - US Keyboard Layout Character Map

    private static let usCharacterMap: [Character: HIDCharInfo] = {
        var map: [Character: HIDCharInfo] = [:]

        // Letters (lowercase = no modifier, uppercase = shift)
        for offset: UInt8 in 0..<26 {
            let lower = Character(UnicodeScalar(0x61 + offset))  // a-z
            let upper = Character(UnicodeScalar(0x41 + offset))  // A-Z
            let keycode: UInt8 = 0x04 + offset                  // HID a=0x04 .. z=0x1D
            map[lower] = HIDCharInfo(keycode: keycode, modifier: 0)
            map[upper] = HIDCharInfo(keycode: keycode, modifier: modLeftShift)
        }

        // Numbers (no modifier)
        // HID: 1=0x1E, 2=0x1F, ..., 9=0x26, 0=0x27
        let digits: [(Character, UInt8)] = [
            ("1", 0x1E), ("2", 0x1F), ("3", 0x20), ("4", 0x21), ("5", 0x22),
            ("6", 0x23), ("7", 0x24), ("8", 0x25), ("9", 0x26), ("0", 0x27),
        ]
        for (char, keycode) in digits {
            map[char] = HIDCharInfo(keycode: keycode, modifier: 0)
        }

        // Shifted number row symbols
        let shiftedDigits: [(Character, UInt8)] = [
            ("!", 0x1E), ("@", 0x1F), ("#", 0x20), ("$", 0x21), ("%", 0x22),
            ("^", 0x23), ("&", 0x24), ("*", 0x25), ("(", 0x26), (")", 0x27),
        ]
        for (char, keycode) in shiftedDigits {
            map[char] = HIDCharInfo(keycode: keycode, modifier: modLeftShift)
        }

        // Punctuation and special keys (unshifted)
        let unshifted: [(Character, UInt8)] = [
            ("-", 0x2D), ("=", 0x2E), ("[", 0x2F), ("]", 0x30), ("\\", 0x31),
            (";", 0x33), ("'", 0x34), ("`", 0x35), (",", 0x36), (".", 0x37),
            ("/", 0x38),
        ]
        for (char, keycode) in unshifted {
            map[char] = HIDCharInfo(keycode: keycode, modifier: 0)
        }

        // Punctuation and special keys (shifted)
        let shifted: [(Character, UInt8)] = [
            ("_", 0x2D), ("+", 0x2E), ("{", 0x2F), ("}", 0x30), ("|", 0x31),
            (":", 0x33), ("\"", 0x34), ("~", 0x35), ("<", 0x36), (">", 0x37),
            ("?", 0x38),
        ]
        for (char, keycode) in shifted {
            map[char] = HIDCharInfo(keycode: keycode, modifier: modLeftShift)
        }

        // Whitespace and control characters
        map[" "] = HIDCharInfo(keycode: 0x2C, modifier: 0)   // Space
        map["\t"] = HIDCharInfo(keycode: 0x2B, modifier: 0)  // Tab
        map["\n"] = HIDCharInfo(keycode: 0x28, modifier: 0)  // Return/Enter
        map["\r"] = HIDCharInfo(keycode: 0x28, modifier: 0)  // Carriage return → Enter

        return map
    }()
}
