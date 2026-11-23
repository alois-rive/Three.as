// three.js DataArrayTexture and Data3DTexture: `depth` layers (or slices)
// of width x height texels, for ShaderMaterials that declare
// texture_2d_array<f32> / texture_3d<f32>. Data and formats as DataTexture.
// `addLayerUpdate` is not ported (any change re-uploads every layer).

import { Context } from "rive/host";
import { GPUTexture, GPUTextureDesc, GPUTextureView, GPUTextureViewDesc } from "rive/gpu";
import { TextureType, TextureViewDimension } from "rive/gpu_enums";
import { rive_gpu_texture_upload_v1 } from "rive/bindings";
import { Texture } from "./Texture";
import { gpuFormat, isFloat32, isFloatType, uploadBytes } from "./DataUpload";
import { NearestFilter, RGBAFormat, UnsignedByteType, ClampToEdgeWrapping } from "../constants";

const uploadRegion = new rive_gpu_texture_upload_v1();

export class DataArrayTexture extends Texture {
    readonly isDataArrayTexture: bool = true;
    data: ArrayBufferView;
    dataWidth: u32;
    dataHeight: u32;
    depth: u32;
    wrapR: i32 = ClampToEdgeWrapping;

    protected gpuTexture: GPUTexture? = null;
    protected gpuView: GPUTextureView? = null;
    private allocatedDepth: u32 = 0;
    private uploadedVersion: i32 = -1;

    constructor(data: ArrayBufferView, width: u32 = 1, height: u32 = 1, depth: u32 = 1) {
        super(null);
        this.data = data;
        this.dataWidth = width;
        this.dataHeight = height;
        this.depth = depth;
        this.format = RGBAFormat;
        this.type = UnsignedByteType;
        this.magFilter = NearestFilter;
        this.minFilter = NearestFilter;
        this.generateMipmaps = false;
        this.flipY = false;
        this.version = 1;
    }

    override get width(): u32 { return this.dataWidth; }
    override get height(): u32 { return this.dataHeight; }
    override get isHDRSource(): bool { return isFloatType(this.type) && !isFloat32(this.type, this.internalFormat); }

    protected textureType(): TextureType { return TextureType.array2D; }
    protected viewDimension(): TextureViewDimension { return TextureViewDimension.array2D; }

    override update(context: Context): void {
        if (this.uploadedVersion == this.version) return;
        if (this.dataWidth == 0 || this.dataHeight == 0 || this.depth == 0) return;
        const format = gpuFormat(this.format, this.type, this.internalFormat);
        let tex = this.gpuTexture;
        if (tex == null || tex.width != this.dataWidth || tex.height != this.dataHeight
                || this.allocatedDepth != this.depth || tex.format != format) {
            if (tex != null) tex.release();
            const view = this.gpuView;
            if (view != null) view.release();
            const desc = new GPUTextureDesc();
            desc.width = this.dataWidth;
            desc.height = this.dataHeight;
            desc.depthOrArrayLayers = this.depth;
            desc.format = format;
            desc.textureType = this.textureType();
            tex = new GPUTexture(desc);
            this.gpuTexture = tex;
            this.allocatedDepth = this.depth;
            const vd = new GPUTextureViewDesc();
            vd.dimension = this.viewDimension();
            this.gpuView = tex.view(vd);
        }
        const bytes = uploadBytes(this.data, this.format, this.type,
            <i32>(this.dataWidth * this.dataHeight * this.depth), isFloat32(this.type, this.internalFormat));
        uploadRegion.width = this.dataWidth;
        uploadRegion.height = this.dataHeight;
        uploadRegion.depth = this.depth;
        uploadRegion.layer = 0;
        tex.upload(uploadRegion, bytes);
        this.uploadedVersion = this.version;
    }

    override getView(): GPUTextureView? { return this.gpuView; }

    override dispose(): void {
        const tex = this.gpuTexture;
        if (tex != null) tex.release();
        const view = this.gpuView;
        if (view != null) view.release();
        this.gpuTexture = null;
        this.gpuView = null;
        this.allocatedDepth = 0;
        this.uploadedVersion = -1;
        super.dispose();
    }
}

/// three.js Data3DTexture (needs the device's `texture3D` feature).
export class Data3DTexture extends DataArrayTexture {
    readonly isData3DTexture: bool = true;

    constructor(data: ArrayBufferView, width: u32 = 1, height: u32 = 1, depth: u32 = 1) {
        super(data, width, height, depth);
    }

    protected override textureType(): TextureType { return TextureType.texture3D; }
    protected override viewDimension(): TextureViewDimension { return TextureViewDimension.texture3D; }
}
