import AVKit
import SwiftUI

@main
struct FilmlabApp: App {
    private let model = AppModel.make()

    init() { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }

    var body: some Scene {
        WindowGroup {
            switch model {
            case let .success(model): CameraScreen(model: model)
            case let .failure(error): Text(error.message).foregroundStyle(Theme.paper).padding().background(Theme.black)
            }
        }
    }
}

struct CameraScreen: View {
    @Bindable var model: AppModel
    @State private var showPanel = false
    @Namespace private var zoom

    var body: some View {
        VStack(spacing: 0) {
            topBand
            Viewfinder(model: model, showPanel: $showPanel)
                .frame(width: screenWidth, height: screenWidth * 4 / 3)
            Group {
                if model.adjusting {
                    TickRuler(param: model.adjustParam, value: $model.recipe[model.adjustParam])
                } else {
                    LookDial(items: model.items, selection: Binding(
                        get: { model.selectedID },
                        set: { id in if let item = model.items.first(where: { $0.id == id }) { model.select(item) } }
                    ))
                }
            }
            .frame(height: 58)
            .transition(.opacity)
            controls
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.black)
        .animation(.snappy(duration: 0.22), value: model.adjusting)
        .task { await model.start() }
        .fullScreenCover(isPresented: $model.viewing) {
            ViewerScreen(model: model).navigationTransition(.zoom(sourceID: "last", in: zoom))
        }
        .onCameraCaptureEvent { event in
            if event.phase == .ended { model.shutter() }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.blink)
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }

