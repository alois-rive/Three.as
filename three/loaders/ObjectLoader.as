// three.js ObjectLoader: a scene (or any object) from three.js's JSON object
// format 4.x, as Object3D.toJSON writes it and the three.js editor saves it.
//
//     const scene = new ObjectLoader(context).load("level");      // BlobAsset
//     const copy = new ObjectLoader(context).parse(JSON.stringify(scene.toJSON()));
//     const remote = await new ObjectLoader(context).loadAsync("https://.../scene.json");
//
// Geometries are rebuilt from their parameters (BoxGeometry ... and shapes
// for Shape/ExtrudeGeometry) or read as BufferGeometry data; materials go
// through MaterialLoader, textures through their images: base64 data: urls
// (decoded by Rive, so they fill in a frame or so later; `parseAsync` /
// `loadAsync` wait for them), Rive image assets named by the url (as is,
// then its file name without extension), raw `data` arrays (DataTexture),
// and, with loadAsync, https: urls (fetched where the host allows it).

import { Context } from "rive/host";
import { Image } from "rive/image";
import { Dynamic, DynamicKind } from "rive/dynamic";
import { Promise } from "rive/promise";
import { Loader } from "./Loader";
import { LoadingManager } from "./LoadingManager";
import { LoaderUtils } from "./LoaderUtils";
import { fetchBytes } from "./FileLoader";
import { decodeTexture } from "./TextureLoader";
import { MaterialLoader } from "./MaterialLoader";
import { BufferGeometryLoader } from "./BufferGeometryLoader";
import {
    JSON, jget, jhas, jnum, jint, jbool, jstr, jarr, jitems, jnumbers, asStr, eulerFromJSON,
} from "../core/JSON";
import { Object3D } from "../core/Object3D";
import { BufferGeometry } from "../core/BufferGeometry";
import { InstancedBufferAttribute } from "../core/InstancedBufferAttribute";
import { Material } from "../materials/Material";
import { MeshBasicMaterial } from "../materials/MeshBasicMaterial";
import { SpriteMaterial } from "../materials/SpriteMaterial";
import { LineBasicMaterial } from "../materials/LineBasicMaterial";
import { PointsMaterial } from "../materials/PointsMaterial";
import { Texture } from "../textures/Texture";
import { DataTexture } from "../textures/DataTexture";
import { CubeTexture } from "../textures/CubeTexture";
import { AnimationClip } from "../animation/AnimationClip";
import { Scene } from "../scenes/Scene";
import { Fog, FogExp2 } from "../scenes/Fog";
import { Camera } from "../cameras/Camera";
import { PerspectiveCamera } from "../cameras/PerspectiveCamera";
import { OrthographicCamera } from "../cameras/OrthographicCamera";
import { AmbientLight } from "../lights/AmbientLight";
import { DirectionalLight } from "../lights/DirectionalLight";
import { PointLight } from "../lights/PointLight";
import { SpotLight } from "../lights/SpotLight";
import { RectAreaLight } from "../lights/RectAreaLight";
import { HemisphereLight } from "../lights/HemisphereLight";
import { LightProbe } from "../lights/LightProbe";
import { LightShadow } from "../lights/LightShadow";
import { Mesh } from "../objects/Mesh";
import { InstancedMesh } from "../objects/InstancedMesh";
import { SkinnedMesh } from "../objects/SkinnedMesh";
import { Bone, Skeleton } from "../objects/Skeleton";
import { Group } from "../objects/Group";
import { LOD } from "../objects/LOD";
import { Line, LineLoop, LineSegments } from "../objects/Line";
import { Points } from "../objects/Points";
import { Sprite } from "../objects/Sprite";
import { Shape } from "../extras/core/Shape";
import { Color } from "../math/Color";
import { BoxGeometry } from "../geometries/BoxGeometry";
import { CapsuleGeometry } from "../geometries/CapsuleGeometry";
import { CircleGeometry } from "../geometries/CircleGeometry";
import { ConeGeometry } from "../geometries/ConeGeometry";
import { CylinderGeometry } from "../geometries/CylinderGeometry";
import { ExtrudeGeometry } from "../geometries/ExtrudeGeometry";
import { LatheGeometry } from "../geometries/LatheGeometry";
import { PlaneGeometry } from "../geometries/PlaneGeometry";
import {
    PolyhedronGeometry, IcosahedronGeometry, OctahedronGeometry, TetrahedronGeometry, DodecahedronGeometry,
} from "../geometries/PolyhedronGeometry";
import { RingGeometry } from "../geometries/RingGeometry";
import { ShapeGeometry } from "../geometries/ShapeGeometry";
import { SphereGeometry } from "../geometries/SphereGeometry";
import { TorusGeometry } from "../geometries/TorusGeometry";
import { TorusKnotGeometry } from "../geometries/TorusKnotGeometry";
import {
    UVMapping, CubeReflectionMapping, CubeRefractionMapping, EquirectangularReflectionMapping,
    EquirectangularRefractionMapping, RepeatWrapping, ClampToEdgeWrapping, MirroredRepeatWrapping,
    NearestFilter, NearestMipmapNearestFilter, NearestMipmapLinearFilter, LinearFilter,
    LinearMipmapNearestFilter, LinearMipmapLinearFilter, FloatType, HalfFloatType, UnsignedByteType,
} from "../constants";

