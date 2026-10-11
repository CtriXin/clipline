import AppKit

/// Where in the menu bar resting the pointer brings the line down, and for
/// how long. The whole bar is easy to hit by accident on the way to a menu;
/// the middle, around the notch, is clear of menus and icons.
enum HotZone: String, CaseIterable {
    case middle, whole, off

    static let key = "hotZone"
    static var saved: HotZone {
        get { HotZone(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .middle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var title: String {
        switch self {
        case .middle: return L("Middle of the menu bar")
        case .whole: return L("Whole menu bar")
        case .off: return L("Off (shortcut only)")
        }
    }

    /// The part of `band` (a screen's menu bar) that counts.
    func area(in band: NSRect) -> NSRect? {
        switch self {
        case .whole: return band
        case .off: return nil
        case .middle:
            // About the notch and a little either side; never under 240 pt.
            let w = max(240, band.width * 0.3)
            return NSRect(x: band.midX - w / 2, y: band.minY, width: w, height: band.height)
        }
    }

    enum Delay: Double, CaseIterable {
        case short = 0.15, normal = 0.3, long = 0.7

        static let key = "hotZoneDelay"
        static var saved: Delay {
            get { Delay(rawValue: UserDefaults.standard.double(forKey: key)) ?? .normal }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
        }

        var title: String {
            switch self {
            case .short: return L("Short")
            case .normal: return L("Normal")
            case .long: return L("Long")
            }
        }
    }
}
