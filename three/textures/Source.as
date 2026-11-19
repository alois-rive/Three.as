// three.js Source: the image data behind a texture, which textures can
// share, keyed by uuid in JSON. Here the pixels stay on the texture (a Rive
// `Image`, or a DataTexture's `data`); a Source records where they came
// from, which is what toJSON writes when it cannot read them back (Rive
// images cannot be read back).

import { Dynamic } from "rive/dynamic";
import { MathUtils } from "../math/MathUtils";

export class Source {
    readonly isSource: bool = true;
    /// Where the image came from: a data: url, an https: url or a Rive
    /// image asset's name ("" when unknown: a canvas, an artboard, a
    /// render target). Loaders set it.
    url: string = "";
    /// The six face urls of a cube texture (CubeTextureLoader,
    /// ObjectLoader).
    urls: Array<string> = [];
    version: i32 = 0;
    private _uuid: string = "";

    get uuid(): string {
        if (this._uuid.length == 0) this._uuid = MathUtils.generateUUID();
        return this._uuid;
    }
    set uuid(value: string) { this._uuid = value; }

    set needsUpdate(value: bool) { if (value) this.version++; }

    /// three.js's image JSON, { uuid, url } (url an array for a cube), or
    /// null when the url is unknown.
    toJSON(): Dynamic? {
        if (this.urls.length == 0 && this.url.length == 0) return null;
        const data = Dynamic.newTable();
        data.set("uuid", Dynamic.fromString(this.uuid));
        if (this.urls.length > 0) {
            const urls = Dynamic.newTable();
            for (let i = 0; i < this.urls.length; i++) urls.push(Dynamic.fromString(this.urls[i]));
            data.set("url", urls);
        } else {
            data.set("url", Dynamic.fromString(this.url));
        }
        return data;
    }
}