/// An image of a JSON document (three.js's Source), as parseImages reads
/// it: what the textures using it are made from.
export class ObjectLoaderImage {
    uuid: string = "";
    /// The url as written (a data: url, an https: url, an asset name).
    url: string = "";
    /// A cube texture's six face urls.
    urls: Array<string> = [];
    /// Encoded bytes (a data: url, or fetched by loadAsync) to decode.
    bytes: ArrayBuffer? = null;
    /// The Rive image asset the url names.
    image: Image? = null;
    /// A cube's face images (Rive image assets).
    images: Array<Image?> = [];
    /// Raw texels ({ data, width, height, type }): a DataTexture's.
    data: ArrayBufferView? = null;
    width: u32 = 0;
    height: u32 = 0;
    dataType: i32 = UnsignedByteType;
}

export class ObjectLoader extends Loader {
    /// Problems met by the last parse (unknown types, missing references,
    /// images that could not be read).
    warnings: Array<string> = [];
    /// Why the last load or parse returned null ("" when it did not).
    error: string = "";

    // Per parse: objects by uuid, and references bound once all are read.
    private objects: Map<string, Object3D> = new Map<string, Object3D>();
    private targetLights: Array<Object3D> = [];
    private targetUuids: Array<string> = [];
    private skinnedMeshes: Array<SkinnedMesh> = [];
    private skeletonUuids: Array<string> = [];
    private lodLevels: Array<LOD> = [];
    private lodJSON: Array<Dynamic?> = [];
    /// Image decodes started by the last parse (parseAsync waits for them).
    decodes: Array<Promise<Texture>> = [];

    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    /// The object in the BlobAsset `name` (`path` + name; JSON text), or
    /// null (see `error`). Images given by https: url need loadAsync.
    load(name: string): Object3D? {
        const context = this.context;
        const full = LoaderUtils.resolveURL(name, this.path);
        const bytes = context != null ? context.blob(full) : null;
        if (bytes == null) {
            this.fail("no blob asset named '" + full + "'");
            return null;
        }
        return this.parse<string>(String.UTF8.decode(bytes!));
    }

    /// The object at `url`: an https: url (fetched where the host allows
    /// the network; its images fetched from beside it or `resourcePath`),
    /// else the blob asset of that name. Resolves once every image is
    /// decoded.
    loadAsync(url: string): Promise<Object3D> {
        return loadObjectAsync(this, url);
    }

    /// An object from three.js's JSON: the text (a string) or its parsed
    /// `Dynamic` (such as Object3D.toJSON's result). Null when it is not an
    /// object document (see `error`). Images decode afterwards.
    parse<T>(json: T): Object3D? {
        const data = this.document<T>(json);
        if (data == null) return null;
        return this.parseDocument(data!, this.parseImages(jget(data, "images")));
    }

    /// As parse, resolving once every image is decoded.
    parseAsync<T>(json: T): Promise<Object3D> {
        const data = this.document<T>(json);
        if (data == null) return Promise.reject<Object3D>(this.error);
        return parseObjectAsync(this, data!, this.resourcePath);
    }

    /// Builds the scene from a parsed document and its images (internal:
    /// parse and parseAsync).
    parseDocument(json: Dynamic, images: Map<string, ObjectLoaderImage>): Object3D? {
        this.warnings = [];
        this.error = "";
        this.objects = new Map<string, Object3D>();
        this.targetLights = [];
        this.targetUuids = [];
        this.skinnedMeshes = [];
        this.skeletonUuids = [];
        this.lodLevels = [];
        this.lodJSON = [];
        this.decodes = [];
        const animations = this.parseAnimations(jget(json, "animations"));
        const shapes = this.parseShapes(jget(json, "shapes"));
        const geometries = this.parseGeometries(jget(json, "geometries"), shapes);
        const textures = this.parseTextures(jget(json, "textures"), images);
        const materials = this.parseMaterials(jget(json, "materials"), textures);
        const object = this.parseObject(jget(json, "object"), geometries, materials, textures, animations);
        const skeletons = this.parseSkeletons(jget(json, "skeletons"), object);
        this.bindSkeletons(object, skeletons);
        this.bindLightTargets(object);
        return object;
    }

    parseShapes(json: Dynamic?): Map<string, Shape> {
        const shapes = new Map<string, Shape>();
        const items = jitems(json);
        for (let i = 0; i < items.length; i++) {
            const shape = new Shape();
            shape.fromJSON(items[i]);
            shapes.set(shape.uuid, shape);
        }
        return shapes;
    }

    /// Skeletons by uuid, their bones found in `object` by uuid (a missing
    /// one becomes a new Bone, as three.js).
    parseSkeletons(json: Dynamic?, object: Object3D): Map<string, Skeleton> {
        const skeletons = new Map<string, Skeleton>();
        const bones = new Map<string, Bone>();
        const uuids = this.objects.keys();
        for (let i = 0; i < uuids.length; i++) {
            const o = this.objects.get(uuids[i]);
            if (o instanceof Bone) bones.set(uuids[i], o as Bone);
        }
        const items = jitems(json);
        for (let i = 0; i < items.length; i++) {
            const skeleton = new Skeleton().fromJSON(items[i], bones);
            skeletons.set(jstr(items[i], "uuid", skeleton.uuid), skeleton);
        }
        return skeletons;
    }

