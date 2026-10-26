import Foundation
import IOKit.ps

/// Batería del Mac. Se actualiza por eventos del sistema (sin polling).
final class PowerModel: ObservableObject {
    @Published var percent = 100
    @Published var isCharging = false
    @Published var onAC = false
    @Published var hasBattery = false

    /// Se llama cuando se enchufa el cargador.
    var onPlug: (() -> Void)?
    /// Se llama al bajar del 20 % y del 10 % sin cargador.
    var onLow: (() -> Void)?

    private var warnedLevel = 100

    private var lastOnAC: Bool?
    private var source: CFRunLoopSource?

    func start() {
        update()

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx = ctx else { return }
            let model = Unmanaged<PowerModel>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                model.update()
            }
        }
        if let src = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            source = src
        }
    }

    func update() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return }

        for powerSource in list {
            guard let description = IOPSGetPowerSourceDescription(snapshot, powerSource)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let onAC = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

            hasBattery = true
            percent = maximum > 0 ? current * 100 / maximum : current
            isCharging = description[kIOPSIsChargingKey] as? Bool ?? false

            if let last = lastOnAC, !last, onAC {
                onPlug?()
            }
            lastOnAC = onAC
            self.onAC = onAC

            if onAC || percent > 25 {
                warnedLevel = 100
            } else {
                let level = percent <= 10 ? 10 : (percent <= 20 ? 20 : 100)
                if level < warnedLevel {
                    warnedLevel = level
                    onLow?()
                }
            }
        }
    }
}
