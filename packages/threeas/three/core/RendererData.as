// What a renderer keeps for an object, material, geometry, texture, skeleton
// or render target (internal): three.js keeps it in WeakMaps keyed by the
// object; AnimaScript has no weak references, so it is kept on the object
// itself (EventDispatcher's `_gpu`, one entry per renderer index). It lives
// as long as the object does: an object dropped without dispose() takes its
// renderer state, and the GPU handles in it, with it when it is collected.
//
// The renderer subclasses it (renderers/GPURenderer, renderers/gpu/*);
// nothing here knows the renderer.

export class RendererData {
    /// The serial of the renderer that made it (GPURenderer: a renderer's
    /// serial changes when it is disposed); -1 once freed. Data whose serial
    /// is not its renderer's is ignored, and released when replaced.
    serial: i32 = -1;

    /// Releases its GPU handles now.
    release(): void {}
}