    parseGeometries(json: Dynamic?, shapes: Map<string, Shape>): Map<string, BufferGeometry> {
        const geometries = new Map<string, BufferGeometry>();
        const items = jitems(json);
        const bufferLoader = new BufferGeometryLoader(this.context);
        for (let i = 0; i < items.length; i++) {
            const data = items[i];
            let type = jstr(data, "type", "BufferGeometry");
            // Pre-r125 names (BoxBufferGeometry ...).
            if (type != "BufferGeometry" && type.endsWith("BufferGeometry")) {
                type = type.substring(0, type.length - 14) + "Geometry";
            }
            let geometry: BufferGeometry? = null;
            if (type == "BufferGeometry" || type == "InstancedBufferGeometry") {
                geometry = bufferLoader.parse<Dynamic>(data!);
                for (let k = 0; k < bufferLoader.warnings.length; k++) this.warn(bufferLoader.warnings[k]);
            } else {
                geometry = createGeometry(type, data, shapes);
                if (geometry == null && jhas(data, "data")) geometry = bufferLoader.parse<Dynamic>(data!);
                if (geometry == null) {
                    this.warn("geometry type '" + type + "' is not supported");
                    continue;
                }
            }
            const g = geometry!;
            if (jhas(data, "uuid")) g.uuid = jstr(data, "uuid", "");
            if (jhas(data, "name")) g.name = jstr(data, "name", "");
            const userData = jget(data, "userData");
            if (userData != null) g.userData = userData!;
            geometries.set(g.uuid, g);
        }
        return geometries;
    }

    parseMaterials(json: Dynamic?, textures: Map<string, Texture>): Map<string, Material> {
        const materials = new Map<string, Material>();
        const items = jitems(json);
        const loader = new MaterialLoader(this.context);
        loader.setTextures(textures);
        for (let i = 0; i < items.length; i++) {
            const uuid = jstr(items[i], "uuid", "");
            if (materials.has(uuid)) continue;
            const material = loader.parse<Dynamic>(items[i]!);
            for (let k = 0; k < loader.warnings.length; k++) this.warn(loader.warnings[k]);
            if (material != null) materials.set(material.uuid, material!);
        }
        return materials;
    }

    parseAnimations(json: Dynamic?): Map<string, AnimationClip> {
        const animations = new Map<string, AnimationClip>();
        const items = jitems(json);
        for (let i = 0; i < items.length; i++) {
            const clip = AnimationClip.parse(items[i]);
            animations.set(clip.uuid, clip);
        }
        return animations;
    }

    /// The document's images by uuid: data: urls decoded to bytes, Rive
    /// image assets looked up by name, raw data read. https: urls are left
    /// for loadAsync to fetch.
    parseImages(json: Dynamic?): Map<string, ObjectLoaderImage> {
        const images = new Map<string, ObjectLoaderImage>();
        const items = jitems(json);
        for (let i = 0; i < items.length; i++) {
            const item = items[i];
            const image = new ObjectLoaderImage();
            image.uuid = jstr(item, "uuid", "");
            const url = jget(item, "url");
            if (url != null && url.kind == DynamicKind.table && jhas(url, "data")) {
                readRawImage(image, url);
            } else if (url != null && url.kind == DynamicKind.table) {
                const urls = Dynamic.asArray(url);
                for (let k = 0; k < urls.length; k++) {
                    const u = asStr(urls[k]);
                    image.urls.push(u);
                    image.images.push(this.imageAsset(u));
                }
            } else if (url != null && url.kind == DynamicKind.string) {
                image.url = Dynamic.asString(url);
                if (image.url.startsWith("data:")) {
                    image.bytes = decodeDataURL(image.url);
                    if (image.bytes == null) this.warn("image " + image.uuid + ": not a base64 data url");
                } else if (!LoaderUtils.isURL(image.url)) {
                    image.image = this.imageAsset(image.url);
                }
            } else if (jhas(item, "data")) {
                readRawImage(image, item);
            }
            images.set(image.uuid, image);
        }
        return images;
    }

