// What three.js types as `Color | Texture` (scene.background): Color and
// Texture both extend this empty class, so either can be assigned. Read it
// back with `instanceof Color` / `instanceof Texture`.

export abstract class ColorOrTexture {}
