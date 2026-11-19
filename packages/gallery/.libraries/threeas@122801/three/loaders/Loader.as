// three.js Loader: the base of every loader, with the Rive context they load
// assets through. `path` prefixes names and urls; `resourcePath` is where a
// file's own references (a .gltf's buffers and images) resolve.

import { Context } from "rive/host";
import { LoadingManager, DefaultLoadingManager } from "./LoadingManager";

export class Loader {
    static readonly DEFAULT_MATERIAL_NAME: string = "__DEFAULT";

    context: Context?;
    manager: LoadingManager;
    crossOrigin: string = "anonymous";
    withCredentials: bool = false;
    path: string = "";
    resourcePath: string = "";
    requestHeader: Map<string, string> = new Map<string, string>();

    constructor(context: Context? = null, manager: LoadingManager? = null) {
        this.context = context;
        this.manager = manager != null ? manager! : DefaultLoadingManager;
    }

    setCrossOrigin(crossOrigin: string): Loader { this.crossOrigin = crossOrigin; return this; }
    setWithCredentials(value: bool): Loader { this.withCredentials = value; return this; }
    setPath(path: string): Loader { this.path = path; return this; }
    setResourcePath(resourcePath: string): Loader { this.resourcePath = resourcePath; return this; }
    setRequestHeader(requestHeader: Map<string, string>): Loader { this.requestHeader = requestHeader; return this; }
}