    parseTextures(json: Dynamic?, images: Map<string, ObjectLoaderImage>): Map<string, Texture> {
        const textures = new Map<string, Texture>();
        const items = jitems(json);
        for (let i = 0; i < items.length; i++) {
            const data = items[i];
            const imageUuid = jstr(data, "image", "");
            if (imageUuid.length == 0) this.warn("no image specified for texture " + jstr(data, "uuid", ""));
            else if (!images.has(imageUuid)) this.warn("undefined image " + imageUuid);
            const image = images.has(imageUuid) ? images.get(imageUuid) : null;
            const flipY = jbool(data, "flipY", true);
            let texture: Texture;
            let premultiplied = false;
            if (image == null) {
                texture = new Texture();
            } else if (image.urls.length > 0) {
                texture = new CubeTexture(image.images);
                texture.source.urls = image.urls;
                premultiplied = true;
                for (let k = 0; k < image.images.length; k++) {
                    if (image.images[k] == null) this.warn("cube face '" + image.urls[k] + "' is not an image asset");
                }
            } else if (image.data != null) {
                texture = new DataTexture(image.data!, image.width, image.height, jint(data, "format", 1023), image.dataType);
            } else if (image.bytes != null) {
                const context = this.context;
                if (context != null) {
                    const listener = decodeTexture(context, image.bytes!, flipY);
                    this.decodes.push(listener.promise);
                    texture = listener.texture;
                } else {
                    this.warn("image " + image.uuid + " needs a Context to decode");
                    texture = new Texture();
                }
                premultiplied = true;
            } else if (image.image != null) {
                texture = new Texture(image.image);
                premultiplied = true;
            } else {
                if (LoaderUtils.isURL(image.url)) this.warn("image '" + image.url + "' is a url: load with loadAsync");
                else this.warn("no image asset named '" + image.url + "'");
                texture = new Texture();
            }
            if (image != null) {
                texture.source.uuid = image.uuid;
                if (image.url.length > 0) texture.source.url = image.url;
            }
            if (jhas(data, "uuid")) texture.uuid = jstr(data, "uuid", "");
            texture.name = jstr(data, "name", texture.name);
            texture.mapping = <i32>parseConstant(jget(data, "mapping"), texture.mapping);
            texture.channel = jint(data, "channel", texture.channel);
            readTextureVector(texture, 0, jnumbers(data, "offset"));
            readTextureVector(texture, 1, jnumbers(data, "repeat"));
            readTextureVector(texture, 2, jnumbers(data, "center"));
            texture.rotation = jnum(data, "rotation", texture.rotation);
            const wrap = jget(data, "wrap");
            if (wrap != null) {
                texture.wrapS = <i32>parseConstant(Dynamic.at(wrap, 0), texture.wrapS);
                texture.wrapT = <i32>parseConstant(Dynamic.at(wrap, 1), texture.wrapT);
            }
            texture.format = jint(data, "format", texture.format);
            if (!(texture instanceof DataTexture) || image == null || image.data == null) {
                texture.type = jint(data, "type", texture.type);
            }
            texture.colorSpace = jstr(data, "colorSpace", texture.colorSpace);
            texture.minFilter = <i32>parseConstant(jget(data, "minFilter"), texture.minFilter);
            texture.magFilter = <i32>parseConstant(jget(data, "magFilter"), texture.magFilter);
            texture.anisotropy = jint(data, "anisotropy", texture.anisotropy);
            texture.flipY = flipY;
            texture.generateMipmaps = jbool(data, "generateMipmaps", texture.generateMipmaps);
            // Images Rive decodes are premultiplied (premultiplyAlpha means
            // "the source is premultiplied" here); raw data keeps the flag.
            texture.premultiplyAlpha = premultiplied ? true : jbool(data, "premultiplyAlpha", texture.premultiplyAlpha);
            const userData = jget(data, "userData");
            if (userData != null) texture.userData = userData!;
            texture.needsUpdate = true;
            textures.set(texture.uuid, texture);
        }
        return textures;
    }

