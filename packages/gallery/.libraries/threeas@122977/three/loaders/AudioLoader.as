// three.js AudioLoader, over Rive. `load(name)` returns an AudioBuffer at
// once for the Rive audio asset called `name` (WAV, MP3 or FLAC: Rive
// decodes them, on a job thread, AudioSource.toBlob); the buffer fills when
// decoding ends (`buffer.ready`, `buffer.promise`), and an Audio given it
// before then starts playing once it is ready. `loadAsync(url)` resolves
// with the decoded buffer: an audio asset's name, or an https: url or blob
// asset holding WAV bytes (decoded here: Rive decodes MP3 and FLAC only from
// its audio assets, not from bytes).

import { Context } from "rive/host";
import { Promise } from "rive/promise";
import { Loader } from "./Loader";
import { LoadingManager } from "./LoadingManager";
import { LoaderUtils } from "./LoaderUtils";
import { fetchBytes } from "./FileLoader";
import { AudioBuffer } from "../audio/AudioNodes";
import { decodeSource } from "../audio/Audio";
import { decodeWAVInto } from "../audio/AudioContext";

export class AudioLoader extends Loader {
    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    /// The audio asset `name`, decoding (check `ready`, or await `promise`).
    load(name: string): AudioBuffer {
        const buffer = new AudioBuffer();
        const resolved = this.path + name;
        buffer.name = resolved;
        const context = this.context;
        const source = context != null ? context.audio(resolved) : null;
        if (source == null) {
            buffer.fail("no audio asset named '" + resolved + "'");
            this.manager.itemStart(resolved);
            this.manager.itemError(resolved);
            this.manager.itemEnd(resolved);
            if (context != null) context.log("three: AudioLoader: no audio asset named '" + resolved + "'");
            return buffer;
        }
        buffer.numberOfChannels = min<i32>(<i32>source.channels, 2);
        buffer.sampleRate = <f64>source.sampleRate;
        buffer.length = <i32>(source.duration * <f64>source.sampleRate);
        decodeSource(source, buffer);
        return buffer;
    }

    /// An audio asset by name, or WAV bytes from an https: url or a blob asset.
    loadAsync(url: string): Promise<AudioBuffer> {
        return loadAudioAsync(this, url);
    }
}

async function loadAudioAsync(loader: AudioLoader, url: string): Promise<AudioBuffer> {
    const resolved = LoaderUtils.resolveURL(url, loader.path);
    const context = loader.context;
    if (!LoaderUtils.isURL(resolved) && context != null && context.audio(resolved) != null) {
        const buffer = loader.load(url);
        return await buffer.promise;
    }
    const bytes = await fetchBytes(loader, url);
    const buffer = new AudioBuffer();
    buffer.name = resolved;
    return await decodeWAVInto(bytes, buffer);
}