    private var topBand: some View {
        HStack {
            Spacer()
            HStack(spacing: 2) {
                pillButton(flashIcon, on: model.flash == .on, label: "Flash \(model.flash.rawValue)") { model.flash = model.flash.next }
                pillButton("camera.filters", on: model.adjusting, label: "Adjust look") {
                    showPanel = false
                    model.adjusting.toggle()
                }
                .disabled(model.recipe.isNative)
                .opacity(model.recipe.isNative ? 0.35 : 1)
                pillButton("ellipsis", on: showPanel, label: "More controls") {
                    model.adjusting = false
                    showPanel.toggle()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 44)
            .background(Theme.paper.opacity(0.1), in: .capsule)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private var flashIcon: String {
        switch model.flash {
        case .off: "bolt.slash.fill"
        case .auto: "bolt.badge.automatic.fill"
        case .on: "bolt.fill"
        }
    }

    private func pillButton(_ icon: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 42, height: 40)
                .foregroundStyle(on ? Theme.edge : Theme.paper)
        }
        .accessibilityLabel(label)
    }

    private var controls: some View {
        HStack {
            Button { if !model.shots.shots.isEmpty { model.viewing = true } } label: { lastShot }
                .matchedTransitionSource(id: "last", in: zoom)
                .accessibilityLabel("View photos")
            Spacer()
            ShutterButton(busy: model.countdown != nil) { model.shutter() }
                .disabled(model.status != .ready)
            Spacer()
            Button { Task { await model.flipCamera() } } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 56, height: 56)
                    .background(Theme.paper.opacity(0.1), in: .circle)
                    .foregroundStyle(Theme.paper)
            }
            .accessibilityLabel(model.front ? "Use rear camera" : "Use front camera")
        }
        .padding(.horizontal, 30)
        .frame(height: 112)
    }

    private var screenWidth: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 402
    }

    private var lastShot: some View {
        ZStack {
            if let image = model.lastShot {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Theme.paper.opacity(0.1)
            }
            if model.developing > 0 {
                Theme.black.opacity(0.45)
                ProgressView().tint(Theme.edge)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(.circle)
    }
}

// MARK: - Viewfinder

struct Viewfinder: View {
    @Bindable var model: AppModel
    @Binding var showPanel: Bool
    @State private var blinkOpacity = 0.0
    @State private var pinchStart: Double?
    @State private var lastDrag: CGSize = .zero
    @State private var dragAxis: Axis?
    @State private var showLookName = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                LivePreview(renderer: model.renderer, frames: model.camera.frames, recipe: model.recipe)
                AspectMask(aspect: model.aspect)
                if model.settings.grid { Grid().stroke(Theme.paper.opacity(0.3), lineWidth: 0.5).allowsHitTesting(false) }
                if model.settings.level { LevelLine(roll: model.level.roll) }
                if let p = model.focusPoint {
                    FocusMark(locked: model.locked, bias: model.bias)
                        .id(p.x + p.y)
                        .position(x: p.x * size.width, y: p.y * size.height)
                }
                if let n = model.countdown {
                    Text("\(n)").font(Theme.din(150)).foregroundStyle(Theme.paper).contentTransition(.numericText(countsDown: true))
                }
                Theme.black.opacity(blinkOpacity).allowsHitTesting(false)
            }
            .contentShape(.rect)
            .gesture(gestures(size: size))
            .simultaneousGesture(magnify)
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if showLookName {
                        Text(model.selectedItem.title)
                            .font(Theme.din(30))
                            .foregroundStyle(Theme.paper)
                            .shadow(color: .black.opacity(0.5), radius: 8)
                            .transition(.opacity)
                    }
                    if model.adjusting {
                        ParamChips(model: model)
                    } else if !model.front {
                        LensBar(model: model)
                    }
                }
                .padding(.bottom, 12)
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if showPanel { QuickPanel(model: model).transition(.move(edge: .top).combined(with: .opacity)) }
                    StatusMessage(model: model)
                }
                .padding(.top, 10)
            }
        }
        .clipped()
        .animation(.snappy(duration: 0.22), value: showPanel)
        .onChange(of: model.blink) {
            blinkOpacity = 1
            withAnimation(.easeOut(duration: 0.18)) { blinkOpacity = 0 }
        }
        .task(id: model.selectedID) {
            guard model.status == .ready else { return }
            withAnimation(.easeOut(duration: 0.15)) { showLookName = true }
            try? await Task.sleep(for: .seconds(1.1))
            withAnimation(.easeIn(duration: 0.4)) { showLookName = false }
        }
    }

    private func gestures(size: CGSize) -> some Gesture {
        let tap = SpatialTapGesture().onEnded { value in
            if showPanel { showPanel = false; return }
            model.focus(at: normalised(value.location, size), lock: false)
        }
        let hold = LongPressGesture(minimumDuration: 0.5).sequenced(before: DragGesture(minimumDistance: 0))
            .onEnded { value in
                if case let .second(true, drag?) = value { model.focus(at: normalised(drag.location, size), lock: true) }
            }
        // Vertical drag (after focusing) sets exposure; a horizontal swipe changes look.
        let drag = DragGesture(minimumDistance: 14)
            .onChanged { value in
                let t = value.translation
                if dragAxis == nil { dragAxis = abs(t.width) > abs(t.height) ? .horizontal : .vertical }
                if dragAxis == .vertical, model.focusPoint != nil {
                    model.adjustBias(by: -Double(t.height - lastDrag.height) / 160)
                }
                lastDrag = t
            }
            .onEnded { value in
                if dragAxis == .horizontal, abs(value.translation.width) > 60 {
                    model.selectNeighbour(value.translation.width < 0 ? 1 : -1)
                }
                lastDrag = .zero
                dragAxis = nil
            }
        return drag.exclusively(before: hold.exclusively(before: tap))
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !model.front else { return }
                let start = pinchStart ?? model.zoomFactor
                pinchStart = start
                model.setZoom(start * value.magnification)
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func normalised(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
    }
}

/// Lens buttons like the built-in camera. Tap 1× repeatedly for 24, 28, 35 mm; drag sideways to zoom freely.
struct LensBar: View {
    let model: AppModel
    @State private var dragStart: Double?
    @State private var showFocal = false

