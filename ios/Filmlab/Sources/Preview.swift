import CoreImage
import MetalKit
import SwiftUI

/// Live viewfinder: camera frames -> approximate scene-linear -> the current recipe -> screen.
///
/// Preview frames are Apple's processed video (display-referred), so they are linearised and then a
/// fixed exposure offset puts them near the ProRAW path. Captures use the real RAW pipeline.
struct LivePreview: UIViewRepresentable {
    let renderer: LookRenderer
    let frames: FrameSink
    let recipe: Recipe

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer, frames: frames) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.contentMode = .scaleAspectFill
        view.delegate = context.coordinator
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_: MTKView, context: Context) {
        context.coordinator.recipe = recipe
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        private let renderer: LookRenderer
        private let frames: FrameSink
        private let queue: MTLCommandQueue?
        var recipe: Recipe?

        init(renderer: LookRenderer, frames: FrameSink) {
            self.renderer = renderer
            self.frames = frames
            queue = device?.makeCommandQueue()
        }

        func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

        func draw(in view: MTKView) {
            guard let recipe, let buffer = frames.frame(), let drawable = view.currentDrawable,
                  let commandBuffer = queue?.makeCommandBuffer()
            else { return }
            // CVPixelBuffers from the camera carry sRGB-ish tagging; Core Image linearises into the working space.
            let source = CIImage(cvPixelBuffer: buffer)
            guard case let .success(looked) = renderer.preview(source, recipe: recipe) else { return }

            let target = view.drawableSize
            let scale = max(target.width / looked.extent.width, target.height / looked.extent.height)
            let scaled = looked.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let fitted = scaled.transformed(by: CGAffineTransform(
                translationX: (target.width - scaled.extent.width) / 2 - scaled.extent.minX,
                y: (target.height - scaled.extent.height) / 2 - scaled.extent.minY
            ))
            let destination = CIRenderDestination(
                width: Int(target.width),
                height: Int(target.height),
                pixelFormat: view.colorPixelFormat,
                commandBuffer: commandBuffer,
                mtlTextureProvider: { drawable.texture }
            )
            destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            _ = try? renderer.context.startTask(toRender: fitted, to: destination)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