    /// One object and its children (every Object3D type the project has;
    /// others load as Object3D, with a warning).
    parseObject(data: Dynamic?, geometries: Map<string, BufferGeometry>, materials: Map<string, Material>,
                textures: Map<string, Texture>, animations: Map<string, AnimationClip>): Object3D {
        const type = jstr(data, "type", "Object3D");
        let object: Object3D;
        if (type == "Scene") {
            const scene = new Scene();
            const background = jget(data, "background");
            if (background != null) {
                if (background.kind == DynamicKind.number) {
                    scene.background = Color.fromHex(<u32>Dynamic.asNumber(background));
                } else {
                    const t = this.textureNamed(textures, asStr(background));
                    if (t != null) scene.background = t;
                }
            }
            if (jhas(data, "environment")) scene.environment = this.textureNamed(textures, jstr(data, "environment", ""));
            const fog = jget(data, "fog");
            if (fog != null) {
                const fogType = jstr(fog, "type", "");
                if (fogType == "Fog") {
                    const f = new Fog(<u32>jnum(fog, "color", 0xffffff), jnum(fog, "near", 1), jnum(fog, "far", 1000));
                    f.name = jstr(fog, "name", "");
                    scene.fog = f;
                } else if (fogType == "FogExp2") {
                    const f = new FogExp2(<u32>jnum(fog, "color", 0xffffff), jnum(fog, "density", 0.00025));
                    f.name = jstr(fog, "name", "");
                    scene.fog = f;
                }
            }
            scene.backgroundBlurriness = jnum(data, "backgroundBlurriness", scene.backgroundBlurriness);
            scene.backgroundIntensity = jnum(data, "backgroundIntensity", scene.backgroundIntensity);
            eulerFromJSON(scene.backgroundRotation, jget(data, "backgroundRotation"));
            scene.environmentIntensity = jnum(data, "environmentIntensity", scene.environmentIntensity);
            eulerFromJSON(scene.environmentRotation, jget(data, "environmentRotation"));
            object = scene;
        } else if (type == "PerspectiveCamera") {
            const camera = new PerspectiveCamera(jnum(data, "fov", 50), jnum(data, "aspect", 1), jnum(data, "near", 0.1),
                jnum(data, "far", 2000));
            camera.focus = jnum(data, "focus", camera.focus);
            camera.zoom = jnum(data, "zoom", camera.zoom);
            camera.filmGauge = jnum(data, "filmGauge", camera.filmGauge);
            camera.filmOffset = jnum(data, "filmOffset", camera.filmOffset);
            camera.updateProjectionMatrix();
            object = camera;
        } else if (type == "OrthographicCamera") {
            const camera = new OrthographicCamera(jnum(data, "left", -1), jnum(data, "right", 1), jnum(data, "top", 1),
                jnum(data, "bottom", -1), jnum(data, "near", 0.1), jnum(data, "far", 2000));
            camera.zoom = jnum(data, "zoom", camera.zoom);
            camera.updateProjectionMatrix();
            object = camera;
        } else if (type == "AmbientLight") {
            object = new AmbientLight(color(data), jnum(data, "intensity", 1));
        } else if (type == "DirectionalLight") {
            object = new DirectionalLight(color(data), jnum(data, "intensity", 1));
            this.pendTarget(object, data);
        } else if (type == "PointLight") {
            object = new PointLight(color(data), jnum(data, "intensity", 1), jnum(data, "distance", 0), jnum(data, "decay", 2));
        } else if (type == "RectAreaLight") {
            object = new RectAreaLight(color(data), jnum(data, "intensity", 1), jnum(data, "width", 10), jnum(data, "height", 10));
        } else if (type == "SpotLight") {
            object = new SpotLight(color(data), jnum(data, "intensity", 1), jnum(data, "distance", 0),
                jnum(data, "angle", Math.PI / 3), jnum(data, "penumbra", 0), jnum(data, "decay", 2));
            this.pendTarget(object, data);
        } else if (type == "HemisphereLight") {
            object = new HemisphereLight(color(data), <u32>jnum(data, "groundColor", 0xffffff), jnum(data, "intensity", 1));
        } else if (type == "LightProbe") {
            const probe = new LightProbe(null, jnum(data, "intensity", 1));
            const sh = jnumbers(data, "sh");
            if (sh != null && sh.length >= 27) probe.sh.fromArray(sh!);
            object = probe;
        } else if (type == "SkinnedMesh") {
            const mesh = new SkinnedMesh(this.geometryOf(data, geometries));
            this.applyMaterials(mesh, data, materials);
            mesh.bindMode = jstr(data, "bindMode", mesh.bindMode);
            const bindMatrix = jnumbers(data, "bindMatrix");
            if (bindMatrix != null && bindMatrix.length >= 16) mesh.bindMatrix.fromArray(bindMatrix!);
            if (jhas(data, "skeleton")) {
                this.skinnedMeshes.push(mesh);
                this.skeletonUuids.push(jstr(data, "skeleton", ""));
            }
            mesh.updateMorphTargets();
            object = mesh;
        } else if (type == "Mesh") {
            const mesh = new Mesh(this.geometryOf(data, geometries));
            this.applyMaterials(mesh, data, materials);
            mesh.updateMorphTargets();
            object = mesh;
        } else if (type == "InstancedMesh") {
            const count = jint(data, "count", 1);
            const mesh = new InstancedMesh(this.geometryOf(data, geometries), new MeshBasicMaterial(), count);
            this.applyMaterials(mesh, data, materials);
            const matrices = jnumbers(jget(data, "instanceMatrix"), "array");
            if (matrices != null) {
                const a = mesh.instanceMatrix.array;
                for (let i = 0; i < matrices.length && i < a.length; i++) a[i] = <f32>matrices[i];
            }
            const colors = jnumbers(jget(data, "instanceColor"), "array");
            if (colors != null) {
                const a = new Float32Array(colors.length);
                for (let i = 0; i < colors.length; i++) a[i] = <f32>colors[i];
                mesh.instanceColor = new InstancedBufferAttribute(a, jint(jget(data, "instanceColor"), "itemSize", 3));
            }
            mesh.updateMorphTargets();
            object = mesh;
        } else if (type == "LOD") {
            const lod = new LOD();
            lod.autoUpdate = jbool(data, "autoUpdate", lod.autoUpdate);
            this.lodLevels.push(lod);
            this.lodJSON.push(data);
            object = lod;
        } else if (type == "Line" || type == "LineLoop" || type == "LineSegments") {
            const geometry = this.geometryOf(data, geometries);
            const material = this.materialOf(data, materials);
            const m = material != null ? material! : new LineBasicMaterial();
            object = type == "LineLoop" ? new LineLoop(geometry, m) : type == "LineSegments" ? new LineSegments(geometry, m)
                : new Line(geometry, m);
        } else if (type == "Points" || type == "PointCloud") {
            const material = this.materialOf(data, materials);
            object = new Points(this.geometryOf(data, geometries), material != null ? material! : new PointsMaterial());
        } else if (type == "Sprite") {
            const material = this.materialOf(data, materials);
            const sprite = new Sprite();
            if (material != null && material instanceof SpriteMaterial) sprite.material = material as SpriteMaterial;
            else if (material != null) this.warn("Sprite " + jstr(data, "uuid", "") + " has no SpriteMaterial");
            object = sprite;
        } else if (type == "Group") {
            object = new Group();
        } else if (type == "Bone") {
            object = new Bone();
        } else {
            if (type != "Object3D") this.warn("object type '" + type + "' is not supported: read as an Object3D");
            object = new Object3D();
        }

        if (jhas(data, "uuid")) object.uuid = jstr(data, "uuid", "");
        object.name = jstr(data, "name", object.name);
        const matrix = jnumbers(data, "matrix");
        if (matrix != null && matrix.length >= 16) {
            object.matrix.fromArray(matrix!);
            object.matrixAutoUpdate = jbool(data, "matrixAutoUpdate", object.matrixAutoUpdate);
            if (object.matrixAutoUpdate) object.matrix.decompose(object.position, object.quaternion, object.scale);
        } else {
            const position = jnumbers(data, "position");
            if (position != null && position.length >= 3) object.position.fromArray(position!);
            eulerFromJSON(object.rotation, jget(data, "rotation"));
            const quaternion = jnumbers(data, "quaternion");
            if (quaternion != null && quaternion.length >= 4) object.quaternion.fromArray(quaternion!);
            const scale = jnumbers(data, "scale");
            if (scale != null && scale.length >= 3) object.scale.fromArray(scale!);
        }
        const up = jnumbers(data, "up");
        if (up != null && up.length >= 3) object.up.fromArray(up!);
        object.castShadow = jbool(data, "castShadow", object.castShadow);
        object.receiveShadow = jbool(data, "receiveShadow", object.receiveShadow);
        const shadowJSON = jget(data, "shadow");
        if (shadowJSON != null) {
            const shadow = shadowOf(object);
            if (shadow != null) this.parseShadow(shadow!, shadowJSON, geometries, materials, textures, animations);
        }
        object.visible = jbool(data, "visible", object.visible);
        object.frustumCulled = jbool(data, "frustumCulled", object.frustumCulled);
        object.renderOrder = jint(data, "renderOrder", object.renderOrder);
        const userData = jget(data, "userData");
        if (userData != null) object.userData = userData!;
        if (jhas(data, "layers")) object.layers.mask = <u32>jnum(data, "layers", 1);
        this.objects.set(object.uuid, object);

        const children = jarr(data, "children");
        for (let i = 0; i < children.length; i++) {
            object.add(this.parseObject(children[i], geometries, materials, textures, animations));
        }
        const clips = jarr(data, "animations");
        for (let i = 0; i < clips.length; i++) {
            const uuid = asStr(clips[i]);
            if (animations.has(uuid)) object.animations.push(animations.get(uuid));
        }
        if (object instanceof LOD) {
            const levels = jarr(data, "levels");
            const lod = object as LOD;
            for (let i = 0; i < levels.length; i++) {
                const uuid = jstr(levels[i], "object", "");
                const child = this.findChild(lod, uuid);
                if (child != null) lod.addLevel(child!, jnum(levels[i], "distance", 0), jnum(levels[i], "hysteresis", 0));
            }
        }
        return object;
    }