    var body: some View {
        let active = model.activeStop
        let readout = model.zoomReadout
        VStack(spacing: 6) {
            if showFocal {
                Text("\(readout.mm) mm").font(Theme.din(15)).foregroundStyle(Theme.edge).padding(.top, 2).transition(.opacity)
            }
            HStack(spacing: 6) {
                ForEach(model.optics.stops) { stop in
                    let on = stop == active
                    Button { model.choose(stop) } label: {
                        Text(on ? Self.format(readout.zoom) + "×" : stop.label)
                            .font(Theme.din(on ? 17 : 15))
                            .padding(.top, 3)
                            .frame(width: on ? 46 : 36, height: on ? 46 : 36)
                            .background(Theme.black.opacity(on ? 0.5 : 0.28), in: .circle)
                            .foregroundStyle(on ? Theme.edge : Theme.paper)
                            .contentTransition(.numericText())
                    }
                    .accessibilityLabel("\(stop.label) times zoom")
                }
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        let start = dragStart ?? model.zoomFactor
                        dragStart = start
                        model.setZoom(start * exp(Double(value.translation.width) / 140))
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .animation(.snappy(duration: 0.2), value: active)
        .sensoryFeedback(.selection, trigger: active)
        .task(id: readout.mm) {
            withAnimation(.easeOut(duration: 0.15)) { showFocal = true }
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeIn(duration: 0.3)) { showFocal = false }
        }
    }

    static func format(_ z: Double) -> String {
        if z < 0.95 { return String(format: "%.1f", z).replacingOccurrences(of: "0.", with: ".") }
        return abs(z - z.rounded()) < 0.05 ? String(Int(z.rounded())) : String(format: "%.1f", z)
    }
}

/// Recipe controls shown in place of the lens buttons while adjusting.
struct ParamChips: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(RecipeParam.allCases) { param in
                        let on = param == model.adjustParam
                        let value = model.recipe[param]
                        let changed = value != model.selectedItem.base[param]
                        Button { model.adjustParam = param } label: {
                            VStack(spacing: 1) {
                                Text(model.recipe.label(for: param))
                                    .font(Theme.din(15))
                                    .foregroundStyle(changed ? Theme.edge : Theme.paper.opacity(0.6))
                                Text(param.title)
                                    .font(.system(size: 12, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on ? Theme.paper : Theme.paper.opacity(0.7))
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(on ? Theme.black.opacity(0.55) : .clear, in: .rect(cornerRadius: 12))
                        }
                        .id(param)
                    }
                    if model.isEdited {
                        Button("Reset") { model.resetRecipe() }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.edge)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onChange(of: model.adjustParam) { _, p in withAnimation { proxy.scrollTo(p, anchor: .center) } }
        }
        .background(Theme.black.opacity(0.3))
    }
}

/// Everything that isn't a look: timer, frame, grid, level, format, RAW, size, location, mirror.
struct QuickPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        let s = model.settings
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            item("timer", "Timer", model.timer == 0 ? "Off" : "\(model.timer)s", on: model.timer > 0) {
                model.timer = model.timer == 0 ? 3 : model.timer == 3 ? 10 : 0
            }
            item("aspectratio", "Frame", model.aspect.rawValue, on: model.aspect != .standard) {
                let all = Aspect.allCases
                model.settings.aspect = all[(all.firstIndex(of: model.aspect)! + 1) % all.count].rawValue
            }
            item("grid", "Grid", s.grid ? "On" : "Off", on: s.grid) { model.settings.grid.toggle() }
            item("level", "Level", s.level ? "On" : "Off", on: s.level) { model.settings.level.toggle() }
            item("photo", "Format", s.format, on: s.format != "HEIF") {
                model.settings.format = s.format == "HEIF" ? "JPEG" : "HEIF"
            }
            item("r.square", "RAW", s.keepRAW ? "Keep" : "Off", on: s.keepRAW) { model.settings.keepRAW.toggle() }
            item("square.resize", "Size", s.highRes ? "48 MP" : "12 MP", on: s.highRes) { model.settings.highRes.toggle() }
            item("location", "Location", s.geotag ? "On" : "Off", on: s.geotag) { model.settings.geotag.toggle() }
            item("person.crop.rectangle", "Selfie", s.mirrorFront ? "Mirrored" : "As seen", on: s.mirrorFront) {
                model.settings.mirrorFront.toggle()
            }
        }
        .padding(10)
        .background(Theme.black.opacity(0.72), in: .rect(cornerRadius: 22))
        .padding(.horizontal, 12)
    }

    private func item(_ icon: String, _ title: String, _ value: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17))
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.paper.opacity(0.7))
                Text(value).font(Theme.din(15)).foregroundStyle(on ? Theme.edge : Theme.paper)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(Theme.paper.opacity(0.06), in: .rect(cornerRadius: 14))
            .foregroundStyle(Theme.paper)
        }
        .sensoryFeedback(.selection, trigger: value)
    }
}

