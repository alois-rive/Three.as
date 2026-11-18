// three.js LoadingManager: counts the items loaders start and finish and
// reports through a listener (three.js takes onLoad / onProgress / onError
// callbacks; AnimaScript has no closures, so override the methods of a
// LoadingManagerListener instead).
//
//     class Progress extends LoadingManagerListener {
//         override onProgress(url: string, loaded: i32, total: i32): void { ... }
//     }
//     const manager = new LoadingManager(new Progress());
//     const loader = new GLTFLoader(context, manager);

export abstract class LoadingManagerListener {
    onStart(url: string, itemsLoaded: i32, itemsTotal: i32): void {}
    onLoad(): void {}
    onProgress(url: string, itemsLoaded: i32, itemsTotal: i32): void {}
    onError(url: string): void {}
}

export class LoadingManager {
    listener: LoadingManagerListener?;
    isLoading: bool = false;
    itemsLoaded: i32 = 0;
    itemsTotal: i32 = 0;
    private urlPrefixes: Array<string> = [];
    private urlReplacements: Array<string> = [];

    constructor(listener: LoadingManagerListener? = null) {
        this.listener = listener;
    }

    itemStart(url: string): void {
        this.itemsTotal++;
        const l = this.listener;
        if (!this.isLoading && l != null) l.onStart(url, this.itemsLoaded, this.itemsTotal);
        this.isLoading = true;
    }

    itemEnd(url: string): void {
        this.itemsLoaded++;
        const l = this.listener;
        if (l != null) l.onProgress(url, this.itemsLoaded, this.itemsTotal);
        if (this.itemsLoaded == this.itemsTotal) {
            this.isLoading = false;
            if (l != null) l.onLoad();
        }
    }

    itemError(url: string): void {
        const l = this.listener;
        if (l != null) l.onError(url);
    }

    /// The url to load for `url` (setURLModifier's rewrite, by prefix here:
    /// three.js takes a callback).
    resolveURL(url: string): string {
        for (let i = 0; i < this.urlPrefixes.length; i++) {
            if (url.startsWith(this.urlPrefixes[i])) return this.urlReplacements[i] + url.substring(this.urlPrefixes[i].length);
        }
        return url;
    }

    /// Loads urls starting with `prefix` from `replacement` instead.
    addURLRewrite(prefix: string, replacement: string): LoadingManager {
        this.urlPrefixes.push(prefix);
        this.urlReplacements.push(replacement);
        return this;
    }
}

export const DefaultLoadingManager: LoadingManager = new LoadingManager();