    /// Binds each SkinnedMesh to its skeleton, with its bind matrix.
    bindSkeletons(object: Object3D, skeletons: Map<string, Skeleton>): void {
        for (let i = 0; i < this.skinnedMeshes.length; i++) {
            const mesh = this.skinnedMeshes[i];
            const uuid = this.skeletonUuids[i];
            if (!skeletons.has(uuid)) {
                this.warn("no skeleton exists with uuid " + uuid);
                continue;
            }
            mesh.bind(skeletons.get(uuid), mesh.bindMatrix);
        }
    }

    /// Points directional and spot lights at their targets (by uuid; a new
    /// Object3D when the target is not in the document, as three.js).
    bindLightTargets(object: Object3D): void {
        for (let i = 0; i < this.targetLights.length; i++) {
            const light = this.targetLights[i];
            const uuid = this.targetUuids[i];
            const target = this.objects.has(uuid) ? this.objects.get(uuid) : new Object3D();
            if (light instanceof DirectionalLight) (light as DirectionalLight).target = target;
            else if (light instanceof SpotLight) (light as SpotLight).target = target;
        }
    }

    // ------------------------------------------------------------- internal

    /// The document of `json` (text or Dynamic), checked to be an object
    /// document; null (and `error`) otherwise.
    private document<T>(json: T): Dynamic? {
        this.error = "";
        let data: Dynamic? = null;
        if (isString<T>()) {
            data = JSON.parse(json as string);
            if (data == null) {
                this.fail("not JSON: " + JSON.lastError);
                return null;
            }
        } else {
            data = json as Dynamic;
        }
        const metadata = jget(data, "metadata");
        const type = jstr(metadata, "type", "").toLowerCase();
        if (type == "geometry" || type == "buffergeometry" || !jhas(data, "object")) {
            this.fail("can't load: not an object document (metadata.type '" + jstr(metadata, "type", "") + "')");
            return null;
        }
        return data;
    }

    private parseShadow(shadow: LightShadow, json: Dynamic, geometries: Map<string, BufferGeometry>,
                        materials: Map<string, Material>, textures: Map<string, Texture>,
                        animations: Map<string, AnimationClip>): void {
        shadow.intensity = jnum(json, "intensity", shadow.intensity);
        shadow.bias = jnum(json, "bias", shadow.bias);
        shadow.normalBias = jnum(json, "normalBias", shadow.normalBias);
        shadow.radius = jnum(json, "radius", shadow.radius);
        const mapSize = jnumbers(json, "mapSize");
        if (mapSize != null && mapSize.length >= 2) shadow.mapSize.set(mapSize[0], mapSize[1]);
        const cameraJSON = jget(json, "camera");
        if (cameraJSON != null) {
            const camera = this.parseObject(cameraJSON, geometries, materials, textures, animations);
            if (camera instanceof Camera) shadow.camera = camera as Camera;
        }
    }

    private pendTarget(light: Object3D, data: Dynamic?): void {
        if (!jhas(data, "target")) return;
        this.targetLights.push(light);
        this.targetUuids.push(jstr(data, "target", ""));
    }

    private geometryOf(data: Dynamic?, geometries: Map<string, BufferGeometry>): BufferGeometry {
        const uuid = jstr(data, "geometry", "");
        if (geometries.has(uuid)) return geometries.get(uuid);
        this.warn("undefined geometry " + uuid);
        return new BufferGeometry();
    }

