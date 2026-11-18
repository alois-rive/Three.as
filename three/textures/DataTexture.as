// three.js DataTexture: raw RGBA8 texels, bottom row first (flipY false),
// nearest filtering, as three.js. Set `needsUpdate = true` after changing
// `data`.

import { Context } from "rive/host";
import { GPUTexture, GPUTextureDesc, GPUTextureView } from "rive/gpu";
import { TextureFormat } from "rive/gpu_enums";
import { rive_gpu_texture_upload_v1 } from "rive/bindings";
import { Texture } from "./Texture";
import { NearestFilter, RGBAFormat } from "../constants";

const uploadRegion = new rive_gpu_texture_upload_v1();

export class DataTexture extends Texture {
    readonly isDataTexture: bool = true;
    data: Uint8Array;
    dataWidth: u32;
    dataHeight: u32;

    private gpuTexture: GPUTexture? = null;
    private gpuView: GPUTextureView? = null;
    private uploadedVersion: i32 = -1;

    /// `data` holds width x height RGBA8 texels (format must be RGBAFormat).
    constructor(data: Uint8Array, width: u32, height: u32, format: i32 = RGBAFormat) {
        super(null);
        this.data = data;
        this.dataWidth = width;
        this.dataHeight = height;
        this.format = format;
        this.magFilter = NearestFilter;
        this.minFilter = NearestFilter;
        this.generateMipmaps = false;
        this.flipY = false;
        this.version = 1;
    }

    override get width(): u32 { return this.dataWidth; }
    override get height(): u32 { return this.dataHeight; }

    override update(context: Context): void {
        if (this.uploadedVersion == this.version) return;
        if (this.dataWidth == 0 || this.dataHeight == 0) return;
        let tex = this.gpuTexture;
        if (tex == null || tex.width != this.dataWidth || tex.height != this.dataHeight) {
            if (tex != null) tex.release();
            const desc = new GPUTextureDesc();
            desc.width = this.dataWidth;
            desc.height = this.dataHeight;
            desc.format = TextureFormat.rgba8unorm;
            tex = new GPUTexture(desc);
            this.gpuTexture = tex;
            this.gpuView = tex.view();
        }
        const data = this.data;
        const bytes = data.byteOffset == 0 && data.byteLength == data.buffer.byteLength
            ? data.buffer : data.slice().buffer;
        uploadRegion.width = this.dataWidth;
        uploadRegion.height = this.dataHeight;
        tex.upload(uploadRegion, bytes);
        this.uploadedVersion = this.version;
    }

    override getView(): GPUTextureView? { return this.gpuView; }

    override dispose(): void {
        const tex = this.gpuTexture;
        if (tex != null) tex.release();
        this.gpuTexture = null;
        this.gpuView = null;
        this.uploadedVersion = -1;
        super.dispose();
    }
}
