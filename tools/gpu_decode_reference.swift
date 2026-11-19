// Decodes compressed texture blocks with the GPU's own decoder (Metal, on
// an Apple silicon Mac), as a reference for the CPU decoders in
// packages/threeas/three/textures/decoders/. tools/make_texture_vectors.py
// runs it; it is not part of the library.
//
//     swiftc -O tools/gpu_decode_reference.swift -o build/gpu_decode_reference
//     build/gpu_decode_reference <metal format> <block w> <block h> <block bytes> <in.bin> <out.bin>
//
// <in.bin> holds N blocks back to back; <out.bin> gets N * w * h texels, block
// by block, rows top first, each texel four little-endian float32 (r, g, b,
// a) as the GPU sampled them (sRGB formats already converted to linear).

import Foundation
import Metal

let formats: [String: MTLPixelFormat] = [
    "bc1_rgba": .bc1_rgba, "bc2_rgba": .bc2_rgba, "bc3_rgba": .bc3_rgba,
    "bc4_rUnorm": .bc4_rUnorm, "bc4_rSnorm": .bc4_rSnorm, "bc5_rgUnorm": .bc5_rgUnorm, "bc5_rgSnorm": .bc5_rgSnorm,
    "bc7_rgbaUnorm": .bc7_rgbaUnorm,
    "etc2_rgb8": .etc2_rgb8, "etc2_rgb8a1": .etc2_rgb8a1, "eac_rgba8": .eac_rgba8,
    "eac_r11Unorm": .eac_r11Unorm, "eac_r11Snorm": .eac_r11Snorm, "eac_rg11Unorm": .eac_rg11Unorm,
    "eac_rg11Snorm": .eac_rg11Snorm,
    "astc_4x4_ldr": .astc_4x4_ldr, "astc_5x4_ldr": .astc_5x4_ldr, "astc_5x5_ldr": .astc_5x5_ldr,
    "astc_6x5_ldr": .astc_6x5_ldr, "astc_6x6_ldr": .astc_6x6_ldr, "astc_8x5_ldr": .astc_8x5_ldr,
    "astc_8x6_ldr": .astc_8x6_ldr, "astc_8x8_ldr": .astc_8x8_ldr, "astc_10x5_ldr": .astc_10x5_ldr,
    "astc_10x6_ldr": .astc_10x6_ldr, "astc_10x8_ldr": .astc_10x8_ldr, "astc_10x10_ldr": .astc_10x10_ldr,
    "astc_12x10_ldr": .astc_12x10_ldr, "astc_12x12_ldr": .astc_12x12_ldr,
    "astc_4x4_srgb": .astc_4x4_srgb, "astc_5x4_srgb": .astc_5x4_srgb, "astc_5x5_srgb": .astc_5x5_srgb,
    "astc_6x5_srgb": .astc_6x5_srgb, "astc_6x6_srgb": .astc_6x6_srgb, "astc_8x5_srgb": .astc_8x5_srgb,
    "astc_8x6_srgb": .astc_8x6_srgb, "astc_8x8_srgb": .astc_8x8_srgb, "astc_10x5_srgb": .astc_10x5_srgb,
    "astc_10x6_srgb": .astc_10x6_srgb, "astc_10x8_srgb": .astc_10x8_srgb, "astc_10x10_srgb": .astc_10x10_srgb,
    "astc_12x10_srgb": .astc_12x10_srgb, "astc_12x12_srgb": .astc_12x12_srgb,
]

let source = """
#include <metal_stdlib>
using namespace metal;
kernel void fetch(texture2d<float, access::sample> t [[texture(0)]],
                  device float4* out [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    uint w = t.get_width(), h = t.get_height();
    if (gid.x >= w || gid.y >= h) return;
    constexpr sampler s(filter::nearest, address::clamp_to_edge, coord::pixel);
    out[gid.y * w + gid.x] = t.sample(s, float2(gid) + 0.5);
}
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
if args.count != 7 { fail("usage: gpu_decode_reference <format> <bw> <bh> <block bytes> <in> <out>") }
guard let format = formats[args[1]] else { fail("unknown format " + args[1]) }
let bw = Int(args[2])!, bh = Int(args[3])!, bb = Int(args[4])!
let input = try! Data(contentsOf: URL(fileURLWithPath: args[5]))
let count = input.count / bb
let cols = min(count, 64), rows = (count + cols - 1) / cols
let width = cols * bw, height = rows * bh

guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
desc.usage = .shaderRead
desc.storageMode = .shared
guard let texture = device.makeTexture(descriptor: desc) else { fail("cannot make a " + args[1] + " texture") }
// Blocks laid out in a grid, `cols` a row; the grid's tail is zero blocks.
var grid = [UInt8](repeating: 0, count: cols * rows * bb)
input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
    for i in 0..<count {
        let gx = i % cols, gy = i / cols
        for k in 0..<bb { grid[(gy * cols + gx) * bb + k] = src[i * bb + k] }
    }
}
grid.withUnsafeBytes { p in
    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: p.baseAddress!, bytesPerRow: cols * bb)
}
let library = try! device.makeLibrary(source: source, options: nil)
let pipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "fetch")!)
let buffer = device.makeBuffer(length: width * height * 16, options: .storageModeShared)!
let queue = device.makeCommandQueue()!
let cmd = queue.makeCommandBuffer()!
let enc = cmd.makeComputeCommandEncoder()!
enc.setComputePipelineState(pipeline)
enc.setTexture(texture, index: 0)
enc.setBuffer(buffer, offset: 0, index: 0)
enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
enc.endEncoding()
cmd.commit()
cmd.waitUntilCompleted()
let texels = buffer.contents().bindMemory(to: Float.self, capacity: width * height * 4)
var out = [Float](repeating: 0, count: count * bw * bh * 4)
for i in 0..<count {
    let gx = i % cols, gy = i / cols
    for y in 0..<bh {
        for x in 0..<bw {
            let src = ((gy * bh + y) * width + gx * bw + x) * 4
            let dst = ((i * bh + y) * bw + x) * 4
            for c in 0..<4 { out[dst + c] = texels[src + c] }
        }
    }
}
out.withUnsafeBytes { p in try! Data(p).write(to: URL(fileURLWithPath: args[6])) }
