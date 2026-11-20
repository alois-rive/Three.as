// three.js FileLoader, over Rive: `loadAsync(url)` fetches an https: url
// (rive/net fetch, where the host allows the network) or reads the blob
// asset of that name, and resolves with its bytes; `loadTextAsync` with its
// text (three.js picks by responseType; AnimaScript has no unions).

import { Context } from "rive/host";
import { fetch, FetchOptions, Response } from "rive/net";
import { Promise } from "rive/promise";
import { Loader } from "./Loader";
import { LoadingManager } from "./LoadingManager";
import { LoaderUtils } from "./LoaderUtils";

export class FileLoader extends Loader {
    responseType: string = "arraybuffer";
    mimeType: string = "";

    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    setResponseType(value: string): FileLoader { this.responseType = value; return this; }
    setMimeType(value: string): FileLoader { this.mimeType = value; return this; }

    loadAsync(url: string): Promise<ArrayBuffer> {
        return fetchBytes(this, url);
    }

    loadTextAsync(url: string): Promise<string> {
        return fetchBytes(this, url).map<string>((bytes: ArrayBuffer): string => String.UTF8.decode(bytes));
    }
}

/// The bytes of `url` (resolved against the loader's path and its manager's
/// rewrites): fetched when it is an http(s) url, else the blob asset of
/// that name. Reports to the manager.
export async function fetchBytes(loader: Loader, url: string, path: string? = null): Promise<ArrayBuffer> {
    const resolved = loader.manager.resolveURL(LoaderUtils.resolveURL(url, path != null ? path! : loader.path));
    const manager = loader.manager;
    manager.itemStart(resolved);
    if (!LoaderUtils.isURL(resolved)) {
        const context = loader.context;
        const bytesAsset = context != null ? context.blob(resolved) : null;
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes == null) {
            manager.itemError(resolved);
            manager.itemEnd(resolved);
            return await Promise.reject<ArrayBuffer>("no blob asset named '" + resolved + "'");
        }
        manager.itemEnd(resolved);
        return bytes!;
    }
    const options = new FetchOptions();
    if (loader.requestHeader.size > 0) options.headers = loader.requestHeader;
    const settled = await fetch(resolved, options).settled();
    if (!settled.ok) {
        manager.itemError(resolved);
        manager.itemEnd(resolved);
        return await Promise.reject<ArrayBuffer>(resolved + ": " + settled.error);
    }
    const response: Response = settled.value;
    if (!response.ok) {
        manager.itemError(resolved);
        manager.itemEnd(resolved);
        return await Promise.reject<ArrayBuffer>(resolved + ": HTTP " + response.status.toString() + " " + response.statusText);
    }
    const bodySettled = await response.arrayBuffer().settled();
    if (!bodySettled.ok) {
        manager.itemError(resolved);
        manager.itemEnd(resolved);
        return await Promise.reject<ArrayBuffer>(resolved + ": " + bodySettled.error);
    }
    manager.itemEnd(resolved);
    return bodySettled.value;
}