struct StatusMessage: View {
    let model: AppModel

    var body: some View {
        if case let .failed(message) = model.status {
            bubble(message)
        } else if let message = model.toast {
            bubble(message).transition(.opacity)
        }
    }

    private func bubble(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.medium)).multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.black.opacity(0.75), in: .rect(cornerRadius: 12))
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 24)
    }
}

/// Darkens what falls outside the chosen frame, inside the 3:4 sensor view.
struct AspectMask: View {
    let aspect: Aspect

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let (cw, ch): (Double, Double) = h / w > aspect.ratio ? (w, w * aspect.ratio) : (h / aspect.ratio, h)
            Path { p in
                p.addRect(CGRect(origin: .zero, size: geo.size))
                p.addRect(CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch))
            }
            .fill(Theme.black.opacity(0.75), style: FillStyle(eoFill: true))
            .animation(.snappy(duration: 0.25), value: aspect)
        }
        .allowsHitTesting(false)
    }
}

struct Grid: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            for i in 1...2 {
                let x = r.minX + r.width * Double(i) / 3, y = r.minY + r.height * Double(i) / 3
                p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
            }
        }
    }
}

/// A short horizon line that appears near level and turns amber when level.
struct LevelLine: View {
    let roll: Double

    var body: some View {
        let level = abs(roll) < 1
        if abs(roll) < 12 {
            HStack(spacing: 0) {
                Rectangle().frame(width: 34, height: 1)
                Rectangle().frame(width: 66, height: 1.5).opacity(level ? 1 : 0)
                Rectangle().frame(width: 34, height: 1)
            }
            .foregroundStyle(level ? Theme.edge : Theme.paper.opacity(0.75))
            .rotationEffect(.degrees(level ? 0 : roll))
            .allowsHitTesting(false)
        }
    }
}

struct FocusMark: View {
    let locked: Bool
    let bias: Double
    @State private var settle = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle().stroke(Theme.edge, lineWidth: 1).frame(width: 70, height: 70)
                .scaleEffect(settle ? 1 : 1.25)
            VStack(alignment: .leading, spacing: 0) {
                if locked { Text("Locked").font(.caption2.weight(.semibold)) }
                if bias != 0 { Text(String(format: "%+.1f", bias)).font(Theme.din(15)) }
            }
            .foregroundStyle(Theme.edge)
            .fixedSize()
            .offset(x: 48, y: -2)
        }
        .onAppear { withAnimation(.spring(duration: 0.3)) { settle = true } }
        .allowsHitTesting(false)
    }
}

// MARK: - Dials

