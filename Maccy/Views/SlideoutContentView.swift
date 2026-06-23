import SwiftUI

struct SlideoutContentView: View {
  @Environment(AppState.self) var appState

  var body: some View {
    VStack {
      ToolbarView()

      if let item = appState.navigator.leadHistoryItem {
        PreviewItemView(item: item)
        ActionsListView(item: item)
      } else if let pasteStack = appState.history.pasteStack,
        appState.navigator.pasteStackSelected {
        PasteStackPreviewView(pasteStack: pasteStack)
      } else {
        EmptyView()
      }
    }
    .padding(.horizontal)
    .padding(.bottom)
    .padding(.top, Popup.verticalPadding)
  }

}

// Lists the actions that match the selected item in the right (preview) pane.
// Click to run, or press ⌃1…⌃9 (handled in KeyHandlingView).
struct ActionsListView: View {
  var item: HistoryItemDecorator

  @Environment(AppState.self) private var appState

  var body: some View {
    let actions = ActionEngine.shared.resolvedActions(for: item.item)
    if !actions.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Divider()
          .padding(.vertical, 4)

        Text("Actions")
          .font(.headline)

        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
          Button {
            action.run()
            appState.popup.close()
          } label: {
            HStack(spacing: 6) {
              Image(systemName: action.systemImage)
                .frame(width: 16)
              Text(index == 0 ? "\(action.title)  •  default" : action.title)
                .lineLimit(1)
              Spacer(minLength: 4)
              if index < 9 {
                Text("⌃\(index + 1)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
