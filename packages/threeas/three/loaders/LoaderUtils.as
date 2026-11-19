// three.js LoaderUtils: url helpers.

export class LoaderUtils {
    /// The url up to and including its last "/" ("" when there is none).
    static extractUrlBase(url: string): string {
        const index = url.lastIndexOf("/");
        if (index == -1) return "./";
        return url.substring(0, index + 1);
    }

    /// `url` against `path`: absolute and data: urls stay, others are
    /// appended to `path`.
    static resolveURL(url: string, path: string): string {
        if (url.length == 0) return "";
        if (url.startsWith("http://") || url.startsWith("https://") || url.startsWith("data:") || url.startsWith("blob:")) {
            return url;
        }
        if (url.startsWith("//") && path.indexOf(":") > 0) return path.substring(0, path.indexOf(":") + 1) + url;
        if (url.startsWith("/") && path.startsWith("http")) {
            const scheme = path.indexOf("//");
            const host = path.indexOf("/", scheme + 2);
            return (host > 0 ? path.substring(0, host) : path) + url;
        }
        return path + url;
    }

    /// Whether `url` is fetched over the network (else it names a Rive asset).
    static isURL(url: string): bool {
        return url.startsWith("https://") || url.startsWith("http://");
    }
}
