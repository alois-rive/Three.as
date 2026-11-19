// three.js DataTexture: raw texels, bottom row first (flipY false), nearest
// filtering, as three.js. `data` is a Uint8Array (UnsignedByteType), a
// Uint16Array of half floats (HalfFloatType) or a Float32Array (FloatType,
// uploaded as half floats), in RGBAFormat, RGBFormat (widened to RGBA),
// RGFormat or RedFormat. Set `needsUpdate = true` after changing `data`.

import { Context } from "rive/host";
import { GPUTexture, GPUTextureDesc, GPUTextureView } from "rive/gpu";
import { rive_gpu_texture_upload_v1 } from "rive/bindings";
import { Texture } from "./Texture";
import { Dynamic } from "rive/dynamic";
import { gpuFormat, isFloatType, uploadBytes } from "./DataUpload";
import { NearestFilter, RGBAFormat, UnsignedByteType } from "../constants";

const uploadRegion = new rive_gpu_texture_upload_v1();

export class DataTexture extends Texture {
    readonly isDataTexture: bool = true;
    data: ArrayBufferView;
    dataWidth: u32;
    dataHeight: u32;

    private gpuTexture: GPUTexture? = null;
    private gpuView: GPUTextureView? = null;
    private uploadedVersion: i32 = -1;

    constructor(data: ArrayBufferView, width: u32, height: u32, format: i32 = RGBAFormat,
                type: i32 = UnsignedByteType) {
        super(null);
        this.data = data;
        this.dataWidth = width;
        this.dataHeight = height;
        this.format = format;
        this.type = type;
        this.magFilter = NearestFilter;
        this.minFilter = NearestFilter;
        this.generateMipmaps = false;
        this.flipY = false;
        this.version = 1;
    }

    /// The source's url when it has one (a decoded image), else three.js's
    /// data image: { uuid, url: { data, width, height, type } } (the texels
    /// as numbers; type "Uint8Array", "Uint16Array" or "Float32Array").
    override imageToJSON(): Dynamic? {
        if (this.source.url.length > 0) return super.imageToJSON();
        const image = Dynamic.newTable();
        image.set("uuid", Dynamic.fromString(this.source.uuid));
        const json = Dynamic.newTable();
        image.set("url", json);
        const d = this.data;
        let values: Array<f64> = [];
        let type = "Uint8Array";
        if (d instanceof Float32Array) {
            const a = d as Float32Array;
            values = new Array<f64>(a.length);
            for (let i = 0; i < a.length; i++) values[i] = <f64>a[i];
            type = "Float32Array";
        } else if (d instanceof Uint16Array) {
            const a = d as Uint16Array;
            values = new Array<f64>(a.length);
            for (let i = 0; i < a.length; i++) values[i] = <f64>a[i];
            type = "Uint16Array";
        } else if (d instanceof Uint8Array) {
            const a = d as Uint8Array;
            values = new Array<f64>(a.length);
            for (let i = 0; i < a.length; i++) values[i] = <f64>a[i];
        }
        json.set("data", Dynamic.fromNumbers(values));
        json.set("width", Dynamic.fromNumber(<f64>this.dataWidth));
        json.set("height", Dynamic.fromNumber(<f64>this.dataHeight));
        json.set("type", Dynamic.fromString(type));
        return image;
    }

    override get width(): u32 { return this.dataWidth; }
    override get height(): u32 { return this.dataHeight; }
    override get isHDRSource(): bool { return isFloatType(this.type); }

    override update(context: Context): void {
        if (this.uploadedVersion == this.version) return;
        if (this.dataWidth == 0 || this.dataHeight == 0) return;
        const format = gpuFormat(this.format, this.type);
        let tex = this.gpuTexture;
        if (tex == null || tex.width != this.dataWidth || tex.height != this.dataHeight || tex.format != format) {
            if (tex != null) tex.release();
            const desc = new GPUTextureDesc();
            desc.width = this.dataWidth;
            desc.height = this.dataHeight;
            desc.format = format;
            tex = new GPUTexture(desc);
            this.gpuTexture = tex;
            this.gpuView = tex.view();
        }
        uploadRegion.width = this.dataWidth;
        uploadRegion.height = this.dataHeight;
        tex.upload(uploadRegion, uploadBytes(this.data, this.format, this.type,
            <i32>(this.dataWidth * this.dataHeight)));
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