/// The looks, as a dial you turn with your thumb. The centred name is the selection.
struct LookDial: View {
    let items: [StripItem]
    @Binding var selection: String
    @State private var centred: String?
    private let itemWidth: CGFloat = 112

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(items) { item in
                        let on = item.id == selection
                        HStack(spacing: 0) {
                            Ticks().frame(width: 18)
                            VStack(spacing: 1) {
                                Text(item.edge.isEmpty ? " " : item.edge).font(Theme.din(11)).foregroundStyle(Theme.edge.opacity(on ? 1 : 0.55))
                                Text(item.title).font(Theme.din(on ? 19 : 16)).lineLimit(1).minimumScaleFactor(0.8)
                                    .foregroundStyle(on ? Theme.paper : Theme.paper.opacity(0.45))
                            }
                            .frame(width: itemWidth - 36)
                            Ticks().frame(width: 18)
                        }
                        .frame(width: itemWidth)
                        .contentShape(.rect)
                        .onTapGesture { withAnimation(.snappy) { centred = item.id } }
                        .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, (geo.size.width - itemWidth) / 2, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $centred, anchor: .center)
            .overlay(alignment: .top) {
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7)).foregroundStyle(Theme.edge)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2), .init(color: .black, location: 0.8), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        }
        .onAppear { centred = selection }
        .onChange(of: centred) { _, id in
            if let id, id != selection { selection = id }
        }
        .onChange(of: selection) { _, id in
            if centred != id { withAnimation(.snappy) { centred = id } }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Look")
    }
}

private struct Ticks: View {
    var body: some View {
        Canvas { ctx, size in
            stride(from: 3.0, to: size.width, by: 6).forEach { x in
                ctx.fill(Path(CGRect(x: x, y: size.height / 2 - 4, width: 1, height: 8)), with: .color(Theme.paper.opacity(0.22)))
            }
        }
    }
}

/// A ruler you scrub to set one recipe value; clicks on every step.
struct TickRuler: View {
    let param: RecipeParam
    @Binding var value: Double
    @State private var dragStart: Double?
    private let spacing: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let steps = Int(((param.range.upperBound - param.range.lowerBound) / param.step).rounded())
            let index = (value - param.range.lowerBound) / param.step
            let zeroIndex = Int(((0 - param.range.lowerBound) / param.step).rounded())
            Canvas { ctx, size in
                let mid = size.width / 2
                for i in 0...steps {
                    let x = mid + (CGFloat(i) - index) * spacing
                    guard x > -2, x < size.width + 2 else { continue }
                    let major = (i - zeroIndex) % param.major == 0
                    let h: CGFloat = i == zeroIndex ? 22 : major ? 16 : 9
                    let fade = 1 - min(abs(x - mid) / mid, 1) * 0.8
                    ctx.fill(Path(CGRect(x: x - 0.5, y: (size.height - h) / 2, width: 1, height: h)), with: .color(Theme.paper.opacity(0.55 * fade)))
                }
                ctx.fill(Path(CGRect(x: mid - 1, y: size.height / 2 - 15, width: 2, height: 30)), with: .color(Theme.edge))
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let start = dragStart ?? value
                        dragStart = start
                        let raw = start - Double(g.translation.width / spacing) * param.step
                        let snapped = (raw / param.step).rounded() * param.step
                        let clamped = min(max(snapped, param.range.lowerBound), param.range.upperBound)
                        if clamped != value { value = clamped }
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement()
        .accessibilityLabel(param.title)
        .accessibilityValue(String(format: "%.1f", value))
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? param.step : -param.step
            value = min(max(value + delta, param.range.lowerBound), param.range.upperBound)
        }
    }
}

// MARK: - Shutter

struct ShutterButton: View {
    let busy: Bool
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Theme.paper, lineWidth: 4).frame(width: 80, height: 80)
                Circle().fill(busy ? Theme.fog : .white).frame(width: 66, height: 66).scaleEffect(pressed ? 0.9 : 1)
            }
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0, pressing: { p in withAnimation(.easeOut(duration: 0.08)) { pressed = p } }, perform: {})
        .accessibilityLabel("Take photo")
    }
}
