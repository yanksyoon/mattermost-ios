import SwiftUI

/// Debug-only "Surface inspector" (T26 scope §4): lists every surface, its resolved render mode,
/// and a toggle, behind one sheet.
///
/// Only present in `DEBUG` builds (callers gate on `SurfaceModeResolver.isDebug`). Each row:
///  - shows the surface tile and its live resolved mode badge (Web / Native);
///  - flags a surface whose choice comes from a `-surfaceMode` launch argument (shown, not
///    editable — the flag wins this run);
///  - offers a segmented Web/native toggle that writes a persisted override to `AppPreferences`
///    (runtime toggle), and a shield when the value is the compile-time default.
@MainActor
struct SurfaceInspector: View {
    @EnvironmentObject private var resolver: SurfaceModeResolver
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Per-surface renderer switch. Native = a SwiftUI screen card (Path B); "
                         + "Web view = the web app in WKWebView (Path A). Nothing ships "
                         + "native-by-default until its -AV validator passes; toggling a surface "
                         + "here only changes this device's run, and beats a -surfaceMode launch "
                         + "flag for that surface.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(Surface.allCases) { surface in
                    SurfaceRow(surface: surface)
                }

                Section {
                    Button(role: .destructive) {
                        resolver.clearAllOverrides()
                    } label: {
                        Text("Reset all to defaults")
                    }
                    .disabled(resolver.overrides.isEmpty)
                }
            }
            .navigationTitle("Surface Inspector")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("surfaceInspectorDone")
                }
            }
            .accessibilityIdentifier("surfaceInspector")
        }
    }
}

@MainActor
private struct SurfaceRow: View {
    let surface: Surface
    @EnvironmentObject private var resolver: SurfaceModeResolver

    private var resolved: SurfaceRenderMode { resolver.resolvedMode(for: surface) }
    private var isDefault: Bool { SurfaceDefaults.defaultMode(for: surface) == resolved }

    /// Reflects the surface's *current* resolved mode, so the picker never disagrees with the
    /// badge. Touching the picker is an explicit user action: it also drops this run's
    /// `-surfaceMode` override for the surface (see `SurfaceModeResolver.setOverride`).
    private var pickerSelection: Binding<SurfaceRenderMode> {
        Binding(
            get: { resolver.resolvedMode(for: surface) },
            set: { resolver.setOverride($0, for: surface) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(surface.title)
                    .font(.headline)
                Spacer()
                ModeBadge(mode: resolved)
            }

            HStack(spacing: 6) {
                if resolver.isLaunchOverridden(surface) {
                    Label("launch override", systemImage: "terminal")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                if isDefault {
                    Text("default: \(SurfaceDefaults.defaultMode(for: surface).rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Picker("Renderer", selection: pickerSelection) {
                Text("Web view").tag(SurfaceRenderMode.web)
                Text("Native").tag(SurfaceRenderMode.native)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("surfaceMode.\(surface.rawValue)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("surfaceRow.\(surface.rawValue)")
    }
}

/// A small resolved-mode chip (Web = blue-ish, Native = green-ish) for the inspector row.
@MainActor
private struct ModeBadge: View {
    let mode: SurfaceRenderMode

    var body: some View {
        Text(mode == .native ? "Native" : "Web view")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(mode == .native ? Color.green : Color.secondary)
            .background(
                (mode == .native ? Color.green : Color.primary).opacity(0.12),
                in: Capsule()
            )
    }
}