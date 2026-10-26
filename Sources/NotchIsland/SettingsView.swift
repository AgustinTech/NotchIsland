import SwiftUI

/// Preferencias de apariencia; los cambios se guardan y se aplican sin reiniciar la app.
struct SettingsView: View {
    @ObservedObject var state: IslandState
    @AppStorage("visualSize") private var visualSize = IslandVisualSize.normal.rawValue
    @AppStorage("visualAnimationSpeed") private var animationSpeed = 1.0
    @AppStorage("visualReduceMotion") private var reduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "capsule.tophalf.filled")
                    .font(.system(size: 23, weight: .medium))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(.white)
                    .background(.black, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apariencia")
                        .font(.title2.bold())
                    Text("Personaliza la isla para tu pantalla y tu ritmo.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 8)

            Form {
                Section("Tamaño") {
                    Picker("Isla abierta", selection: $visualSize) {
                        ForEach(IslandVisualSize.allCases) { size in
                            Text(size.title).tag(size.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("El tamaño se adapta si una pantalla tiene menos espacio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Movimiento") {
                    Picker("Velocidad", selection: $animationSpeed) {
                        Text("Suave").tag(0.75)
                        Text("Normal").tag(1.0)
                        Text("Rápida").tag(1.5)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Reducir movimiento", isOn: $reduceMotion)
                    if systemReduceMotion {
                        Text("La preferencia de macOS para reducir movimiento también está activa.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Pestañas visibles") {
                    ForEach(IslandTab.allCases) { tab in
                        Toggle(isOn: Binding(
                            get: { state.visibleTabs.contains(tab) },
                            set: { state.setTabVisible(tab, visible: $0) }
                        )) {
                            Label(tab.title, systemImage: tab.symbol)
                        }
                        .disabled(state.visibleTabs.count == 1 && state.visibleTabs.contains(tab))
                    }
                    Text("Siempre debe quedar al menos una pestaña visible.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 420, minHeight: 500)
    }
}
