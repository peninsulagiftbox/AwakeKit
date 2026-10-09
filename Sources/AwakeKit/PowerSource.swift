import Foundation
import IOKit.ps

/// Power-source state via the IOKit power sources API.
enum PowerSource {
    /// Query the supplying source, not the battery/UPS inventory: desktops
    /// can draw AC power even when that inventory is empty.
    static var isOnACPower: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        let source = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue()
        return isACPowerSource(source as String?)
    }

    static func isACPowerSource(_ source: String?) -> Bool {
        source == kIOPMACPowerKey
    }
}
