// Loader, LoadingManager and LoaderUtils: rive . --test

import { Tests } from "rive/test";
import * as THREE from "../three/Three";

class Counter extends THREE.LoadingManagerListener {
    starts: i32 = 0;
    progress: i32 = 0;
    loads: i32 = 0;
    errors: i32 = 0;
    override onStart(url: string, loaded: i32, total: i32): void { this.starts++; }
    override onProgress(url: string, loaded: i32, total: i32): void { this.progress++; }
    override onLoad(): void { this.loads++; }
    override onError(url: string): void { this.errors++; }
}

export class LoaderTests extends Tests {
    override run(): void {
        group("LoaderUtils", () => {
            test("extractUrlBase and resolveURL", (expect) => {
                expect.that(THREE.LoaderUtils.extractUrlBase("https://a.org/models/duck.gltf")).is("https://a.org/models/");
                expect.that(THREE.LoaderUtils.extractUrlBase("duck.gltf")).is("./");
                expect.that(THREE.LoaderUtils.resolveURL("duck.bin", "https://a.org/m/")).is("https://a.org/m/duck.bin");
                expect.that(THREE.LoaderUtils.resolveURL("https://b.org/x.png", "https://a.org/m/")).is("https://b.org/x.png");
                expect.that(THREE.LoaderUtils.resolveURL("/x.png", "https://a.org/m/")).is("https://a.org/x.png");
                expect.that(THREE.LoaderUtils.resolveURL("data:,x", "https://a.org/")).is("data:,x");
                expect.that(THREE.LoaderUtils.isURL("https://a.org")).is(true);
                expect.that(THREE.LoaderUtils.isURL("robot")).is(false);
            });
        });
        group("LoadingManager", () => {
            test("counts items and reports through its listener", (expect) => {
                const c = new Counter();
                const m = new THREE.LoadingManager(c);
                m.itemStart("a");
                m.itemStart("b");
                expect.that(m.isLoading).is(true);
                m.itemEnd("a");
                m.itemError("b");
                m.itemEnd("b");
                expect.that(c.starts).is(1);
                expect.that(c.progress).is(2);
                expect.that(c.loads).is(1);
                expect.that(c.errors).is(1);
                expect.that(m.isLoading).is(false);
                expect.that(m.itemsTotal).is(2);
            });
            test("rewrites urls by prefix", (expect) => {
                const m = new THREE.LoadingManager().addURLRewrite("models/", "https://cdn.example/m/");
                expect.that(m.resolveURL("models/duck.glb")).is("https://cdn.example/m/duck.glb");
                expect.that(m.resolveURL("other.glb")).is("other.glb");
            });
        });
    }
}
