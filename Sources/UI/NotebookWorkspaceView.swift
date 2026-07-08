import SwiftUI

struct NotebookWorkspaceView: View {
    @ObservedObject var library: LibraryViewModel
    let onShowLibrary: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Divider()

            if let coordinator = library.activeCoordinator {
                NotebookDetailView(
                    coordinator: coordinator,
                    onClose: { Task { await library.close(coordinator) } },
                    onShowLibrary: onShowLibrary
                )
                .id(coordinator.notebook.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Open Notebook")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(library.openCoordinators, id: \.notebook.id) { coordinator in
                    NotebookTabButton(
                        title: coordinator.notebook.manifest.title,
                        isActive: coordinator.notebook.id == library.activeCoordinator?.notebook.id,
                        onSelect: { library.activate(coordinator) },
                        onClose: { Task { await library.close(coordinator) } }
                    )
                }

                Button(action: onShowLibrary) {
                    Label("Library", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(width: 36, height: 32)
                }
                .buttonStyle(.bordered)
                .help("Open another notebook or PDF")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

private struct NotebookTabButton: View {
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                Text(title)
                    .lineLimit(1)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Close notebook")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 32)
        .background(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: Capsule())
    }
}