    private materialOf(data: Dynamic?, materials: Map<string, Material>): Material? {
        const value = jget(data, "material");
        if (value == null) return null;
        const uuid = value.kind == DynamicKind.table ? asStr(Dynamic.at(value, 0)) : asStr(value);
        if (materials.has(uuid)) return materials.get(uuid);
        this.warn("undefined material " + uuid);
        return null;
    }

    /// A mesh's material, or per-group materials for an array of uuids.
    private applyMaterials(mesh: Mesh, data: Dynamic?, materials: Map<string, Material>): void {
        const value = jget(data, "material");
        if (value == null) return;
        if (value.kind == DynamicKind.table) {
            const uuids = Dynamic.asArray(value);
            const list: Array<Material> = [];
            for (let i = 0; i < uuids.length; i++) {
                const uuid = asStr(uuids[i]);
                if (materials.has(uuid)) list.push(materials.get(uuid));
                else this.warn("undefined material " + uuid);
            }
            mesh.materials = list;
            if (list.length > 0) mesh.material = list[0];
        } else {
            const m = this.materialOf(data, materials);
            if (m != null) mesh.material = m!;
        }
    }

    private textureNamed(textures: Map<string, Texture>, uuid: string): Texture? {
        if (textures.has(uuid)) return textures.get(uuid);
        this.warn("undefined texture " + uuid);
        return null;
    }

    private imageAsset(url: string): Image? {
        const context = this.context;
        if (context == null || url.length == 0 || LoaderUtils.isURL(url)) return null;
        let image = context.image(this.resourcePath + url);
        if (image == null) image = context.image(assetName(url));
        return image;
    }

    private findChild(object: Object3D, uuid: string): Object3D? {
        for (let i = 0; i < object.children.length; i++) if (object.children[i].uuid == uuid) return object.children[i];
        return null;
    }

    warn(message: string): void {
        this.warnings.push(message);
        const context = this.context;
        if (context != null) context.log("three: ObjectLoader: " + message);
    }

    private fail(message: string): void {
        this.error = message;
        const context = this.context;
        if (context != null) context.log("three: ObjectLoader: " + message);
    }
}

async function loadObjectAsync(loader: ObjectLoader, url: string): Promise<Object3D> {
    const resolved = LoaderUtils.resolveURL(url, loader.path);
    const settled = await fetchBytes(loader, url).settled();
    if (!settled.ok) {
        loader.error = settled.error;
        return await Promise.reject<Object3D>(settled.error);
    }
    const data = JSON.parse(String.UTF8.decode(settled.value));
    if (data == null) {
        loader.error = "not JSON: " + JSON.lastError;
        return await Promise.reject<Object3D>(loader.error);
    }
    const base = loader.resourcePath.length > 0 ? loader.resourcePath
        : LoaderUtils.isURL(resolved) ? LoaderUtils.extractUrlBase(resolved) : "";
    return await parseObjectAsync(loader, data!, base);
}

/// Fetches the document's https: (or relative, beside an https: document)
/// images, builds the scene and waits for every image to decode.
async function parseObjectAsync(loader: ObjectLoader, data: Dynamic, base: string): Promise<Object3D> {
    if (!jhas(data, "object")) return await Promise.reject<Object3D>("can't load: not an object document");
    const images = loader.parseImages(jget(data, "images"));
    const uuids = images.keys();
    for (let i = 0; i < uuids.length; i++) {
        const image = images.get(uuids[i]);
        if (image.url.length == 0 || image.bytes != null || image.image != null) continue;
        const remote = LoaderUtils.isURL(image.url) || LoaderUtils.isURL(base);
        if (!remote) continue;
        const settled = await fetchBytes(loader, LoaderUtils.resolveURL(image.url, base), "").settled();
        if (settled.ok) image.bytes = settled.value;
        else loader.warn("image '" + image.url + "': " + settled.error);
    }
    const object = loader.parseDocument(data, images);
    if (object == null) return await Promise.reject<Object3D>(loader.error);
    const decodes = loader.decodes;
    for (let i = 0; i < decodes.length; i++) {
        const outcome = await decodes[i].settled();
        if (!outcome.ok) loader.warn("image decode failed: " + outcome.error);
    }
    return object!;
}

// ------------------------------------------------------------------ helpers

/// A built-in geometry of three.js's class `type` from its parameters, or
/// null for another type.
function createGeometry(type: string, data: Dynamic?, shapes: Map<string, Shape>): BufferGeometry? {
    if (type == "BoxGeometry") return BoxGeometry.fromJSON(data);
    if (type == "CapsuleGeometry") return CapsuleGeometry.fromJSON(data);
    if (type == "CircleGeometry") return CircleGeometry.fromJSON(data);
    if (type == "ConeGeometry") return ConeGeometry.fromJSON(data);
    if (type == "CylinderGeometry") return CylinderGeometry.fromJSON(data);
    if (type == "DodecahedronGeometry") return DodecahedronGeometry.fromJSON(data);
    if (type == "ExtrudeGeometry") return ExtrudeGeometry.fromJSON(data, shapes);
    if (type == "IcosahedronGeometry") return IcosahedronGeometry.fromJSON(data);
    if (type == "LatheGeometry") return LatheGeometry.fromJSON(data);
    if (type == "OctahedronGeometry") return OctahedronGeometry.fromJSON(data);
    if (type == "PlaneGeometry") return PlaneGeometry.fromJSON(data);
    if (type == "PolyhedronGeometry") return PolyhedronGeometry.fromJSON(data);
    if (type == "RingGeometry") return RingGeometry.fromJSON(data);
    if (type == "ShapeGeometry") return ShapeGeometry.fromJSON(data, shapes);
    if (type == "SphereGeometry") return SphereGeometry.fromJSON(data);
    if (type == "TetrahedronGeometry") return TetrahedronGeometry.fromJSON(data);
    if (type == "TorusGeometry") return TorusGeometry.fromJSON(data);
    if (type == "TorusKnotGeometry") return TorusKnotGeometry.fromJSON(data);
    return null;
}

