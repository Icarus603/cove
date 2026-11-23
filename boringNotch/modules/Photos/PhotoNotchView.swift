//
//  PhotoNotchView.swift
//  boringNotch
//
//  The Photos tab in the notch: a quick look. Recent photos (or an album's) in a strip you scroll sideways; a click opens
//  that photo in the photo window, where the real work happens. Photos dropped on the tab are added to the library.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class PhotoNotchModel: ObservableObject {
    static let shared = PhotoNotchModel()

    @Published var scope: PhotoScope = .all { didSet { reload() } }
    @Published private(set) var ids: [Int64] = []
    private var observer: AnyCancellable?
    private var task: Task<Void, Never>?

    private init() {
        observer = PhotoLibrary.shared.$revision.dropFirst().sink { [weak self] _ in self?.reload() }
        reload()
    }

    /// The most recent photos only: a strip, not the whole library (that is what the window is for).
    func reload() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            // An album shows its photos in the order the user arranged; all photos, the newest first.
            let isAlbum: Bool = { if case .album = scope { return true } else { return false } }()
            let all = await PhotoLibrary.shared.ids(scope: scope, sort: isAlbum ? .manual : .takenNewest)
            guard !Task.isCancelled else { return }
            ids = Array(all.prefix(300))
            if case .album(let id) = scope, !PhotoLibrary.shared.albums.contains(where: { $0.id == id }) { scope = .all }
        }
    }
}

struct PhotoNotchView: View {
    @ObservedObject private var library = PhotoLibrary.shared
    @ObservedObject private var model = PhotoNotchModel.shared

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                header
                if library.photoCount == 0 && library.importProgress == nil { empty } else { strip }
                if let progress = library.importProgress {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).progressViewStyle(.linear).tint(.effectiveAccent)
                        Text("Adding \(progress.done) / \(progress.total)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    }
                } else if let summary = library.lastSummary {
                    ImportReportBar(report: summary.report, compact: true) { library.lastSummary = nil }
                }
            }
            .padding(.horizontal, 6)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    chip(String(localized: "All Photos"), count: library.photoCount, selected: model.scope == .all) { model.scope = .all }
                    ForEach(library.albums) { album in
                        chip(album.name, count: album.count, selected: model.scope == .album(album.id)) { model.scope = .album(album.id) }
                    }
                }
            }
            Button { PhotoActions.chooseFilesToAdd() } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.92)))
                    .foregroundStyle(Color.black)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain).help(Text("Add photos or folders"))
            Button { PhotoWindowController.shared.show(scope: model.scope) } label: {
                Label("Open Photos", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.92)))
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 26)
    }

    private func chip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Text("\(count)").foregroundStyle(selected ? Color.black.opacity(0.55) : Color.secondary)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(selected ? Color.white.opacity(0.92) : Color.white.opacity(0.1)))
            .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    // MARK: Body

    private var strip: some View {
        Group {
            if model.ids.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "rectangle.stack").font(.system(size: 20)).foregroundStyle(.secondary)
                    Text("This album is empty.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: [GridItem(.fixed(104), spacing: 4), GridItem(.fixed(104), spacing: 4)], spacing: 4) {
                        ForEach(model.ids, id: \.self) { id in
                            PhotoCell(id: id, size: 104)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .onTapGesture { PhotoWindowController.shared.show(scope: model.scope, photo: id) }
                        }
                    }
                }
                .frame(height: 212)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Your photo library is empty").font(.system(size: 12, weight: .semibold))
            Text("Use Add to put photos or folders in the library. Your files stay where they are.").font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("JPEG · PNG · HEIC · TIFF · GIF · WebP · BMP").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}
