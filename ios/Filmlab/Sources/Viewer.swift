import ImageIO
import SwiftUI

/// Full-screen review of recent Filmlab shots: swipe between them, zoom, change the look from the RAW, share, delete.
struct ViewerScreen: View {
    @Bindable var model: AppModel
    @State private var currentID: UUID?
    @State private var lookID: String = ""
    @State private var redeveloped: [UUID: (look: String, image: UIImage)] = [:]
    @State private var rendering = false
    @State private var chromeHidden = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var current: Shot? { model.shots.shots.first { $0.id == currentID } ?? model.shots.shots.first }

    var body: some View {
        ZStack {
            Theme.black.ignoresSafeArea()
            TabView(selection: $currentID) {
                ForEach(model.shots.shots) { shot in
                    ZoomablePhoto(url: shot.photoURL, override: redeveloped[shot.id].flatMap { $0.look == lookID ? $0.image : nil })
                        .tag(Optional(shot.id))
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { chromeHidden.toggle() } }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if !chromeHidden, let shot = current {
                VStack(spacing: 0) {
                    header(shot)
                    Spacer()
                    footer(shot)
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(chromeHidden)
        .onAppear {
            currentID = model.shots.shots.first?.id
            lookID = current?.itemID ?? ""
        }
        .onChange(of: currentID) {
            lookID = current?.itemID ?? ""
        }
        .task(id: "\(currentID?.uuidString ?? "")|\(lookID)") { await redevelopPreview() }
    }

    private func header(_ shot: Shot) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back to camera")
            Spacer()
            VStack(spacing: 0) {
                Text(shot.date, format: .dateTime.day().month(.abbreviated))
                    .font(.system(size: 15, weight: .semibold))
                Text(shot.date, format: .dateTime.hour().minute())
                    .font(Theme.din(14)).foregroundStyle(Theme.paper.opacity(0.6))
            }
            Spacer()
            Button { openURL(URL(string: "photos-redirect://")!) } label: {
                Image(systemName: "photo.on.rectangle").font(.system(size: 17)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Open Photos")
        }
        .foregroundStyle(Theme.paper)
        .padding(.horizontal, 12)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func footer(_ shot: Shot) -> some View {
        VStack(spacing: 6) {
            if shot.hasRAW {
                LookDial(items: model.items.filter { !$0.base.isNative }, selection: $lookID)
                    .frame(height: 58)
                    .overlay(alignment: .top) {
                        if rendering { ProgressView().tint(Theme.edge).scaleEffect(0.7).offset(y: -18) }
                    }
            } else {
                Text(shot.title).font(Theme.din(20)).foregroundStyle(Theme.paper).frame(height: 58)
            }
            HStack {
                Button { Task { await model.delete(shot) } } label: {
                    Image(systemName: "trash").font(.system(size: 18)).frame(width: 52, height: 52)
                }
                .accessibilityLabel("Delete photo")
                Spacer()
                if shot.hasRAW, lookID != shot.itemID, let item = model.items.first(where: { $0.id == lookID }) {
                    Button { Task { await model.saveCopy(of: shot, as: item) } } label: {
                        Text("Save copy").font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 18).frame(height: 40)
                            .background(Theme.edge, in: .capsule).foregroundStyle(Theme.black)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
                Spacer()
                ShareLink(item: shot.photoURL) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 18)).frame(width: 52, height: 52)
                }
                .accessibilityLabel("Share photo")
            }
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 16)
            .animation(.snappy(duration: 0.2), value: lookID)
        }
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    /// Re-renders the current shot from its RAW at screen size when the dial moves off the original look.
    private func redevelopPreview() async {
        guard let shot = current, shot.hasRAW, lookID != shot.itemID, redeveloped[shot.id]?.look != lookID,
              let item = model.items.first(where: { $0.id == lookID }), let dng = model.shots.raw(for: shot)
        else { return }
        try? await Task.sleep(for: .milliseconds(120)) // let the dial settle
        guard !Task.isCancelled else { return }
        rendering = true
        defer { rendering = false }
        let renderer = model.renderer
        let recipe = item.base
        let options = shot.options
        let image = await Task.detached(priority: .userInitiated) {
            renderer.previewDevelop(dng: dng, recipe: recipe, options: options, maxDimension: 2000).map { UncheckedImage(image: $0) }
        }.value
        guard !Task.isCancelled, let image else { return }
        redeveloped[shot.id] = (lookID, UIImage(cgImage: image.image))
    }
}

struct UncheckedImage: @unchecked Sendable {
    let image: CGImage
}

/// A photo that fits the screen, pinch or double-tap to zoom, drag to pan when zoomed.
struct ZoomablePhoto: View {
    let url: URL
    let override: UIImage?
    @State private var loaded: UIImage?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image = override ?? loaded {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { scale = max(1, baseScale * $0.magnification) }
                    .onEnded { _ in
                        baseScale = scale
                        if scale <= 1.01 { reset() }
                    },
                isEnabled: true
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { v in
                        guard scale > 1 else { return }
                        offset = CGSize(width: baseOffset.width + v.translation.width, height: baseOffset.height + v.translation.height)
                    }
                    .onEnded { _ in baseOffset = offset },
                isEnabled: scale > 1
            )
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    if scale > 1 {
                        reset()
                    } else {
                        scale = 2.5
                        baseScale = 2.5
                    }
                }
            }
        }
        .task(id: url) { loaded = await Self.load(url) }
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }

    private static func load(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2800,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
            else { return UncheckedImage?.none }
            return UncheckedImage(image: cg)
        }.value.map { UIImage(cgImage: $0.image) }
    }
}
