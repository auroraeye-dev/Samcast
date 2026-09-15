import SwiftUI

/// First-run setup: shows exactly which permissions are missing, why they are
/// needed, and a button that goes straight to the right place.
struct PermissionsView: View {
    @ObservedObject var permissions: Permissions

    var body: some View {
        VStack(spacing: 18) {
            Text("🦆")
                .font(.system(size: 64))
            Text("Set up Samcast")
                .font(.title2).bold()
            Text("Samcast needs two permissions from macOS. It never sends anything over the internet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            VStack(spacing: 10) {
                row(title: "Camera",
                    reason: "Reads your hand gestures.",
                    state: permissions.camera,
                    action: permissions.camera == .notDetermined ? "Allow" : "Open Settings") {
                        permissions.camera == .notDetermined
                            ? permissions.requestCamera()
                            : permissions.openCameraSettings()
                    }

                row(title: "Screen Recording",
                    reason: "Captures the screen to share and to take screenshots.",
                    state: permissions.screenRecordingFailed ? .denied : permissions.screenRecording,
                    action: "Open Settings") {
                        permissions.requestScreenRecording()
                    }
            }
            .frame(maxWidth: 520)

            VStack(spacing: 6) {
                Text("After enabling Screen Recording, macOS requires a restart of the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Re-check") { permissions.refresh() }
                    Button("Relaunch Samcast") { permissions.relaunch() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
        }
        .padding(28)
    }

    private func row(title: String,
                     reason: String,
                     state: Permissions.State,
                     action: String,
                     perform: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(state == .granted ? Color.green : Color.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state == .granted {
                Text("Granted").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(action, action: perform)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.10)))
    }
}