function color(data: Dynamic?): u32 {
    return <u32>jnum(data, "color", 0xffffff);
}

/// A light's shadow, or null for objects without one.
function shadowOf(object: Object3D): LightShadow? {
    if (object instanceof DirectionalLight) return (object as DirectionalLight).shadow;
    if (object instanceof SpotLight) return (object as SpotLight).shadow;
    if (object instanceof PointLight) return (object as PointLight).shadow;
    return null;
}

/// Sets texture.offset (which 0), repeat (1) or center (2) from [x, y].
function readTextureVector(texture: Texture, which: i32, values: Array<f64>?): void {
    if (values == null || values.length < 2) return;
    if (which == 0) texture.offset.set(values[0], values[1]);
    else if (which == 1) texture.repeat.set(values[0], values[1]);
    else texture.center.set(values[0], values[1]);
}

/// A texture constant: a number, or its three.js name ("RepeatWrapping").
function parseConstant(value: Dynamic?, fallback: i32): f64 {
    if (value == null) return <f64>fallback;
    if (value.kind == DynamicKind.number) return Dynamic.asNumber(value);
    const name = asStr(value);
    if (name == "UVMapping") return UVMapping;
    if (name == "CubeReflectionMapping") return CubeReflectionMapping;
    if (name == "CubeRefractionMapping") return CubeRefractionMapping;
    if (name == "EquirectangularReflectionMapping") return EquirectangularReflectionMapping;
    if (name == "EquirectangularRefractionMapping") return EquirectangularRefractionMapping;
    if (name == "RepeatWrapping") return RepeatWrapping;
    if (name == "ClampToEdgeWrapping") return ClampToEdgeWrapping;
    if (name == "MirroredRepeatWrapping") return MirroredRepeatWrapping;
    if (name == "NearestFilter") return NearestFilter;
    if (name == "NearestMipmapNearestFilter") return NearestMipmapNearestFilter;
    if (name == "NearestMipmapLinearFilter") return NearestMipmapLinearFilter;
    if (name == "LinearFilter") return LinearFilter;
    if (name == "LinearMipmapNearestFilter") return LinearMipmapNearestFilter;
    if (name == "LinearMipmapLinearFilter") return LinearMipmapLinearFilter;
    return <f64>fallback;
}

/// { data, width, height, type } of a DataTexture's image.
function readRawImage(image: ObjectLoaderImage, item: Dynamic?): void {
    const values = jnumbers(item, "data");
    image.width = <u32>jnum(item, "width", 0);
    image.height = <u32>jnum(item, "height", 0);
    if (values == null) return;
    const type = jstr(item, "type", "Uint8Array");
    if (type == "Float32Array") {
        const a = new Float32Array(values.length);
        for (let i = 0; i < values.length; i++) a[i] = <f32>values[i];
        image.data = a;
        image.dataType = FloatType;
    } else if (type == "Uint16Array") {
        const a = new Uint16Array(values.length);
        for (let i = 0; i < values.length; i++) a[i] = <u16>values[i];
        image.data = a;
        image.dataType = HalfFloatType;
    } else {
        const a = new Uint8Array(values.length);
        for (let i = 0; i < values.length; i++) a[i] = <u8>values[i];
        image.data = a;
        image.dataType = UnsignedByteType;
    }
}

/// The bytes of a base64 data: url, or null.
function decodeDataURL(url: string): ArrayBuffer? {
    const comma = url.indexOf(",");
    if (comma < 0 || !url.substring(0, comma).endsWith(";base64")) return null;
    const out = new Uint8Array((url.length - comma) * 3 / 4 + 3);
    let n = 0, acc: u32 = 0, bits = 0;
    for (let i = comma + 1; i < url.length; i++) {
        const v = base64Value(url.charCodeAt(i));
        if (v < 0) continue;
        acc = (acc << 6) | <u32>v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[n++] = <u8>((acc >> <u32>bits) & 255);
        }
    }
    return out.slice(0, n).buffer;
}

function base64Value(c: i32): i32 {
    if (c >= 65 && c <= 90) return c - 65;
    if (c >= 97 && c <= 122) return c - 71;
    if (c >= 48 && c <= 57) return c + 4;
    if (c == 43 || c == 45) return 62;
    if (c == 47 || c == 95) return 63;
    return -1;
}

/// A url's file name without folders or extension: the Rive asset name.
function assetName(url: string): string {
    let name = url;
    const q = name.indexOf("?");
    if (q >= 0) name = name.substring(0, q);
    const slash = name.lastIndexOf("/");
    if (slash >= 0) name = name.substring(slash + 1);
    const dot = name.lastIndexOf(".");
    if (dot > 0) name = name.substring(0, dot);
    return name;
}
