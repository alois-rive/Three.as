// What three.js types as `Color | Texture` (scene.background): Color and
// Texture both extend this class, so either can be assigned. Read it back
// with `instanceof Color` / `instanceof Texture`. It dispatches events, so
// Texture is an EventDispatcher, as three.js.

import { EventDispatcher } from "./EventDispatcher";

export abstract class ColorOrTexture extends EventDispatcher {}
