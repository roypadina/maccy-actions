import AppKit
import Defaults
import SwiftUI

struct HistoryItemView: View {
  @Bindable var item: HistoryItemDecorator
  var previous: HistoryItemDecorator?
  var next: HistoryItemDecorator?
  var index: Int

  private var visualIndex: Int? {
    if appState.navigator.isMultiSelectInProgress && item.selectionIndex >= 0 {
      return item.selectionIndex
    }
    return nil
  }

  private var selectionAppearance: SelectionAppearance {
    let previousSelected = previous?.isSelected ?? false
    let nextSelected = next?.isSelected ?? false
    switch (previousSelected, nextSelected) {
    case (true, false):
      return .topConnection
    case (false, true):
      return .bottomConnection
    case (true, true):
      return .topBottomConnection
    default:
      return .none
    }
  }

  @Environment(AppState.self) private var appState

  var body: some View {
    ListItemView(
      id: item.id,
      selectionId: item.id,
      appIcon: item.applicationImage,
      image: item.thumbnailImage,
      accessoryImage: item.thumbnailImage != nil ? nil : ColorImage.from(item.title),
      attributedTitle: item.attributedTitle,
      shortcuts: item.shortcuts,
      rowActions: rowActions,
      isSelected: item.isSelected,
      selectionIndex: visualIndex,
      selectionAppearance: selectionAppearance
    ) {
      Text(verbatim: item.title)
    }
    .onAppear {
      item.ensureThumbnailImage()
    }
    .onTapGesture {
      if NSEvent.modifierFlags.contains(.command) && appState.multiSelectionEnabled {
        appState.navigator.addToSelection(item: item)
      } else {
        Task {
          appState.history.select(item)
        }
      }
    }
    .contextMenu {
      actionsMenu
    }
  }

  @ViewBuilder
  private var actionsMenu: some View {
    if rowActions.isEmpty {
      Text("No matching actions")
    } else {
      ForEach(rowActions) { rowAction in
        Button(action: rowAction.run) {
          Label(rowAction.title, systemImage: rowAction.systemImage)
        }
      }
    }
  }

  private var rowActions: [RowActionItem] {
    item.resolvedActions.enumerated().map { index, action in
      RowActionItem(
        id: action.id,
        title: index == 0 ? "\(action.title) (default)" : action.title,
        systemImage: action.systemImage
      ) {
        action.run()
        appState.popup.close()
      }
    }
  }
}
