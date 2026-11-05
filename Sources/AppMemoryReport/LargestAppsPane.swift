import MemoryCore
import SwiftUI

/// The six largest apps at one point of the history, next to the RAM chart and in its style.
struct LargestAppsPane: View {
    /// The largest apps, at most six are shown.
    let apps: [RankedApp]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("Largest apps"))
                .font(.callout)
            list(apps.prefix(6))
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.black)
        .background(Color(red: 244 / 255, green: 245 / 255, blue: 245 / 255))
        .environment(\.colorScheme, .light)
    }

    private func list(_ apps: ArraySlice<RankedApp>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(apps) { app in
                HStack(spacing: 6) {
                    Image(nsImage: AppIcons.icon(for: app.appPath))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(app.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(formatBytes(app.bytes))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(app.bytes)))
                }
                .font(.callout)
            }
        }
        .animation(.snappy, value: apps.map(\.id))
        .animation(.snappy, value: apps.map(\.bytes))
    }
}
