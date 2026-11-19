// three.js examples/jsm/lights/RectAreaLightUniformsLib.js: three.js needs
// `init()` before RectAreaLights render; here the tables are built into
// the renderer (three/lights/RectAreaLightTables.as), so init does nothing.

export class RectAreaLightUniformsLib {
    static init(): void {}
}
