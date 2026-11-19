// three.js's FBXLoader addon (r170), for Rive: reads an FBX file (binary,
// version 6400 and up, or ASCII 7000 and up) from a BlobAsset and returns a
// Group, as three.js:
//
//     const object = new FBXLoader(context).load("character");   // the BlobAsset's name
//     if (object != null) {
//         scene.add(object);
//         mixer = new AnimationMixer(object);
//         mixer.clipAction(object.animations[0]).play();
//     }
//
// `loadAsync(url)` (an https: url or a blob asset) inflates a binary file's
// compressed arrays in a Rive job first, and resolves with the Group.
//
// Read, as three.js: the node hierarchy with FBX's pre/post rotations,
// pivots, offsets and inherit types; meshes (polygons triangulated, normals,
// uvs, vertex colours, material indices as groups, geometric transforms);
// NURBS curves (as lines); Phong / Lambert materials and their textures
// (embedded Video content, or image / blob assets named after the file);
// cameras, lights, skins (clusters, bind poses), blend shapes (morph
// targets) and animation stacks (AnimationClips of position, quaternion,
// scale and morph influence tracks).
//
// The structure follows three.js's: BinaryParser / TextParser build an
// FBXTree, FBXTreeParser builds the scene with GeometryParser, and
// AnimationParser the clips. The tree is typed (FBXNode, FBXValue,
// FBXProperty) instead of plain JavaScript objects.

import { Context, DecodedImage, ImageDecodeListener } from "rive/host";
import { Promise } from "rive/promise";
import { Jobs } from "rive/jobs";
import { Loader } from "../../loaders/Loader";
import { LoadingManager } from "../../loaders/LoadingManager";
import { LoaderUtils } from "../../loaders/LoaderUtils";
import { fetchBytes } from "../../loaders/FileLoader";
import { decodeTexture } from "../../loaders/TextureLoader";
import { unzlibSync } from "../libs/fflate";
import { NURBSCurve } from "../curves/NURBSCurve";
import { AmbientLight } from "../../lights/AmbientLight";
import { DirectionalLight } from "../../lights/DirectionalLight";
import { PointLight } from "../../lights/PointLight";
import { SpotLight } from "../../lights/SpotLight";
import { AnimationClip } from "../../animation/AnimationClip";
import {
    KeyframeTrack, NumberKeyframeTrack, QuaternionKeyframeTrack, VectorKeyframeTrack,
} from "../../animation/KeyframeTrack";
import { PropertyBinding } from "../../animation/PropertyBinding";
import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute, Float32BufferAttribute } from "../../core/BufferAttribute";
import { Object3D } from "../../core/Object3D";
import { PerspectiveCamera } from "../../cameras/PerspectiveCamera";
import { Group } from "../../objects/Group";
import { Line } from "../../objects/Line";
import { Mesh } from "../../objects/Mesh";
import { SkinnedMesh } from "../../objects/SkinnedMesh";
import { Bone, Skeleton } from "../../objects/Skeleton";
import { Material } from "../../materials/Material";
import { LineBasicMaterial } from "../../materials/LineBasicMaterial";
import { MeshLambertMaterial } from "../../materials/MeshLambertMaterial";
import { MeshPhongMaterial } from "../../materials/MeshPhongMaterial";
import { Texture } from "../../textures/Texture";
import { DataTexture } from "../../textures/DataTexture";
import { Color } from "../../math/Color";
import { Euler } from "../../math/Euler";
import { MathUtils } from "../../math/MathUtils";
import { Matrix3 } from "../../math/Matrix3";
import { Matrix4 } from "../../math/Matrix4";
import { Quaternion } from "../../math/Quaternion";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { Vector4 } from "../../math/Vector4";
import { ShapeUtils } from "../../extras/ShapeUtils";
import {
    ClampToEdgeWrapping, EquirectangularReflectionMapping, LinearFilter, LinearMipmapLinearFilter, NoColorSpace,
    RepeatWrapping, SRGBColorSpace,
} from "../../constants";

export class FBXLoader extends Loader {
    // `context` loads blob and image assets, decodes embedded images and
    // logs; without one, `parse` still builds the scene (textures stay
    // empty).
    /// Why the last load or parse returned null.
    error: string = "";
    /// Warnings of the last parse (three.js's console.warn lines).
    warnings: Array<string> = [];
    /// GlobalSettings' UnitScaleFactor of the last parse (three.js's
    /// `object.userData.unitScaleFactor`; 1 when the file has none).
    unitScaleFactor: f64 = 1;
    /// Each loaded object's FBX node name before sanitizing, by
    /// `object.id` (three.js's `userData.originalName`).
    originalNames: Map<i32, string> = new Map<i32, string>();

    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    /// Loads the BlobAsset called `name` (`path` + name), at once; null (and
    /// a log line) when it is missing or not an FBX this loader reads.
    /// Textures not embedded in the file are image or blob assets named
    /// after their files without extension ("wood.png" -> "wood").
    /// Urls need loadAsync.
    load(name: string): Group? {
        const context = this.context;
        const full = LoaderUtils.resolveURL(name, this.path);
        if (LoaderUtils.isURL(full)) {
            this.fail("urls load with loadAsync");
            return null;
        }
        const bytesAsset = context != null ? context.blob(full) : null;
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes == null) {
            this.fail("no blob asset named '" + full + "'");
            return null;
        }
        return this.parse(bytes!, this.path);
    }

    /// Loads `url`: an https: url (fetched where the host allows the
    /// network; textures from beside it, or from `resourcePath`), else the
    /// blob asset of that name. A binary file's compressed arrays inflate
    /// in a Rive job (inflateFBX), off the main lane; the scene is built
    /// when it is done. Textures fill in later.
    loadAsync(url: string): Promise<Group> {
        return loadFBXAsync(this, url);
    }

    /// As parse, inflating a binary file's arrays in a job first.
    parseAsync(FBXBuffer: ArrayBuffer, path: string = ""): Promise<Group> {
        return parseFBXAsync(this, FBXBuffer, path);
    }

    /// Parses binary or ASCII FBX bytes. `path` is where external textures
    /// resolve (`resourcePath` wins): an https: url to fetch them from, or
    /// a prefix for asset names.
    parse(FBXBuffer: ArrayBuffer, path: string = ""): Group? {
        return this.parseInflated(FBXBuffer, path, null);
    }

    /// parse, with a binary file's compressed arrays already inflated.
    parseInflated(FBXBuffer: ArrayBuffer, path: string, inflated: FBXInflated?): Group? {
        this.error = "";
        this.warnings = [];
        this.unitScaleFactor = 1;
        this.originalNames = new Map<i32, string>();
        let fbxTree: FBXTree? = null;
        if (isFbxFormatBinary(FBXBuffer)) {
            const parser = new BinaryParser();
            parser.inflated = inflated;
            fbxTree = parser.parse(FBXBuffer);
            if (fbxTree == null) {
                this.fail(parser.error);
                return null;
            }
        } else {
            const FBXText = convertArrayBufferToString(FBXBuffer);
            if (!isFbxFormatASCII(FBXText)) {
                this.fail("Unknown format.");
                return null;
            }
            const version = getFbxVersion(FBXText);
            if (version < 0) {
                this.fail("Cannot find the version number for the file given.");
                return null;
            }
            if (version < 7000) {
                this.fail("FBX version not supported, FileVersion: " + version.toString());
                return null;
            }
            fbxTree = new TextParser().parse(FBXText);
        }
        const texturePath = this.resourcePath.length > 0 ? this.resourcePath : path;
        return new FBXTreeParser(this, fbxTree!, texturePath).parse();
    }

    /// A three.js console.warn: kept in `warnings` and logged.
    warn(message: string): void {
        this.warnings.push(message);
        const context = this.context;
        if (context != null) context.log("three: FBXLoader: " + message);
    }

    private fail(message: string): void {
        this.error = message;
        const context = this.context;
        if (context != null) context.log("three: FBXLoader: " + message);
    }
}

async function loadFBXAsync(loader: FBXLoader, url: string): Promise<Group> {
    const resolved = LoaderUtils.resolveURL(url, loader.path);
    const settled = await fetchBytes(loader, url).settled();
    if (!settled.ok) {
        loader.error = settled.error;
        return await Promise.reject<Group>(settled.error);
    }
    const path = loader.path.length == 0 && LoaderUtils.isURL(resolved) ? LoaderUtils.extractUrlBase(resolved) : loader.path;
    return await parseFBXAsync(loader, settled.value, path);
}

async function parseFBXAsync(loader: FBXLoader, data: ArrayBuffer, path: string): Promise<Group> {
    let inflated: FBXInflated? = null;
    if (isFbxFormatBinary(data)) {
        const result = await Jobs.run(inflateFBX, data).promise();
        if (result.error.length > 0) {
            loader.error = result.error;
            return await Promise.reject<Group>(result.error);
        }
        inflated = result;
    }
    const object = loader.parseInflated(data, path, inflated);
    if (object == null) return await Promise.reject<Group>(loader.error);
    return object!;
}

/// A binary FBX's compressed arrays, inflated, in file order: the values of
/// array k are values[offsets[k] .. offsets[k] + lengths[k]].
export class FBXInflated {
    error: string = "";
    values: Float64Array = new Float64Array(0);
    offsets: Int32Array = new Int32Array(0);
    lengths: Int32Array = new Int32Array(0);
}

/// The job behind loadAsync / parseAsync: inflates every zlib-compressed
/// array of a binary FBX (most of a binary parse's time), off the main lane.
@job export function inflateFBX(data: ArrayBuffer): FBXInflated {
    const out = new FBXInflated();
    const parser = new BinaryParser();
    const collected: Array<Array<f64>> = [];
    parser.collected = collected;
    if (parser.parse(data) == null) {
        out.error = parser.error;
        return out;
    }
    let total = 0;
    for (let i = 0; i < collected.length; i++) total += collected[i].length;
    out.values = new Float64Array(total);
    out.offsets = new Int32Array(collected.length);
    out.lengths = new Int32Array(collected.length);
    let at = 0;
    for (let i = 0; i < collected.length; i++) {
        const array = collected[i];
        out.offsets[i] = at;
        out.lengths[i] = array.length;
        for (let j = 0; j < array.length; j++) out.values[at + j] = array[j];
        at += array.length;
    }
    return out;
}

/// Fills a texture when its fetched image has decoded.
class FBXTextureDecode extends ImageDecodeListener {
    texture: DataTexture;
    context: Context;

    constructor(texture: DataTexture, context: Context) {
        super();
        this.texture = texture;
        this.context = context;
    }

    override onImageDecoded(image: DecodedImage): void {
        const t = this.texture;
        t.data = Uint8Array.wrap(image.data);
        t.dataWidth = image.width;
        t.dataHeight = image.height;
        t.needsUpdate = true;
        forgetDecode(this);
    }

    override onImageDecodeFailed(message: string): void {
        this.context.log("three: FBXLoader: a texture failed to decode: " + message);
        forgetDecode(this);
    }
}

// Decodes in flight (kept alive until they report).
const pendingDecodes: Array<FBXTextureDecode> = [];

function forgetDecode(listener: FBXTextureDecode): void {
    const i = pendingDecodes.indexOf(listener);
    if (i >= 0) pendingDecodes.splice(i, 1);
}

/// Fetches `url` and decodes it into `texture` (a texture three.js's
/// TextureLoader would load from beside the file).
async function fetchTextureInto(loader: FBXLoader, url: string, texture: DataTexture): Promise<void> {
    const settled = await fetchBytes(loader, url, "").settled();
    const context = loader.context;
    if (context == null) return;
    if (!settled.ok) {
        context.log("three: FBXLoader: " + settled.error);
        return;
    }
    const listener = new FBXTextureDecode(texture, context);
    pendingDecodes.push(listener);
    context.decodeImage(settled.value, listener);
}

/// An empty texture to be filled by a decode, set up as TextureLoader's.
function pendingTexture(): DataTexture {
    const texture = new DataTexture(new Uint8Array(0), 0, 0);
    texture.premultiplyAlpha = true;   // decoded images are premultiplied
    texture.generateMipmaps = true;
    texture.magFilter = LinearFilter;
    texture.minFilter = LinearMipmapLinearFilter;
    return texture;
}

// ===================================================================== scene

/// One end of a connection: the other object's ID and the property it
/// connects through ("" for an object-object connection, three.js's
/// undefined).
export class FBXRelationship {
    ID: i64;
    relationship: string;

    constructor(ID: i64, relationship: string) {
        this.ID = ID;
        this.relationship = relationship;
    }
}

export class FBXRelationships {
    parents: Array<FBXRelationship> = [];
    children: Array<FBXRelationship> = [];
}

/// An image of FBXTree.Objects.Video: its file name, and its bytes when
/// the file embeds them.
class FBXImage {
    fileName: string = "";
    content: Uint8Array? = null;
}

/// A cluster: one bone's vertices and weights and its bind transform.
class FBXRawBone {
    ID: i64 = 0;
    indices: Array<f64> = [];
    weights: Array<f64> = [];
    transformLink: Matrix4 = new Matrix4();
}

/// A Skin deformer: its clusters and, once models are built, its bones.
class FBXSkeleton {
    ID: i64 = 0;
    geometryID: i64 = 0;
    rawBones: Array<FBXRawBone> = [];
    bones: Array<Bone?> = [];
}

/// A BlendShapeChannel: a morph target's name and shape geometry.
class FBXRawMorphTarget {
    name: string = "";
    initialWeight: f64 = 0;
    id: i64 = 0;
    fullWeights: Array<f64> = [];
    geoID: i64 = 0;
}

/// A BlendShape deformer.
class FBXMorphTarget {
    id: i64 = 0;
    rawTargets: Array<FBXRawMorphTarget> = [];
}

class FBXDeformers {
    skeletons: Map<i64, FBXSkeleton> = new Map<i64, FBXSkeleton>();
    skeletonIDs: Array<i64> = [];
    morphTargets: Map<i64, FBXMorphTarget> = new Map<i64, FBXMorphTarget>();
}

/// A model's transform properties (three.js's userData.transformData).
/// Absent vectors are null.
export class FBXTransformData {
    inheritType: i32 = 0;
    eulerOrder: string = "";
    translation: Array<f64>? = null;
    preRotation: Array<f64>? = null;
    rotation: Array<f64>? = null;
    postRotation: Array<f64>? = null;
    scale: Array<f64>? = null;
    scalingOffset: Array<f64>? = null;
    scalingPivot: Array<f64>? = null;
    rotationOffset: Array<f64>? = null;
    rotationPivot: Array<f64>? = null;
    parentMatrix: Matrix4? = null;
    parentMatrixWorld: Matrix4? = null;
}

/// The material parameters three.js collects before `setValues` (NaN or
/// null: not set).
class FBXMaterialParameters {
    bumpScale: f64 = NaN;
    color: Color? = null;
    displacementScale: f64 = NaN;
    emissive: Color? = null;
    emissiveIntensity: f64 = NaN;
    opacity: f64 = 1;
    transparent: bool = false;
    reflectivity: f64 = NaN;
    shininess: f64 = NaN;
    specular: Color? = null;
    bumpMap: Texture? = null;
    aoMap: Texture? = null;
    map: Texture? = null;
    displacementMap: Texture? = null;
    emissiveMap: Texture? = null;
    normalMap: Texture? = null;
    envMap: Texture? = null;
    specularMap: Texture? = null;
    alphaMap: Texture? = null;
}

/// State shared by the parsers of one file (three.js's module-level
/// fbxTree, connections and sceneGraph, and the userData it sets).
export class FBXState {
    loader: FBXLoader;
    fbxTree: FBXTree;
    connections: Map<i64, FBXRelationships> = new Map<i64, FBXRelationships>();
    sceneGraph: Group = new Group();
    /// FBX IDs by object.id (three.js's `object.ID`).
    modelIDs: Map<i32, i64> = new Map<i32, i64>();
    /// Transform data by object.id.
    transformData: Map<i32, FBXTransformData> = new Map<i32, FBXTransformData>();
    /// Skin deformers by geometry.id (three.js's `geometry.FBX_Deformer`).
    geometryDeformers: Map<i32, FBXSkeleton> = new Map<i32, FBXSkeleton>();

    constructor(loader: FBXLoader, fbxTree: FBXTree) {
        this.loader = loader;
        this.fbxTree = fbxTree;
    }

    relationships(id: i64): FBXRelationships {
        if (this.connections.has(id)) return this.connections.get(id);
        return new FBXRelationships();
    }

    warn(message: string): void {
        this.loader.warn(message);
    }
}

// Parses the FBXTree returned by the BinaryParser or TextParser and returns
// a Group.
class FBXTreeParser {
    state: FBXState;
    texturePath: string;

    constructor(loader: FBXLoader, fbxTree: FBXTree, texturePath: string) {
        this.state = new FBXState(loader, fbxTree);
        this.texturePath = texturePath;
    }

    parse(): Group {
        this.state.connections = this.parseConnections();
        const images = this.parseImages();
        const textures = this.parseTextures(images);
        const materials = this.parseMaterials(textures);
        const deformers = this.parseDeformers();
        const geometryMap = new GeometryParser(this.state).parse(deformers);
        this.parseScene(deformers, geometryMap, materials);
        return this.state.sceneGraph;
    }

    // Parses FBXTree.Connections, which holds parent-child connections
    // between objects (material -> texture, model -> geometry ...) and
    // their type.
    parseConnections(): Map<i64, FBXRelationships> {
        const connectionMap = new Map<i64, FBXRelationships>();
        const node = this.state.fbxTree.node("Connections");
        if (node == null) return connectionMap;
        const rawConnections = node.connections;
        for (let i = 0; i < rawConnections.length; i++) {
            const rawConnection = rawConnections[i];
            const fromID = rawConnection.from;
            const toID = rawConnection.to;
            const relationship = rawConnection.relationship;
            if (!connectionMap.has(fromID)) connectionMap.set(fromID, new FBXRelationships());
            connectionMap.get(fromID).parents.push(new FBXRelationship(toID, relationship));
            if (!connectionMap.has(toID)) connectionMap.set(toID, new FBXRelationships());
            connectionMap.get(toID).children.push(new FBXRelationship(fromID, relationship));
        }
        return connectionMap;
    }

    // Parses FBXTree.Objects.Video for embedded image data. These images are
    // connected to textures in FBXTree.Objects.Texture via Connections.
    parseImages(): Map<i64, FBXImage> {
        const images = new Map<i64, FBXImage>();
        const blobs = new Map<string, Uint8Array>();
        const videoNodes = this.state.fbxTree.objects("Video");
        for (let n = 0; n < videoNodes.ids.length; n++) {
            const id = videoNodes.ids[n];
            const videoNode = videoNodes.get(id);
            const image = new FBXImage();
            image.fileName = videoFileName(videoNode);
            images.set(id, image);
            // raw image data is in videoNode.Content
            const content = videoNode.value("Content");
            if (content != null) {
                const arrayBufferContent = content.kind == FBX_BYTES && content.bytes != null && content.bytes!.byteLength > 0;
                const base64Content = content.kind == FBX_STRING && content.str.length > 0;
                if (arrayBufferContent || base64Content) {
                    const bytes = this.parseImage(videoNode);
                    if (bytes != null) blobs.set(image.fileName, bytes!);
                }
            }
        }
        const ids = images.keys();
        for (let i = 0; i < ids.length; i++) {
            const image = images.get(ids[i]);
            if (blobs.has(image.fileName)) image.content = blobs.get(image.fileName);
            else image.fileName = lastPart(image.fileName, "\\");
        }
        return images;
    }

    // Parses embedded image data in FBXTree.Video.Content. Rive decodes PNG
    // and JPEG (three.js also hands BMP, TIFF and TGA to the browser).
    parseImage(videoNode: FBXNode): Uint8Array? {
        const content = videoNode.value("Content")!;
        const fileName = videoFileName(videoNode);
        const extension = fileName.slice(fileName.lastIndexOf(".") + 1).toLowerCase();
        if (extension == "bmp" || extension == "tif" || extension == "tga") {
            this.state.warn("Image type \"" + extension + "\" is not supported by Rive's image decoder, skipping " + fileName);
            return null;
        }
        if (extension != "jpg" && extension != "jpeg" && extension != "png") {
            this.state.warn("Image type \"" + extension + "\" is not supported.");
            return null;
        }
        if (content.kind == FBX_STRING) return base64Decode(content.str);   // ASCII format
        return Uint8Array.wrap(content.bytes!);   // Binary format
    }

    // Parses the nodes in FBXTree.Objects.Texture. These hold UV scaling,
    // cropping, rotation etc. and are connected to images in
    // FBXTree.Objects.Video.
    parseTextures(images: Map<i64, FBXImage>): Map<i64, Texture> {
        const textureMap = new Map<i64, Texture>();
        const textureNodes = this.state.fbxTree.objects("Texture");
        for (let n = 0; n < textureNodes.ids.length; n++) {
            const id = textureNodes.ids[n];
            textureMap.set(id, this.parseTexture(textureNodes.get(id), images));
        }
        return textureMap;
    }

    // Parses one node of FBXTree.Objects.Texture.
    parseTexture(textureNode: FBXNode, images: Map<i64, FBXImage>): Texture {
        const texture = this.loadTexture(textureNode, images);
        texture.name = textureNode.attrName;
        const wrapModeU = textureNode.property("WrapModeU");
        const wrapModeV = textureNode.property("WrapModeV");
        const valueU = wrapModeU != null ? wrapModeU.value.asNumber() : 0;
        const valueV = wrapModeV != null ? wrapModeV.value.asNumber() : 0;
        // 0: repeat (default), 1: clamp
        texture.wrapS = valueU == 0 ? RepeatWrapping : ClampToEdgeWrapping;
        texture.wrapT = valueV == 0 ? RepeatWrapping : ClampToEdgeWrapping;
        const scaling = textureNode.property("Scaling");
        if (scaling != null) {
            const values = scaling.value.arr;
            if (values.length >= 2) {
                texture.repeat.x = values[0];
                texture.repeat.y = values[1];
            }
        }
        const translation = textureNode.property("Translation");
        if (translation != null) {
            const values = translation.value.arr;
            if (values.length >= 2) {
                texture.offset.x = values[0];
                texture.offset.y = values[1];
            }
        }
        return texture;
    }

    // Loads a texture from embedded data, or from the file it names: an
    // image or blob asset named after the file, or a url beside the FBX.
    loadTexture(textureNode: FBXNode, images: Map<i64, FBXImage>): Texture {
        const fileNameValue = textureNode.string("FileName", "");
        const extension = lastPart(fileNameValue, ".").toLowerCase();
        if (extension == "tga" || extension == "tif" || extension == "tiff" || extension == "exr" ||
            extension == "dds" || extension == "hdr" || extension == "ktx2") {
            this.state.warn(extension.toUpperCase() + " loader not found, creating placeholder texture for " +
                textureNode.string("RelativeFilename", ""));
            return new Texture();
        }
        const children = this.state.relationships(textureNode.id).children;
        let image: FBXImage? = null;
        if (children.length > 0 && images.has(children[0].ID)) image = images.get(children[0].ID);
        const context = this.state.loader.context;
        if (image == null) {
            this.state.warn("texture '" + textureNode.attrName + "' has no image");
            return new Texture();
        }
        const content = image.content;
        if (content != null) {
            if (context == null) return new Texture();
            return decodeTexture(context, content.slice().buffer, true).texture;
        }
        const fileName = image.fileName;
        const base = this.texturePath;
        if (LoaderUtils.isURL(base)) {
            const texture = pendingTexture();
            texture.name = fileName;
            fetchTextureInto(this.state.loader, LoaderUtils.resolveURL(fileName, base), texture);
            return texture;
        }
        if (context == null) return new Texture();
        const name = (base == "./" ? "" : base) + assetName(fileName);
        const riveImage = context.image(name);
        if (riveImage != null) {
            const texture = new Texture(riveImage);
            texture.colorSpace = NoColorSpace;   // as three.js's loaded textures; colour maps are set to sRGB
            return texture;
        }
        const bytesAsset = context.blob(name);
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes != null) return decodeTexture(context, bytes!, true).texture;
        this.state.warn("no image or blob asset named '" + name + "' (texture " + fileName + ")");
        const texture = new Texture();
        texture.name = name;
        return texture;
    }

    // Parses the nodes in FBXTree.Objects.Material.
    parseMaterials(textureMap: Map<i64, Texture>): Map<i64, Material> {
        const materialMap = new Map<i64, Material>();
        const materialNodes = this.state.fbxTree.objects("Material");
        for (let n = 0; n < materialNodes.ids.length; n++) {
            const id = materialNodes.ids[n];
            const material = this.parseMaterial(materialNodes.get(id), textureMap);
            if (material != null) materialMap.set(id, material!);
        }
        return materialMap;
    }

    // Parses one node of FBXTree.Objects.Material. Materials are connected
    // to texture maps in FBXTree.Objects.Texture. FBX only has the Lambert
    // and Phong shading models.
    parseMaterial(materialNode: FBXNode, textureMap: Map<i64, Texture>): Material? {
        const ID = materialNode.id;
        const name = materialNode.attrName;
        let type = "";
        const shadingModel = materialNode.value("ShadingModel");
        if (shadingModel != null) type = shadingModel.asString();
        else {
            // Case where FBX wraps the shading model in a property object.
            const property = materialNode.property("ShadingModel");
            if (property != null) type = property.value.asString();
        }
        // Ignore unused materials which don't have any connections.
        if (!this.state.connections.has(ID)) return null;
        const parameters = this.parseParameters(materialNode, textureMap, ID);
        let material: Material;
        const lower = type.toLowerCase();
        if (lower == "phong") material = new MeshPhongMaterial();
        else if (lower == "lambert") material = new MeshLambertMaterial();
        else {
            this.state.warn("unknown material type \"" + type + "\". Defaulting to MeshPhongMaterial.");
            material = new MeshPhongMaterial();
        }
        this.setValues(material, parameters);
        material.name = name;
        return material;
    }

    // Material.setValues for the parameters FBX sets.
    private setValues(material: Material, p: FBXMaterialParameters): void {
        const color = p.color, emissive = p.emissive, specular = p.specular;
        material.opacity = p.opacity;
        if (p.transparent) material.transparent = true;
        if (material instanceof MeshPhongMaterial) {
            const m = material as MeshPhongMaterial;
            if (!isNaN(p.bumpScale)) m.bumpScale = p.bumpScale;
            if (color != null) m.color.copy(color);
            if (!isNaN(p.displacementScale)) m.displacementScale = p.displacementScale;
            if (emissive != null) m.emissive.copy(emissive);
            if (!isNaN(p.emissiveIntensity)) m.emissiveIntensity = p.emissiveIntensity;
            if (!isNaN(p.reflectivity)) m.reflectivity = p.reflectivity;
            if (!isNaN(p.shininess)) m.shininess = p.shininess;
            if (specular != null) m.specular.copy(specular);
            if (p.bumpMap != null) m.bumpMap = p.bumpMap;
            if (p.aoMap != null) m.aoMap = p.aoMap;
            if (p.map != null) m.map = p.map;
            if (p.displacementMap != null) m.displacementMap = p.displacementMap;
            if (p.emissiveMap != null) m.emissiveMap = p.emissiveMap;
            if (p.normalMap != null) m.normalMap = p.normalMap;
            if (p.envMap != null) m.envMap = p.envMap;
            if (p.specularMap != null) m.specularMap = p.specularMap;
            if (p.alphaMap != null) m.alphaMap = p.alphaMap;
        } else if (material instanceof MeshLambertMaterial) {
            const m = material as MeshLambertMaterial;
            if (!isNaN(p.bumpScale)) m.bumpScale = p.bumpScale;
            if (color != null) m.color.copy(color);
            if (!isNaN(p.displacementScale)) m.displacementScale = p.displacementScale;
            if (emissive != null) m.emissive.copy(emissive);
            if (!isNaN(p.emissiveIntensity)) m.emissiveIntensity = p.emissiveIntensity;
            if (!isNaN(p.reflectivity)) m.reflectivity = p.reflectivity;
            if (!isNaN(p.shininess)) this.state.warn("'shininess' is not a property of THREE.MeshLambertMaterial.");
            if (specular != null) this.state.warn("'specular' is not a property of THREE.MeshLambertMaterial.");
            if (p.bumpMap != null) m.bumpMap = p.bumpMap;
            if (p.aoMap != null) m.aoMap = p.aoMap;
            if (p.map != null) m.map = p.map;
            if (p.displacementMap != null) m.displacementMap = p.displacementMap;
            if (p.emissiveMap != null) m.emissiveMap = p.emissiveMap;
            if (p.normalMap != null) m.normalMap = p.normalMap;
            if (p.envMap != null) m.envMap = p.envMap;
            if (p.specularMap != null) m.specularMap = p.specularMap;
            if (p.alphaMap != null) m.alphaMap = p.alphaMap;
        }
    }

    // Parses an FBX material's properties into three.js material
    // parameters, and the texture maps connected to it.
    parseParameters(materialNode: FBXNode, textureMap: Map<i64, Texture>, ID: i64): FBXMaterialParameters {
        const parameters = new FBXMaterialParameters();
        const bumpFactor = materialNode.property("BumpFactor");
        if (bumpFactor != null) parameters.bumpScale = bumpFactor.value.asNumber();
        const diffuse = materialNode.property("Diffuse");
        const diffuseColor = materialNode.property("DiffuseColor");
        if (diffuse != null) {
            parameters.color = colorFromSRGB(diffuse.value.arr);
        } else if (diffuseColor != null && (diffuseColor.type == "Color" || diffuseColor.type == "ColorRGB")) {
            // The blender exporter exports diffuse here instead of in materialNode.Diffuse
            parameters.color = colorFromSRGB(diffuseColor.value.arr);
        }
        const displacementFactor = materialNode.property("DisplacementFactor");
        if (displacementFactor != null) parameters.displacementScale = displacementFactor.value.asNumber();
        const emissive = materialNode.property("Emissive");
        const emissiveColor = materialNode.property("EmissiveColor");
        if (emissive != null) {
            parameters.emissive = colorFromSRGB(emissive.value.arr);
        } else if (emissiveColor != null && (emissiveColor.type == "Color" || emissiveColor.type == "ColorRGB")) {
            // The blender exporter exports emissive color here instead of in materialNode.Emissive
            parameters.emissive = colorFromSRGB(emissiveColor.value.arr);
        }
        const emissiveFactor = materialNode.property("EmissiveFactor");
        if (emissiveFactor != null) parameters.emissiveIntensity = emissiveFactor.value.asNumber();
        // Transparency as Blender's and Unity's importers handle it.
        const transparencyFactor = materialNode.property("TransparencyFactor");
        parameters.opacity = 1 - (transparencyFactor != null ? transparencyFactor.value.asNumber() : 0);
        if (parameters.opacity == 1 || parameters.opacity == 0) {
            const opacity = materialNode.property("Opacity");
            if (opacity != null) parameters.opacity = opacity.value.asNumber();
            else {
                const transparentColor = materialNode.property("TransparentColor");
                const t = transparentColor != null && transparentColor.value.arr.length > 0 ? transparentColor.value.arr[0] : 0;
                parameters.opacity = 1 - t;
            }
        }
        if (parameters.opacity < 1.0) parameters.transparent = true;
        const reflectionFactor = materialNode.property("ReflectionFactor");
        if (reflectionFactor != null) parameters.reflectivity = reflectionFactor.value.asNumber();
        const shininess = materialNode.property("Shininess");
        if (shininess != null) parameters.shininess = shininess.value.asNumber();
        const specular = materialNode.property("Specular");
        const specularColor = materialNode.property("SpecularColor");
        if (specular != null) {
            parameters.specular = colorFromSRGB(specular.value.arr);
        } else if (specularColor != null && specularColor.type == "Color") {
            // The blender exporter exports specular color here instead of in materialNode.Specular
            parameters.specular = colorFromSRGB(specularColor.value.arr);
        }
        const children = this.state.relationships(ID).children;
        for (let i = 0; i < children.length; i++) {
            const child = children[i];
            const type = child.relationship;
            if (type == "Bump") {
                parameters.bumpMap = this.getTexture(textureMap, child.ID);
            } else if (type == "Maya|TEX_ao_map") {
                parameters.aoMap = this.getTexture(textureMap, child.ID);
            } else if (type == "DiffuseColor" || type == "Maya|TEX_color_map") {
                const map = this.getTexture(textureMap, child.ID);
                parameters.map = map;
                if (map != null) map.colorSpace = SRGBColorSpace;
            } else if (type == "DisplacementColor") {
                parameters.displacementMap = this.getTexture(textureMap, child.ID);
            } else if (type == "EmissiveColor") {
                const map = this.getTexture(textureMap, child.ID);
                parameters.emissiveMap = map;
                if (map != null) map.colorSpace = SRGBColorSpace;
            } else if (type == "NormalMap" || type == "Maya|TEX_normal_map") {
                parameters.normalMap = this.getTexture(textureMap, child.ID);
            } else if (type == "ReflectionColor") {
                const map = this.getTexture(textureMap, child.ID);
                parameters.envMap = map;
                if (map != null) {
                    map.mapping = EquirectangularReflectionMapping;
                    map.colorSpace = SRGBColorSpace;
                }
            } else if (type == "SpecularColor") {
                const map = this.getTexture(textureMap, child.ID);
                parameters.specularMap = map;
                if (map != null) map.colorSpace = SRGBColorSpace;
            } else if (type == "TransparentColor" || type == "TransparencyFactor") {
                parameters.alphaMap = this.getTexture(textureMap, child.ID);
                parameters.transparent = true;
            } else {
                // AmbientColor, ShininessExponent (glossiness), SpecularFactor
                // (specular level), VectorDisplacementColor ...
                this.state.warn((type.length > 0 ? type : "undefined") + " map is not supported in three.js, skipping texture.");
            }
        }
        return parameters;
    }

    // A texture of the textureMap for a material; layered textures use their
    // first layer.
    getTexture(textureMap: Map<i64, Texture>, id: i64): Texture? {
        const layered = this.state.fbxTree.objects("LayeredTexture");
        if (layered.has(id)) {
            this.state.warn("layered textures are not supported in three.js. Discarding all but first layer.");
            const children = this.state.relationships(id).children;
            if (children.length > 0) id = children[0].ID;
        }
        return textureMap.has(id) ? textureMap.get(id) : null;
    }

    // Parses the nodes in FBXTree.Objects.Deformer. Skins and blend shapes
    // are read (not vertex caches).
    parseDeformers(): FBXDeformers {
        const deformers = new FBXDeformers();
        const deformerNodes = this.state.fbxTree.objects("Deformer");
        for (let n = 0; n < deformerNodes.ids.length; n++) {
            const nodeID = deformerNodes.ids[n];
            const deformerNode = deformerNodes.get(nodeID);
            const relationships = this.state.relationships(nodeID);
            if (deformerNode.attrType == "Skin") {
                const skeleton = this.parseSkeleton(relationships, deformerNodes);
                skeleton.ID = nodeID;
                if (relationships.parents.length > 1) this.state.warn("skeleton attached to more than one geometry is not supported.");
                if (relationships.parents.length > 0) skeleton.geometryID = relationships.parents[0].ID;
                deformers.skeletons.set(nodeID, skeleton);
                deformers.skeletonIDs.push(nodeID);
            } else if (deformerNode.attrType == "BlendShape") {
                const morphTarget = new FBXMorphTarget();
                morphTarget.rawTargets = this.parseMorphTargets(relationships, deformerNodes);
                morphTarget.id = nodeID;
                if (relationships.parents.length > 1) this.state.warn("morph target attached to more than one geometry is not supported.");
                deformers.morphTargets.set(nodeID, morphTarget);
            }
        }
        return deformers;
    }

    // Parses a Skin deformer: its sub nodes of type Cluster are its bones.
    parseSkeleton(relationships: FBXRelationships, deformerNodes: FBXObjects): FBXSkeleton {
        const skeleton = new FBXSkeleton();
        for (let i = 0; i < relationships.children.length; i++) {
            const child = relationships.children[i];
            if (!deformerNodes.has(child.ID)) continue;
            const boneNode = deformerNodes.get(child.ID);
            if (boneNode.attrType != "Cluster") continue;
            const rawBone = new FBXRawBone();
            rawBone.ID = child.ID;
            const transformLink = boneNode.array("TransformLink");
            if (transformLink != null && transformLink.length >= 16) rawBone.transformLink.fromArray(transformLink);
            const indexes = boneNode.array("Indexes");
            if (indexes != null) {
                rawBone.indices = indexes;
                const weights = boneNode.array("Weights");
                if (weights != null) rawBone.weights = weights;
            }
            skeleton.rawBones.push(rawBone);
        }
        return skeleton;
    }

    // Parses a BlendShape deformer: its sub nodes of type BlendShapeChannel
    // are its morph targets.
    parseMorphTargets(relationships: FBXRelationships, deformerNodes: FBXObjects): Array<FBXRawMorphTarget> {
        const rawMorphTargets: Array<FBXRawMorphTarget> = [];
        for (let i = 0; i < relationships.children.length; i++) {
            const child = relationships.children[i];
            if (!deformerNodes.has(child.ID)) continue;
            const morphTargetNode = deformerNodes.get(child.ID);
            if (morphTargetNode.attrType != "BlendShapeChannel") return rawMorphTargets;
            const rawMorphTarget = new FBXRawMorphTarget();
            rawMorphTarget.name = morphTargetNode.attrName;
            rawMorphTarget.initialWeight = morphTargetNode.number("DeformPercent", 0);
            rawMorphTarget.id = morphTargetNode.id;
            const fullWeights = morphTargetNode.array("FullWeights");
            if (fullWeights != null) rawMorphTarget.fullWeights = fullWeights;
            const shapes = this.state.relationships(child.ID).children;
            let found = false;
            for (let s = 0; s < shapes.length; s++) {
                if (shapes[s].relationship.length == 0) {
                    rawMorphTarget.geoID = shapes[s].ID;
                    found = true;
                    break;
                }
            }
            if (!found) continue;
            rawMorphTargets.push(rawMorphTarget);
        }
        return rawMorphTargets;
    }

    // Creates the Group the loader returns.
    parseScene(deformers: FBXDeformers, geometryMap: Map<i64, BufferGeometry>, materialMap: Map<i64, Material>): void {
        const state = this.state;
        const sceneGraph = new Group();
        state.sceneGraph = sceneGraph;
        const modelMap = this.parseModels(deformers, geometryMap, materialMap);
        const modelNodes = state.fbxTree.objects("Model");
        const ids = modelMap.keys();
        for (let i = 0; i < ids.length; i++) {
            const model = modelMap.get(ids[i]);
            this.setLookAtProperties(model, modelNodes.get(ids[i]));
            const parentConnections = state.relationships(ids[i]).parents;
            for (let p = 0; p < parentConnections.length; p++) {
                const connection = parentConnections[p];
                if (modelMap.has(connection.ID)) modelMap.get(connection.ID).add(model);
            }
            if (model.parent == null) sceneGraph.add(model);
        }
        this.bindSkeleton(deformers, geometryMap, modelMap);
        this.addGlobalSceneSettings();
        this.applyTransforms(sceneGraph);
        const animations = new AnimationParser(state).parse();
        // If all the models were already combined in a single group, return that.
        if (sceneGraph.children.length == 1 && sceneGraph.children[0] instanceof Group) {
            const group = sceneGraph.children[0] as Group;
            group.animations = animations;
            state.sceneGraph = group;
        }
        state.sceneGraph.animations = animations;
    }

    // three.js's sceneGraph.traverse applying each model's transform data.
    private applyTransforms(node: Object3D): void {
        const state = this.state;
        if (state.transformData.has(node.id)) {
            const transformData = state.transformData.get(node.id);
            const parent = node.parent;
            if (parent != null) {
                transformData.parentMatrix = parent.matrix;
                transformData.parentMatrixWorld = parent.matrixWorld;
            }
            const transform = generateTransform(transformData);
            node.applyMatrix4(transform);
            node.updateWorldMatrix(false, false);
        }
        const children = node.children;
        for (let i = 0; i < children.length; i++) this.applyTransforms(children[i]);
    }

    // Parses the nodes in FBXTree.Objects.Model.
    parseModels(deformers: FBXDeformers, geometryMap: Map<i64, BufferGeometry>, materialMap: Map<i64, Material>): Map<i64, Object3D> {
        const state = this.state;
        const modelMap = new Map<i64, Object3D>();
        const modelNodes = state.fbxTree.objects("Model");
        for (let n = 0; n < modelNodes.ids.length; n++) {
            const id = modelNodes.ids[n];
            const node = modelNodes.get(id);
            const relationships = state.relationships(id);
            let model: Object3D;
            const bone = this.buildSkeleton(relationships, deformers, id, node.attrName);
            if (bone != null) {
                model = bone!;
            } else {
                const type = node.attrType;
                if (type == "Camera") model = this.createCamera(relationships);
                else if (type == "Light") model = this.createLight(relationships);
                else if (type == "Mesh") model = this.createMesh(relationships, geometryMap, materialMap);
                else if (type == "NurbsCurve") model = this.createCurve(relationships, geometryMap);
                else if (type == "LimbNode" || type == "Root") model = new Bone();
                else model = new Group();   // Null and others
                model.name = node.attrName.length > 0 ? PropertyBinding.sanitizeNodeName(node.attrName) : "";
                state.loader.originalNames.set(model.id, node.attrName);
                state.modelIDs.set(model.id, id);
            }
            this.getTransformData(model, node);
            modelMap.set(id, model);
        }
        return modelMap;
    }

    buildSkeleton(relationships: FBXRelationships, deformers: FBXDeformers, id: i64, name: string): Bone? {
        let bone: Bone? = null;
        const state = this.state;
        for (let p = 0; p < relationships.parents.length; p++) {
            const parent = relationships.parents[p];
            for (let s = 0; s < deformers.skeletonIDs.length; s++) {
                const skeleton = deformers.skeletons.get(deformers.skeletonIDs[s]);
                for (let i = 0; i < skeleton.rawBones.length; i++) {
                    const rawBone = skeleton.rawBones[i];
                    if (rawBone.ID != parent.ID) continue;
                    const subBone = bone;
                    const b = new Bone();
                    b.matrixWorld.copy(rawBone.transformLink);
                    // name and id here, else a "subBone" would have none
                    b.name = name.length > 0 ? PropertyBinding.sanitizeNodeName(name) : "";
                    state.loader.originalNames.set(b.id, name);
                    state.modelIDs.set(b.id, id);
                    while (skeleton.bones.length <= i) skeleton.bones.push(null);
                    skeleton.bones[i] = b;
                    // A bone shared between several meshes is duplicated,
                    // the copy a child of the first bone.
                    if (subBone != null) b.add(subBone!);
                    bone = b;
                }
            }
        }
        return bone;
    }

    // Creates a PerspectiveCamera (orthographic ones are not supported, as
    // three.js).
    createCamera(relationships: FBXRelationships): Object3D {
        const cameraAttribute = this.nodeAttribute(relationships);
        if (cameraAttribute == null) return new Object3D();
        const attribute = cameraAttribute!;
        let type = 0;
        const projection = attribute.property("CameraProjectionType");
        if (projection != null && projection.value.asNumber() == 1) type = 1;
        let nearClippingPlane: f64 = 1;
        const near = attribute.property("NearPlane");
        if (near != null) nearClippingPlane = near.value.asNumber() / 1000;
        let farClippingPlane: f64 = 1000;
        const far = attribute.property("FarPlane");
        if (far != null) farClippingPlane = far.value.asNumber() / 1000;
        // three.js defaults to the window's size; there is no window here.
        let width: f64 = 1;
        let height: f64 = 1;
        const aspectWidth = attribute.property("AspectWidth");
        const aspectHeight = attribute.property("AspectHeight");
        if (aspectWidth != null && aspectHeight != null) {
            width = aspectWidth.value.asNumber();
            height = aspectHeight.value.asNumber();
        }
        const aspect = width / height;
        let fov: f64 = 45;
        const fieldOfView = attribute.property("FieldOfView");
        if (fieldOfView != null) fov = fieldOfView.value.asNumber();
        const focalLength = attribute.property("FocalLength");
        if (type == 0) {
            const camera = new PerspectiveCamera(fov, aspect, nearClippingPlane, farClippingPlane);
            if (focalLength != null) camera.setFocalLength(focalLength.value.asNumber());
            return camera;
        }
        this.state.warn("Orthographic cameras not supported yet.");
        return new Object3D();
    }

    // Creates a DirectionalLight, PointLight or SpotLight.
    createLight(relationships: FBXRelationships): Object3D {
        const lightAttribute = this.nodeAttribute(relationships);
        if (lightAttribute == null) return new Object3D();
        const attribute = lightAttribute!;
        // LightType can be undefined for point lights.
        const lightType = attribute.property("LightType");
        const type = lightType == null ? 0 : <i32>lightType.value.asNumber();
        const color = new Color(0xffffff);
        const colorProperty = attribute.property("Color");
        if (colorProperty != null) {
            const c = colorFromSRGB(colorProperty.value.arr);
            if (c != null) color.copy(c!);
        }
        const intensityProperty = attribute.property("Intensity");
        let intensity = intensityProperty == null ? 1 : intensityProperty.value.asNumber() / 100;
        // light disabled
        const castLight = attribute.property("CastLightOnObject");
        if (castLight != null && castLight.value.asNumber() == 0) intensity = 0;
        let distance: f64 = 0;
        const farAttenuationEnd = attribute.property("FarAttenuationEnd");
        if (farAttenuationEnd != null) {
            const enable = attribute.property("EnableFarAttenuation");
            if (enable != null && enable.value.asNumber() == 0) distance = 0;
            else distance = farAttenuationEnd.value.asNumber();
        }
        // TODO (three.js): could this be calculated linearly from FarAttenuationStart to FarAttenuationEnd?
        const decay: f64 = 1;
        let model: Object3D;
        if (type == 0) {
            const light = new PointLight(0xffffff, intensity, distance, decay);
            light.color.copy(color);
            model = light;
        } else if (type == 1) {
            const light = new DirectionalLight(0xffffff, intensity);
            light.color.copy(color);
            model = light;
        } else if (type == 2) {
            let angle = Math.PI / 3;
            const innerAngle = attribute.property("InnerAngle");
            if (innerAngle != null) angle = MathUtils.degToRad(innerAngle.value.asNumber());
            let penumbra: f64 = 0;
            const outerAngle = attribute.property("OuterAngle");
            if (outerAngle != null) {
                // As three.js (its TODO: FBX's outer angle is in degrees, the
                // penumbra a 0-1 fraction of the inner angle).
                penumbra = MathUtils.degToRad(outerAngle.value.asNumber());
                penumbra = Math.max(penumbra, 1);
            }
            const light = new SpotLight(0xffffff, intensity, distance, angle, penumbra, decay);
            light.color.copy(color);
            model = light;
        } else {
            this.state.warn("Unknown light type " + type.toString() + ", defaulting to a PointLight.");
            const light = new PointLight(0xffffff, intensity);
            light.color.copy(color);
            model = light;
        }
        const castShadows = attribute.property("CastShadows");
        if (castShadows != null && castShadows.value.asNumber() == 1) model.castShadow = true;
        return model;
    }

    // The (last) NodeAttribute among the children.
    private nodeAttribute(relationships: FBXRelationships): FBXNode? {
        const attributes = this.state.fbxTree.objects("NodeAttribute");
        let found: FBXNode? = null;
        for (let i = 0; i < relationships.children.length; i++) {
            const child = relationships.children[i];
            if (attributes.has(child.ID)) found = attributes.get(child.ID);
        }
        return found;
    }

    createMesh(relationships: FBXRelationships, geometryMap: Map<i64, BufferGeometry>, materialMap: Map<i64, Material>): Mesh {
        let geometry: BufferGeometry? = null;
        const materials: Array<Material> = [];
        // the geometry and materials from the connections
        for (let i = 0; i < relationships.children.length; i++) {
            const child = relationships.children[i];
            if (geometryMap.has(child.ID)) geometry = geometryMap.get(child.ID);
            if (materialMap.has(child.ID)) materials.push(materialMap.get(child.ID));
        }
        if (materials.length == 0) {
            const material = new MeshPhongMaterial({ name: Loader.DEFAULT_MATERIAL_NAME, color: 0xcccccc });
            materials.push(material);
        }
        if (geometry == null) {
            this.state.warn("mesh without geometry");
            geometry = new BufferGeometry();
        }
        const geo = geometry!;
        if (geo.hasAttribute("color")) {
            for (let i = 0; i < materials.length; i++) materials[i].vertexColors = true;
        }
        let model: Mesh;
        if (this.state.geometryDeformers.has(geo.id)) {
            const skinned = new SkinnedMesh(geo, materials[0]);
            skinned.normalizeSkinWeights();
            model = skinned;
        } else {
            model = new Mesh(geo, materials[0]);
        }
        if (materials.length > 1) model.materials = materials;
        if (geo.morphAttributes.size > 0) model.updateMorphTargets();
        return model;
    }

    createCurve(relationships: FBXRelationships, geometryMap: Map<i64, BufferGeometry>): Line {
        let geometry: BufferGeometry? = null;
        for (let i = 0; i < relationships.children.length; i++) {
            const child = relationships.children[i];
            if (geometryMap.has(child.ID)) geometry = geometryMap.get(child.ID);
        }
        // FBX does not list materials for Nurbs lines, so we'll just put our own in here.
        const material = new LineBasicMaterial({ name: Loader.DEFAULT_MATERIAL_NAME, color: 0x3300ff, linewidth: 1 });
        return new Line(geometry != null ? geometry! : new BufferGeometry(), material);
    }

    // The model node's transform data.
    getTransformData(model: Object3D, modelNode: FBXNode): void {
        const transformData = new FBXTransformData();
        const inheritType = modelNode.property("InheritType");
        if (inheritType != null) transformData.inheritType = <i32>inheritType.value.asNumber();
        const rotationOrder = modelNode.property("RotationOrder");
        if (rotationOrder != null) transformData.eulerOrder = this.eulerOrder(<i32>rotationOrder.value.asNumber());
        else transformData.eulerOrder = getEulerOrder(0);
        transformData.translation = vectorProperty(modelNode, "Lcl_Translation");
        transformData.preRotation = vectorProperty(modelNode, "PreRotation");
        transformData.rotation = vectorProperty(modelNode, "Lcl_Rotation");
        transformData.postRotation = vectorProperty(modelNode, "PostRotation");
        transformData.scale = vectorProperty(modelNode, "Lcl_Scaling");
        transformData.scalingOffset = vectorProperty(modelNode, "ScalingOffset");
        transformData.scalingPivot = vectorProperty(modelNode, "ScalingPivot");
        transformData.rotationOffset = vectorProperty(modelNode, "RotationOffset");
        transformData.rotationPivot = vectorProperty(modelNode, "RotationPivot");
        this.state.transformData.set(model.id, transformData);
    }

    private eulerOrder(order: i32): string {
        if (order == 6) this.state.warn("unsupported Euler Order: Spherical XYZ. Animations and rotations may be incorrect.");
        return getEulerOrder(order);
    }

    setLookAtProperties(model: Object3D, modelNode: FBXNode): void {
        if (modelNode.property("LookAtProperty") == null) return;
        const state = this.state;
        const ID = state.modelIDs.has(model.id) ? state.modelIDs.get(model.id) : <i64>0;
        const children = state.relationships(ID).children;
        const models = state.fbxTree.objects("Model");
        for (let i = 0; i < children.length; i++) {
            const child = children[i];
            if (child.relationship != "LookAtProperty" || !models.has(child.ID)) continue;
            const lookAtTarget = models.get(child.ID);
            const pos = vectorProperty(lookAtTarget, "Lcl_Translation");
            if (pos == null) continue;
            if (model instanceof DirectionalLight) {
                const target = (model as DirectionalLight).target;
                target.position.fromArray(pos!);
                state.sceneGraph.add(target);
            } else if (model instanceof SpotLight) {
                const target = (model as SpotLight).target;
                target.position.fromArray(pos!);
                state.sceneGraph.add(target);
            } else {
                // Cameras and other Object3Ds
                model.lookAt(new Vector3().fromArray(pos!));
            }
        }
    }

    bindSkeleton(deformers: FBXDeformers, geometryMap: Map<i64, BufferGeometry>, modelMap: Map<i64, Object3D>): void {
        const state = this.state;
        const bindMatrices = this.parsePoseNodes();
        for (let s = 0; s < deformers.skeletonIDs.length; s++) {
            const skeleton = deformers.skeletons.get(deformers.skeletonIDs[s]);
            const parents = state.relationships(skeleton.ID).parents;
            for (let p = 0; p < parents.length; p++) {
                const parent = parents[p];
                if (!geometryMap.has(parent.ID)) continue;
                const geoRelationships = state.relationships(parent.ID);
                for (let g = 0; g < geoRelationships.parents.length; g++) {
                    const geoConnParent = geoRelationships.parents[g];
                    if (!modelMap.has(geoConnParent.ID)) continue;
                    const model = modelMap.get(geoConnParent.ID);
                    if (!(model instanceof SkinnedMesh)) continue;
                    const mesh = model as SkinnedMesh;
                    const bones: Array<Bone> = [];
                    for (let b = 0; b < skeleton.bones.length; b++) {
                        const bone = skeleton.bones[b];
                        bones.push(bone != null ? bone! : new Bone());
                    }
                    // three.js's Skeleton takes the bones' world matrices
                    // (their TransformLinks, set in buildSkeleton) as is.
                    const threeSkeleton = new Skeleton(bones, calculateInverses(bones));
                    if (bindMatrices.has(geoConnParent.ID)) {
                        mesh.bind(threeSkeleton, bindMatrices.get(geoConnParent.ID));
                    } else {
                        mesh.updateMatrixWorld(true);
                        threeSkeleton.boneInverses = calculateInverses(bones);
                        mesh.bind(threeSkeleton, mesh.matrixWorld.clone());
                    }
                }
            }
        }
    }

    parsePoseNodes(): Map<i64, Matrix4> {
        const bindMatrices = new Map<i64, Matrix4>();
        const poseNodes = this.state.fbxTree.objects("Pose");
        for (let n = 0; n < poseNodes.ids.length; n++) {
            const pose = poseNodes.get(poseNodes.ids[n]);
            if (pose.attrType != "BindPose" || !(pose.number("NbPoseNodes", 0) > 0)) continue;
            const nodes = pose.nodesNamed("PoseNode");
            for (let i = 0; i < nodes.length; i++) {
                const poseNode = nodes[i];
                const node = poseNode.value("Node");
                const matrix = poseNode.array("Matrix");
                if (node == null || matrix == null || matrix.length < 16) continue;
                bindMatrices.set(node.asLong(), new Matrix4().fromArray(matrix));
            }
        }
        return bindMatrices;
    }

    addGlobalSceneSettings(): void {
        const state = this.state;
        const globalSettings = state.fbxTree.node("GlobalSettings");
        if (globalSettings == null) return;
        const ambient = globalSettings.property("AmbientColor");
        if (ambient != null) {
            // Parse ambient color - if it's not set to black (default), create an ambient light
            const ambientColor = ambient.value.arr;
            if (ambientColor.length >= 3) {
                const r = ambientColor[0], g = ambientColor[1], b = ambientColor[2];
                if (r != 0 || g != 0 || b != 0) {
                    const light = new AmbientLight(0xffffff, 1);
                    light.color.setRGB(r, g, b, SRGBColorSpace);
                    state.sceneGraph.add(light);
                }
            }
        }
        const unitScaleFactor = globalSettings.property("UnitScaleFactor");
        if (unitScaleFactor != null) state.loader.unitScaleFactor = unitScaleFactor.value.asNumber();
    }
}

/// three.js's Skeleton.calculateInverses: the inverses of the bones' world
/// matrices as they are (ThreeAS's Skeleton updates them first).
function calculateInverses(bones: Array<Bone>): Array<Matrix4> {
    const inverses: Array<Matrix4> = [];
    for (let i = 0; i < bones.length; i++) inverses.push(bones[i].matrixWorld.clone().invert());
    return inverses;
}

/// A colour property's value, from sRGB to the working (linear) space.
function colorFromSRGB(values: Array<f64>): Color? {
    if (values.length < 3) return null;
    return new Color().setRGB(values[0], values[1], values[2], SRGBColorSpace);
}

/// A vector property's value (null when absent).
function vectorProperty(node: FBXNode, name: string): Array<f64>? {
    const property = node.property(name);
    if (property == null || property.value.kind != FBX_ARRAY) return null;
    return property.value.arr;
}

/// RelativeFilename, else Filename.
function videoFileName(videoNode: FBXNode): string {
    const relative = videoNode.string("RelativeFilename", "");
    return relative.length > 0 ? relative : videoNode.string("Filename", "");
}

/// What follows the last `separator` (the whole string without one).
function lastPart(s: string, separator: string): string {
    const i = s.lastIndexOf(separator);
    return i >= 0 ? s.substring(i + separator.length) : s;
}

/// The asset name for a file a model references: its name without folders
/// or extension.
function assetName(fileName: string): string {
    let name = lastPart(lastPart(fileName, "\\"), "/");
    const dot = name.lastIndexOf(".");
    if (dot > 0) name = name.substring(0, dot);
    return name;
}

// ================================================================= geometry

class FBXLayerInfo {
    dataSize: i32 = 1;
    buffer: Array<f64> = [];
    indices: Array<f64> = [];
    mappingType: string = "";
    referenceType: string = "";
}

class FBXWeight {
    id: i32;
    weight: f64;

    constructor(id: i32, weight: f64) {
        this.id = id;
        this.weight = weight;
    }
}

class FBXGeoInfo {
    vertexPositions: Array<f64> = [];
    baseVertexPositions: Array<f64>? = null;
    vertexIndices: Array<f64> = [];
    color: FBXLayerInfo? = null;
    material: FBXLayerInfo? = null;
    normal: FBXLayerInfo? = null;
    uv: Array<FBXLayerInfo> = [];
    weightTable: Map<i32, Array<FBXWeight>> = new Map<i32, Array<FBXWeight>>();
    skeleton: FBXSkeleton? = null;
}

class FBXBuffers {
    vertex: Array<f64> = [];
    normal: Array<f64> = [];
    colors: Array<f64> = [];
    uvs: Array<Array<f64>> = [];
    materialIndex: Array<i32> = [];
    vertexWeights: Array<f64> = [];
    weightsIndices: Array<f64> = [];
}

// Parses the geometry data of the FBXTree and returns a map of
// BufferGeometries.
class GeometryParser {
    state: FBXState;
    negativeMaterialIndices: bool = false;

    constructor(state: FBXState) {
        this.state = state;
    }

    // Parses the nodes in FBXTree.Objects.Geometry.
    parse(deformers: FBXDeformers): Map<i64, BufferGeometry> {
        const geometryMap = new Map<i64, BufferGeometry>();
        const geoNodes = this.state.fbxTree.objects("Geometry");
        for (let n = 0; n < geoNodes.ids.length; n++) {
            const nodeID = geoNodes.ids[n];
            const relationships = this.state.relationships(nodeID);
            const geo = this.parseGeometry(relationships, geoNodes.get(nodeID), deformers);
            if (geo != null) geometryMap.set(nodeID, geo!);
        }
        if (this.negativeMaterialIndices) {
            this.state.warn("The FBX file contains invalid (negative) material indices. The asset might not render as expected.");
        }
        return geometryMap;
    }

    // Parses one node of FBXTree.Objects.Geometry.
    parseGeometry(relationships: FBXRelationships, geoNode: FBXNode, deformers: FBXDeformers): BufferGeometry? {
        if (geoNode.attrType == "Mesh") return this.parseMeshGeometry(relationships, geoNode, deformers);
        if (geoNode.attrType == "NurbsCurve") return this.parseNurbsGeometry(geoNode);
        return null;
    }

    // Parses one mesh geometry node of FBXTree.Objects.Geometry.
    parseMeshGeometry(relationships: FBXRelationships, geoNode: FBXNode, deformers: FBXDeformers): BufferGeometry? {
        const models = this.state.fbxTree.objects("Model");
        // Assume one model and take the geometric transform from that one;
        // a geometry shared by several models may cause problems.
        let modelNode: FBXNode? = null;
        for (let i = 0; i < relationships.parents.length; i++) {
            if (models.has(relationships.parents[i].ID)) {
                modelNode = models.get(relationships.parents[i].ID);
                break;
            }
        }
        // don't create geometry if it is not associated with any models
        if (modelNode == null) return null;
        let skeleton: FBXSkeleton? = null;
        const morphTargets: Array<FBXMorphTarget> = [];
        for (let i = 0; i < relationships.children.length; i++) {
            const child = relationships.children[i];
            if (deformers.skeletons.has(child.ID)) skeleton = deformers.skeletons.get(child.ID);
            if (deformers.morphTargets.has(child.ID)) morphTargets.push(deformers.morphTargets.get(child.ID));
        }
        const node = modelNode!;
        const transformData = new FBXTransformData();
        const rotationOrder = node.property("RotationOrder");
        if (rotationOrder != null) transformData.eulerOrder = getEulerOrder(<i32>rotationOrder.value.asNumber());
        const inheritType = node.property("InheritType");
        if (inheritType != null) transformData.inheritType = <i32>inheritType.value.asNumber();
        transformData.translation = vectorProperty(node, "GeometricTranslation");
        transformData.rotation = vectorProperty(node, "GeometricRotation");
        transformData.scale = vectorProperty(node, "GeometricScaling");
        const transform = generateTransform(transformData);
        return this.genGeometry(geoNode, skeleton, morphTargets, transform);
    }

    // Generates a BufferGeometry from a node in FBXTree.Objects.Geometry.
    genGeometry(geoNode: FBXNode, skeleton: FBXSkeleton?, morphTargets: Array<FBXMorphTarget>, preTransform: Matrix4): BufferGeometry {
        const geo = new BufferGeometry();
        if (geoNode.attrName.length > 0) geo.name = geoNode.attrName;
        const geoInfo = this.parseGeoNode(geoNode, skeleton);
        const buffers = this.genBuffers(geoInfo);
        const positionAttribute = new Float32BufferAttribute(buffers.vertex, 3);
        positionAttribute.applyMatrix4(preTransform);
        geo.setAttribute("position", positionAttribute);
        if (buffers.colors.length > 0) geo.setAttribute("color", new Float32BufferAttribute(buffers.colors, 3));
        if (skeleton != null) {
            geo.setAttribute("skinIndex", new Float32BufferAttribute(buffers.weightsIndices, 4));
            geo.setAttribute("skinWeight", new Float32BufferAttribute(buffers.vertexWeights, 4));
            // used later to bind the skeleton to the model
            this.state.geometryDeformers.set(geo.id, skeleton!);
        }
        if (buffers.normal.length > 0) {
            const normalMatrix = new Matrix3().getNormalMatrix(preTransform);
            const normalAttribute = new Float32BufferAttribute(buffers.normal, 3);
            normalAttribute.applyNormalMatrix(normalMatrix);
            geo.setAttribute("normal", normalAttribute);
        }
        for (let i = 0; i < buffers.uvs.length; i++) {
            const name = i == 0 ? "uv" : "uv" + i.toString();
            geo.setAttribute(name, new Float32BufferAttribute(buffers.uvs[i], 2));
        }
        const material = geoInfo.material;
        if (material != null && material.mappingType != "AllSame" && buffers.materialIndex.length > 0) {
            // The material indices of the vertices become the geometry's groups.
            const materialIndex = buffers.materialIndex;
            let prevMaterialIndex = materialIndex[0];
            let startIndex = 0;
            for (let i = 0; i < materialIndex.length; i++) {
                const currentIndex = materialIndex[i];
                if (currentIndex != prevMaterialIndex) {
                    geo.addGroup(startIndex, i - startIndex, prevMaterialIndex);
                    prevMaterialIndex = currentIndex;
                    startIndex = i;
                }
            }
            // the loop above doesn't add the last group, do that here.
            if (geo.groups.length > 0) {
                const lastGroup = geo.groups[geo.groups.length - 1];
                const lastIndex = lastGroup.start + lastGroup.count;
                if (lastIndex != materialIndex.length) geo.addGroup(lastIndex, materialIndex.length - lastIndex, prevMaterialIndex);
            }
            // several materials, the whole geometry using one of them
            if (geo.groups.length == 0) geo.addGroup(0, materialIndex.length, materialIndex[0]);
        }
        this.addMorphTargets(geo, geoNode, morphTargets, preTransform);
        return geo;
    }

    parseGeoNode(geoNode: FBXNode, skeleton: FBXSkeleton?): FBXGeoInfo {
        const geoInfo = new FBXGeoInfo();
        const vertices = geoNode.array("Vertices");
        if (vertices != null) geoInfo.vertexPositions = vertices;
        const indices = geoNode.array("PolygonVertexIndex");
        if (indices != null) geoInfo.vertexIndices = indices;
        const colors = geoNode.nodesNamed("LayerElementColor");
        if (colors.length > 0) geoInfo.color = this.parseVertexColors(colors[0]);
        const materials = geoNode.nodesNamed("LayerElementMaterial");
        if (materials.length > 0) geoInfo.material = this.parseMaterialIndices(materials[0]);
        const normals = geoNode.nodesNamed("LayerElementNormal");
        if (normals.length > 0) geoInfo.normal = this.parseNormals(normals[0]);
        const uvs = geoNode.nodesNamed("LayerElementUV");
        for (let i = 0; i < uvs.length; i++) {
            if (uvs[i].array("UV") != null) geoInfo.uv.push(this.parseUVs(uvs[i]));
        }
        if (skeleton != null) {
            geoInfo.skeleton = skeleton;
            const rawBones = skeleton.rawBones;
            for (let i = 0; i < rawBones.length; i++) {
                const rawBone = rawBones[i];
                // the bone's vertex indices and weights
                for (let j = 0; j < rawBone.indices.length; j++) {
                    const index = <i32>rawBone.indices[j];
                    if (!geoInfo.weightTable.has(index)) geoInfo.weightTable.set(index, []);
                    const weight = j < rawBone.weights.length ? rawBone.weights[j] : NaN;
                    geoInfo.weightTable.get(index).push(new FBXWeight(i, weight));
                }
            }
        }
        return geoInfo;
    }

    genBuffers(geoInfo: FBXGeoInfo): FBXBuffers {
        const buffers = new FBXBuffers();
        let polygonIndex = 0;
        let faceLength = 0;
        let displayedWeightsWarning = false;
        // a single face's data (emptied, not reallocated, after each face)
        const facePositionIndexes: Array<i32> = [];
        const faceNormals: Array<f64> = [];
        const faceColors: Array<f64> = [];
        const faceUVs: Array<Array<f64>> = newArrays(geoInfo.uv.length);
        const faceWeights: Array<f64> = [];
        const faceWeightIndices: Array<f64> = [];
        // a vertex's weights
        const weights: Array<f64> = [];
        const weightIndices: Array<f64> = [];
        const wIndex: Array<f64> = [0, 0, 0, 0];
        const Weight: Array<f64> = [0, 0, 0, 0];
        const color = geoInfo.color, normal = geoInfo.normal, material = geoInfo.material;
        const skeleton = geoInfo.skeleton;
        const vertexIndices = geoInfo.vertexIndices;
        for (let polygonVertexIndex = 0; polygonVertexIndex < vertexIndices.length; polygonVertexIndex++) {
            let vertexIndex = <i32>vertexIndices[polygonVertexIndex];
            let materialIndex = 0;
            let endOfFace = false;
            // Face and vertex indices share one array; a negative index ends
            // a face (its vertex is index ^ -1):
            // PolygonVertexIndex: *24 { a: 0, 1, 3, -3, 2, 3, 5, -5, ... }
            if (vertexIndex < 0) {
                vertexIndex = vertexIndex ^ -1;   // (x * -1) - 1
                endOfFace = true;
            }
            facePositionIndexes.push(vertexIndex * 3);
            facePositionIndexes.push(vertexIndex * 3 + 1);
            facePositionIndexes.push(vertexIndex * 3 + 2);
            if (color != null) {
                getData(polygonVertexIndex, polygonIndex, vertexIndex, color);
                faceColors.push(dataArray[0]);
                faceColors.push(dataArray[1]);
                faceColors.push(dataArray[2]);
            }
            if (skeleton != null) {
                weights.length = 0;
                weightIndices.length = 0;
                if (geoInfo.weightTable.has(vertexIndex)) {
                    const table = geoInfo.weightTable.get(vertexIndex);
                    for (let w = 0; w < table.length; w++) {
                        weights.push(table[w].weight);
                        weightIndices.push(<f64>table[w].id);
                    }
                }
                if (weights.length > 4) {
                    if (!displayedWeightsWarning) {
                        this.state.warn("Vertex has more than 4 skinning weights assigned to vertex. Deleting additional weights.");
                        displayedWeightsWarning = true;
                    }
                    for (let k = 0; k < 4; k++) {
                        wIndex[k] = 0;
                        Weight[k] = 0;
                    }
                    for (let weightIndex = 0; weightIndex < weights.length; weightIndex++) {
                        let currentWeight = weights[weightIndex];
                        let currentIndex = weightIndices[weightIndex];
                        for (let compared = 0; compared < 4; compared++) {
                            const comparedWeight = Weight[compared];
                            if (currentWeight > comparedWeight) {
                                Weight[compared] = currentWeight;
                                currentWeight = comparedWeight;
                                const tmp = wIndex[compared];
                                wIndex[compared] = currentIndex;
                                currentIndex = tmp;
                            }
                        }
                    }
                    weights.length = 4;
                    weightIndices.length = 4;
                    for (let k = 0; k < 4; k++) {
                        weights[k] = Weight[k];
                        weightIndices[k] = wIndex[k];
                    }
                }
                // if the weight array is shorter than 4 pad with 0s
                while (weights.length < 4) {
                    weights.push(0);
                    weightIndices.push(0);
                }
                for (let i = 0; i < 4; ++i) {
                    faceWeights.push(weights[i]);
                    faceWeightIndices.push(weightIndices[i]);
                }
            }
            if (normal != null) {
                getData(polygonVertexIndex, polygonIndex, vertexIndex, normal);
                faceNormals.push(dataArray[0]);
                faceNormals.push(dataArray[1]);
                faceNormals.push(dataArray[2]);
            }
            if (material != null && material.mappingType != "AllSame") {
                getData(polygonVertexIndex, polygonIndex, vertexIndex, material);
                const index = dataArray[0];
                materialIndex = isNaN(index) ? 0 : <i32>index;
                if (materialIndex < 0) {
                    this.negativeMaterialIndices = true;
                    materialIndex = 0;   // fallback
                }
            }
            for (let i = 0; i < geoInfo.uv.length; i++) {
                getData(polygonVertexIndex, polygonIndex, vertexIndex, geoInfo.uv[i]);
                faceUVs[i].push(dataArray[0]);
                faceUVs[i].push(dataArray[1]);
            }
            faceLength++;
            if (endOfFace) {
                this.genFace(buffers, geoInfo, facePositionIndexes, materialIndex, faceNormals, faceColors, faceUVs,
                    faceWeights, faceWeightIndices, faceLength);
                polygonIndex++;
                faceLength = 0;
                // reset arrays for the next face
                facePositionIndexes.length = 0;
                faceNormals.length = 0;
                faceColors.length = 0;
                for (let i = 0; i < faceUVs.length; i++) faceUVs[i].length = 0;
                faceWeights.length = 0;
                faceWeightIndices.length = 0;
            }
        }
        return buffers;
    }

    // See https://www.khronos.org/opengl/wiki/Calculating_a_Surface_Normal
    getNormalNewell(vertices: Array<Vector3>): Vector3 {
        const normal = new Vector3(0.0, 0.0, 0.0);
        for (let i = 0; i < vertices.length; i++) {
            const current = vertices[i];
            const next = vertices[(i + 1) % vertices.length];
            normal.x += (current.y - next.y) * (current.z + next.z);
            normal.y += (current.z - next.z) * (current.x + next.x);
            normal.z += (current.x - next.x) * (current.y + next.y);
        }
        normal.normalize();
        return normal;
    }

    /// [normal, tangent, bitangent] (three.js returns an object).
    getNormalTangentAndBitangent(vertices: Array<Vector3>): Array<Vector3> {
        const normalVector = this.getNormalNewell(vertices);
        // Avoid up being equal or almost equal to normalVector
        const up = Math.abs(normalVector.z) > 0.5 ? new Vector3(0.0, 1.0, 0.0) : new Vector3(0.0, 0.0, 1.0);
        const tangent = up.cross(normalVector).normalize();
        const bitangent = normalVector.clone().cross(tangent).normalize();
        return [normalVector, tangent, bitangent];
    }

    flattenVertex(vertex: Vector3, normalTangent: Vector3, normalBitangent: Vector3): Vector2 {
        return new Vector2(vertex.dot(normalTangent), vertex.dot(normalBitangent));
    }

    // Generates the data of one face; a polygon of more than three vertices
    // is triangulated (earcut, in the polygon's plane).
    genFace(buffers: FBXBuffers, geoInfo: FBXGeoInfo, facePositionIndexes: Array<i32>, materialIndex: i32,
            faceNormals: Array<f64>, faceColors: Array<f64>, faceUVs: Array<Array<f64>>, faceWeights: Array<f64>,
            faceWeightIndices: Array<f64>, faceLength: i32): void {
        let triangles: Array<Array<i32>>;
        if (faceLength > 3) {
            const vertices: Array<Vector3> = [];
            // in morphing scenario vertexPositions represent morphPositions
            // while baseVertexPositions represent the original geometry's positions
            const base = geoInfo.baseVertexPositions;
            const positions = base != null ? base! : geoInfo.vertexPositions;
            for (let i = 0; i < facePositionIndexes.length; i += 3) {
                vertices.push(new Vector3(
                    at(positions, facePositionIndexes[i]),
                    at(positions, facePositionIndexes[i + 1]),
                    at(positions, facePositionIndexes[i + 2])));
            }
            const frame = this.getNormalTangentAndBitangent(vertices);
            const tangent = frame[1], bitangent = frame[2];
            const triangulationInput: Array<Vector2> = [];
            for (let i = 0; i < vertices.length; i++) triangulationInput.push(this.flattenVertex(vertices[i], tangent, bitangent));
            // Faces not taking part in a morph flatten to points at the
            // origin and give no triangles: hence baseVertexPositions above.
            triangles = ShapeUtils.triangulateShape(triangulationInput, []);
        } else {
            // Regular triangle, skip earcut triangulation step
            triangles = [[0, 1, 2]];
        }
        const positions = geoInfo.vertexPositions;
        for (let t = 0; t < triangles.length; t++) {
            const tri = triangles[t];
            for (let k = 0; k < 3; k++) {
                const v = tri[k];
                buffers.vertex.push(at(positions, facePositionIndexes[v * 3]));
                buffers.vertex.push(at(positions, facePositionIndexes[v * 3 + 1]));
                buffers.vertex.push(at(positions, facePositionIndexes[v * 3 + 2]));
            }
            if (geoInfo.skeleton != null) {
                for (let k = 0; k < 3; k++) {
                    const v = tri[k];
                    for (let c = 0; c < 4; c++) buffers.vertexWeights.push(faceWeights[v * 4 + c]);
                }
                for (let k = 0; k < 3; k++) {
                    const v = tri[k];
                    for (let c = 0; c < 4; c++) buffers.weightsIndices.push(faceWeightIndices[v * 4 + c]);
                }
            }
            if (geoInfo.color != null) {
                for (let k = 0; k < 3; k++) {
                    const v = tri[k];
                    for (let c = 0; c < 3; c++) buffers.colors.push(faceColors[v * 3 + c]);
                }
            }
            const material = geoInfo.material;
            if (material != null && material.mappingType != "AllSame") {
                buffers.materialIndex.push(materialIndex);
                buffers.materialIndex.push(materialIndex);
                buffers.materialIndex.push(materialIndex);
            }
            if (geoInfo.normal != null) {
                for (let k = 0; k < 3; k++) {
                    const v = tri[k];
                    for (let c = 0; c < 3; c++) buffers.normal.push(faceNormals[v * 3 + c]);
                }
            }
            for (let j = 0; j < geoInfo.uv.length; j++) {
                while (buffers.uvs.length <= j) buffers.uvs.push([]);
                const uvs = buffers.uvs[j];
                const face = faceUVs[j];
                for (let k = 0; k < 3; k++) {
                    const v = tri[k];
                    uvs.push(face[v * 2]);
                    uvs.push(face[v * 2 + 1]);
                }
            }
        }
    }

    addMorphTargets(parentGeo: BufferGeometry, parentGeoNode: FBXNode, morphTargets: Array<FBXMorphTarget>, preTransform: Matrix4): void {
        if (morphTargets.length == 0) return;
        parentGeo.morphTargetsRelative = true;
        const positions: Array<BufferAttribute> = [];
        parentGeo.morphAttributes.set("position", positions);
        // parentGeo.morphAttributes.normal = []; // not implemented (three.js)
        const geometries = this.state.fbxTree.objects("Geometry");
        for (let m = 0; m < morphTargets.length; m++) {
            const rawTargets = morphTargets[m].rawTargets;
            for (let r = 0; r < rawTargets.length; r++) {
                const rawTarget = rawTargets[r];
                if (geometries.has(rawTarget.geoID)) {
                    this.genMorphGeometry(parentGeo, parentGeoNode, geometries.get(rawTarget.geoID), preTransform, rawTarget.name);
                }
            }
        }
    }

    // A morph geometry node (a Shape) is like a geometry node, but holds
    // positions and normals of the affected vertices only, and their
    // indices in the original geometry (Indexes).
    genMorphGeometry(parentGeo: BufferGeometry, parentGeoNode: FBXNode, morphGeoNode: FBXNode, preTransform: Matrix4, name: string): void {
        const vertices = parentGeoNode.array("Vertices");
        const basePositions = vertices != null ? vertices! : new Array<f64>(0);
        const indices = parentGeoNode.array("PolygonVertexIndex");
        const baseIndices = indices != null ? indices! : new Array<f64>(0);
        const morphVertices = morphGeoNode.array("Vertices");
        const morphPositionsSparse = morphVertices != null ? morphVertices! : new Array<f64>(0);
        const morphIndexes = morphGeoNode.array("Indexes");
        const morphIndices = morphIndexes != null ? morphIndexes! : new Array<f64>(0);
        const position = parentGeo.getAttribute("position");
        const length = position != null ? position.count * 3 : 0;
        const morphPositions = new Array<f64>(length);
        for (let i = 0; i < morphIndices.length; i++) {
            const morphIndex = <i32>morphIndices[i] * 3;
            if (morphIndex < 0 || morphIndex + 2 >= length) continue;
            morphPositions[morphIndex] = at(morphPositionsSparse, i * 3);
            morphPositions[morphIndex + 1] = at(morphPositionsSparse, i * 3 + 1);
            morphPositions[morphIndex + 2] = at(morphPositionsSparse, i * 3 + 2);
        }
        // TODO (three.js): add morph normal support
        const morphGeoInfo = new FBXGeoInfo();
        morphGeoInfo.vertexIndices = baseIndices;
        morphGeoInfo.vertexPositions = morphPositions;
        morphGeoInfo.baseVertexPositions = basePositions;
        const morphBuffers = this.genBuffers(morphGeoInfo);
        const positionAttribute = new Float32BufferAttribute(morphBuffers.vertex, 3);
        positionAttribute.name = name.length > 0 ? name : morphGeoNode.attrName;
        positionAttribute.applyMatrix4(preTransform);
        parentGeo.morphAttributes.get("position").push(positionAttribute);
    }

    // The normals of FBXTree.Objects.Geometry.LayerElementNormal.
    parseNormals(NormalNode: FBXNode): FBXLayerInfo {
        const info = new FBXLayerInfo();
        info.dataSize = 3;
        info.mappingType = NormalNode.string("MappingInformationType", "");
        info.referenceType = NormalNode.string("ReferenceInformationType", "");
        const buffer = NormalNode.array("Normals");
        if (buffer != null) info.buffer = buffer;
        if (info.referenceType == "IndexToDirect") {
            const normalIndex = NormalNode.array("NormalIndex");
            const normalsIndex = NormalNode.array("NormalsIndex");
            if (normalIndex != null) info.indices = normalIndex;
            else if (normalsIndex != null) info.indices = normalsIndex;
        }
        return info;
    }

    // The uvs of FBXTree.Objects.Geometry.LayerElementUV.
    parseUVs(UVNode: FBXNode): FBXLayerInfo {
        const info = new FBXLayerInfo();
        info.dataSize = 2;
        info.mappingType = UVNode.string("MappingInformationType", "");
        info.referenceType = UVNode.string("ReferenceInformationType", "");
        const buffer = UVNode.array("UV");
        if (buffer != null) info.buffer = buffer;
        if (info.referenceType == "IndexToDirect") {
            const uvIndex = UVNode.array("UVIndex");
            if (uvIndex != null) info.indices = uvIndex;
        }
        return info;
    }

    // The vertex colours of FBXTree.Objects.Geometry.LayerElementColor,
    // from sRGB to linear.
    parseVertexColors(ColorNode: FBXNode): FBXLayerInfo {
        const info = new FBXLayerInfo();
        info.dataSize = 4;
        info.mappingType = ColorNode.string("MappingInformationType", "");
        info.referenceType = ColorNode.string("ReferenceInformationType", "");
        const colors = ColorNode.array("Colors");
        const buffer = colors != null ? colors!.slice() : new Array<f64>(0);
        if (info.referenceType == "IndexToDirect") {
            const colorIndex = ColorNode.array("ColorIndex");
            if (colorIndex != null) info.indices = colorIndex;
        }
        const c = new Color();
        for (let i = 0; i + 2 < buffer.length; i += 4) {
            c.setRGB(buffer[i], buffer[i + 1], buffer[i + 2], SRGBColorSpace);
            buffer[i] = c.r;
            buffer[i + 1] = c.g;
            buffer[i + 2] = c.b;
        }
        info.buffer = buffer;
        return info;
    }

    // The material indices of FBXTree.Objects.Geometry.LayerElementMaterial.
    parseMaterialIndices(MaterialNode: FBXNode): FBXLayerInfo {
        const info = new FBXLayerInfo();
        info.dataSize = 1;
        const mappingType = MaterialNode.string("MappingInformationType", "");
        info.referenceType = MaterialNode.string("ReferenceInformationType", "");
        if (mappingType == "NoMappingInformation") {
            info.buffer = [0];
            info.indices = [0];
            info.mappingType = "AllSame";
            return info;
        }
        const materials = MaterialNode.array("Materials");
        const materialIndexBuffer = materials != null ? materials! : new Array<f64>(0);
        // Materials are stored as indices: an intermediate buffer pointing
        // into it keeps getData's shape.
        const materialIndices: Array<f64> = [];
        for (let i = 0; i < materialIndexBuffer.length; ++i) materialIndices.push(<f64>i);
        info.buffer = materialIndexBuffer;
        info.indices = materialIndices;
        info.mappingType = mappingType;
        return info;
    }

    // Generates a line geometry from a NurbsCurve node.
    parseNurbsGeometry(geoNode: FBXNode): BufferGeometry {
        const order = geoNode.number("Order", NaN);
        if (isNaN(order)) {
            this.state.warn("Invalid Order given for geometry ID: " + geoNode.id.toString());
            return new BufferGeometry();
        }
        const degree = <i32>order - 1;
        const knotVector = geoNode.array("KnotVector");
        const knots = knotVector != null ? knotVector! : new Array<f64>(0);
        const controlPoints: Array<Vector4> = [];
        const points = geoNode.array("Points");
        const pointsValues = points != null ? points! : new Array<f64>(0);
        for (let i = 0; i + 3 < pointsValues.length; i += 4) {
            controlPoints.push(new Vector4(pointsValues[i], pointsValues[i + 1], pointsValues[i + 2], pointsValues[i + 3]));
        }
        if (controlPoints.length == 0 || knots.length == 0 || degree < 1) return new BufferGeometry();
        let startKnot = 0, endKnot = -1;
        const form = geoNode.string("Form", "");
        if (form == "Closed") {
            controlPoints.push(controlPoints[0]);
        } else if (form == "Periodic") {
            startKnot = degree;
            endKnot = knots.length - 1 - startKnot;
            for (let i = 0; i < degree; ++i) controlPoints.push(controlPoints[i]);
        }
        const curve = new NURBSCurve(degree, knots, controlPoints, startKnot, endKnot);
        const curvePoints = curve.getPoints(controlPoints.length * 12);
        // BufferGeometry.setFromPoints
        const position: Array<f64> = [];
        for (let i = 0; i < curvePoints.length; i++) {
            position.push(curvePoints[i].x);
            position.push(curvePoints[i].y);
            position.push(curvePoints[i].z);
        }
        const geometry = new BufferGeometry();
        geometry.setAttribute("position", new Float32BufferAttribute(position, 3));
        return geometry;
    }
}

function newArrays(n: i32): Array<Array<f64>> {
    const arrays: Array<Array<f64>> = [];
    for (let i = 0; i < n; i++) arrays.push([]);
    return arrays;
}

/// `array[index]`, NaN out of range (JavaScript's undefined).
function at(array: Array<f64>, index: i32): f64 {
    return index >= 0 && index < array.length ? unchecked(array[index]) : NaN;
}

// ================================================================ animation

/// times.indexOf(time), searching on from the last hit `from` (key times
/// ascend, so each lookup continues where the previous one stopped; the
/// whole array is searched when they do not).
function indexOfTime(times: Array<f64>, time: f64, from: i32): i32 {
    const start = from > 0 ? from : 0;
    for (let i = start; i < times.length; i++) {
        const t = unchecked(times[i]);
        if (t == time) {
            // the first equal key, as indexOf
            let first = i;
            while (first > 0 && unchecked(times[first - 1]) == time) first--;
            return first;
        }
        if (t > time) break;
    }
    // unsorted times (not valid FBX): search them all, as indexOf
    return start > 0 && unchecked(times[start - 1]) > time ? times.indexOf(time) : -1;
}

class FBXAnimationCurve {
    id: i64 = 0;
    times: Array<f64> = [];
    values: Array<f64> = [];
}

class FBXCurveNode {
    id: i64 = 0;
    attr: string = "";
    x: FBXAnimationCurve? = null;
    y: FBXAnimationCurve? = null;
    z: FBXAnimationCurve? = null;
    morph: FBXAnimationCurve? = null;

    hasCurves(): bool {
        return this.x != null || this.y != null || this.z != null || this.morph != null;
    }
}

/// One animated model's (or morph channel's) curve nodes in a layer.
class FBXRawTracks {
    modelName: string = "";
    ID: i64 = 0;
    transform: Matrix4? = null;
    eulerOrder: string = "";
    preRotation: Array<f64>? = null;
    postRotation: Array<f64>? = null;
    morphName: string = "";
    T: FBXCurveNode? = null;
    R: FBXCurveNode? = null;
    S: FBXCurveNode? = null;
    DeformPercent: FBXCurveNode? = null;
}

class FBXRawClip {
    name: string = "";
    layer: Array<FBXRawTracks> = [];
}

// Parses the animation data of the FBXTree.
class AnimationParser {
    state: FBXState;

    constructor(state: FBXState) {
        this.state = state;
    }

    // The raw clips as three.js AnimationClips.
    parse(): Array<AnimationClip> {
        const animationClips: Array<AnimationClip> = [];
        const rawClips = this.parseClips();
        for (let i = 0; i < rawClips.length; i++) animationClips.push(this.addClip(rawClips[i]));
        return animationClips;
    }

    parseClips(): Array<FBXRawClip> {
        // the transformation data is in FBXTree.Objects.AnimationCurve: no
        // curves, no animations
        if (this.state.fbxTree.objects("AnimationCurve").ids.length == 0) return [];
        const curveNodesMap = this.parseAnimationCurveNodes();
        this.parseAnimationCurves(curveNodesMap);
        const layersMap = this.parseAnimationLayers(curveNodesMap);
        return this.parseAnimStacks(layersMap);
    }

    // Parses the nodes in FBXTree.Objects.AnimationCurveNode. Each holds the
    // animation of one transform of a model (e.g. left arm rotation) and is
    // referenced by an AnimationLayer.
    parseAnimationCurveNodes(): Map<i64, FBXCurveNode> {
        const rawCurveNodes = this.state.fbxTree.objects("AnimationCurveNode");
        const curveNodesMap = new Map<i64, FBXCurveNode>();
        for (let n = 0; n < rawCurveNodes.ids.length; n++) {
            const rawCurveNode = rawCurveNodes.get(rawCurveNodes.ids[n]);
            const name = rawCurveNode.attrName;
            // attrName.match(/S|R|T|DeformPercent/)
            if (name.indexOf("S") >= 0 || name.indexOf("R") >= 0 || name.indexOf("T") >= 0 || name.indexOf("DeformPercent") >= 0) {
                const curveNode = new FBXCurveNode();
                curveNode.id = rawCurveNode.id;
                curveNode.attr = name;
                curveNodesMap.set(curveNode.id, curveNode);
            }
        }
        return curveNodesMap;
    }

    // Parses the nodes in FBXTree.Objects.AnimationCurve and connects them
    // to their AnimationCurveNodes. Each AnimationCurve holds the times and
    // values of one axis (e.g. x rotation).
    parseAnimationCurves(curveNodesMap: Map<i64, FBXCurveNode>): void {
        const rawCurves = this.state.fbxTree.objects("AnimationCurve");
        for (let n = 0; n < rawCurves.ids.length; n++) {
            const rawCurve = rawCurves.get(rawCurves.ids[n]);
            const animationCurve = new FBXAnimationCurve();
            animationCurve.id = rawCurve.id;
            const keyTime = rawCurve.array("KeyTime");
            if (keyTime != null) {
                for (let i = 0; i < keyTime.length; i++) animationCurve.times.push(convertFBXTimeToSeconds(keyTime[i]));
            }
            const keyValues = rawCurve.array("KeyValueFloat");
            if (keyValues != null) animationCurve.values = keyValues;
            if (!this.state.connections.has(animationCurve.id)) continue;
            const relationships = this.state.connections.get(animationCurve.id);
            if (relationships.parents.length == 0) continue;
            const animationCurveID = relationships.parents[0].ID;
            const animationCurveRelationship = relationships.parents[0].relationship;
            if (!curveNodesMap.has(animationCurveID)) continue;
            const curveNode = curveNodesMap.get(animationCurveID);
            if (animationCurveRelationship.indexOf("X") >= 0) curveNode.x = animationCurve;
            else if (animationCurveRelationship.indexOf("Y") >= 0) curveNode.y = animationCurve;
            else if (animationCurveRelationship.indexOf("Z") >= 0) curveNode.z = animationCurve;
            else if (animationCurveRelationship.indexOf("DeformPercent") >= 0) curveNode.morph = animationCurve;
        }
    }

    // Parses the nodes in FBXTree.Objects.AnimationLayer. Each layer holds
    // AnimationCurveNodes and is referenced by an AnimationStack (in
    // practice one layer a stack).
    parseAnimationLayers(curveNodesMap: Map<i64, FBXCurveNode>): Map<i64, Array<FBXRawTracks>> {
        const state = this.state;
        const rawLayers = state.fbxTree.objects("AnimationLayer");
        const models = state.fbxTree.objects("Model");
        const deformerNodes = state.fbxTree.objects("Deformer");
        const layersMap = new Map<i64, Array<FBXRawTracks>>();
        for (let n = 0; n < rawLayers.ids.length; n++) {
            const nodeID = rawLayers.ids[n];
            if (!state.connections.has(nodeID)) continue;
            const layerCurveNodes: Array<FBXRawTracks> = [];
            // all the animationCurveNodes used in the layer
            const children = state.connections.get(nodeID).children;
            for (let i = 0; i < children.length; i++) {
                const child = children[i];
                if (!curveNodesMap.has(child.ID)) continue;
                const curveNode = curveNodesMap.get(child.ID);
                // the parent with a property: the animated model or channel
                const parent = this.propertyParent(child.ID);
                if (curveNode.x != null || curveNode.y != null || curveNode.z != null) {
                    if (parent == null) continue;
                    const modelID = parent.ID;
                    if (!models.has(modelID)) {
                        state.warn("Encountered a unused curve.");
                        continue;
                    }
                    const rawModel = models.get(modelID);
                    const node = new FBXRawTracks();
                    node.modelName = rawModel.attrName.length > 0 ? PropertyBinding.sanitizeNodeName(rawModel.attrName) : "";
                    node.ID = rawModel.id;
                    const child3D = this.findModel(rawModel.id);
                    if (child3D != null) {
                        node.transform = child3D.matrix;
                        if (state.transformData.has(child3D.id)) node.eulerOrder = state.transformData.get(child3D.id).eulerOrder;
                    }
                    if (node.transform == null) node.transform = new Matrix4();
                    // pre rotations of the model apply to every animation value as well
                    node.preRotation = vectorProperty(rawModel, "PreRotation");
                    node.postRotation = vectorProperty(rawModel, "PostRotation");
                    this.setCurveNode(node, curveNode);
                    layerCurveNodes.push(node);
                } else if (curveNode.morph != null) {
                    if (parent == null) continue;
                    const deformerID = parent.ID;
                    const morpher = state.relationships(deformerID).parents;
                    if (morpher.length == 0) continue;
                    const geometry = state.relationships(morpher[0].ID).parents;
                    if (geometry.length == 0) continue;
                    // assuming geometry is not used in more than one model
                    const model = state.relationships(geometry[0].ID).parents;
                    if (model.length == 0 || !models.has(model[0].ID) || !deformerNodes.has(deformerID)) continue;
                    const rawModel = models.get(model[0].ID);
                    const node = new FBXRawTracks();
                    node.modelName = rawModel.attrName.length > 0 ? PropertyBinding.sanitizeNodeName(rawModel.attrName) : "";
                    node.morphName = deformerNodes.get(deformerID).attrName;
                    this.setCurveNode(node, curveNode);
                    layerCurveNodes.push(node);
                }
            }
            layersMap.set(nodeID, layerCurveNodes);
        }
        return layersMap;
    }

    private propertyParent(id: i64): FBXRelationship? {
        const parents = this.state.relationships(id).parents;
        for (let i = 0; i < parents.length; i++) {
            if (parents[i].relationship.length > 0) return parents[i];
        }
        return null;
    }

    // layerCurveNodes[i][curveNode.attr] = curveNode
    private setCurveNode(node: FBXRawTracks, curveNode: FBXCurveNode): void {
        const attr = curveNode.attr;
        if (attr == "T") node.T = curveNode;
        else if (attr == "R") node.R = curveNode;
        else if (attr == "S") node.S = curveNode;
        else if (attr == "DeformPercent") node.DeformPercent = curveNode;
    }

    // The scene graph's (last) object of FBX ID `id` (three.js's traverse).
    private findModel(id: i64): Object3D? {
        let found: Object3D? = null;
        const stack: Array<Object3D> = [this.state.sceneGraph];
        while (stack.length > 0) {
            const object = stack.pop();
            if (this.state.modelIDs.has(object.id) && this.state.modelIDs.get(object.id) == id) found = object;
            for (let i = object.children.length - 1; i >= 0; i--) stack.push(object.children[i]);
        }
        return found;
    }

    // Parses the nodes in FBXTree.Objects.AnimationStack, the top of the
    // animation hierarchy: each becomes an AnimationClip.
    parseAnimStacks(layersMap: Map<i64, Array<FBXRawTracks>>): Array<FBXRawClip> {
        const rawStacks = this.state.fbxTree.objects("AnimationStack");
        const rawClips: Array<FBXRawClip> = [];
        for (let n = 0; n < rawStacks.ids.length; n++) {
            const nodeID = rawStacks.ids[n];
            const children = this.state.relationships(nodeID).children;
            if (children.length > 1) {
                this.state.warn("Encountered an animation stack with multiple layers, this is currently not supported. Ignoring subsequent layers.");
            }
            if (children.length == 0 || !layersMap.has(children[0].ID)) continue;
            const clip = new FBXRawClip();
            clip.name = rawStacks.get(nodeID).attrName;
            clip.layer = layersMap.get(children[0].ID);
            rawClips.push(clip);
        }
        return rawClips;
    }

    addClip(rawClip: FBXRawClip): AnimationClip {
        const tracks: Array<KeyframeTrack> = [];
        for (let i = 0; i < rawClip.layer.length; i++) this.generateTracks(rawClip.layer[i], tracks);
        return new AnimationClip(rawClip.name, -1, tracks);
    }

    generateTracks(rawTracks: FBXRawTracks, tracks: Array<KeyframeTrack>): void {
        const position = new Vector3();
        const scale = new Vector3();
        const transform = rawTracks.transform;
        if (transform != null) transform.decompose(position, new Quaternion(), scale);
        const initialPosition: Array<f64> = [position.x, position.y, position.z];
        const initialScale: Array<f64> = [scale.x, scale.y, scale.z];
        const T = rawTracks.T, R = rawTracks.R, S = rawTracks.S;
        if (T != null && T.hasCurves()) {
            tracks.push(this.generateVectorTrack(rawTracks.modelName, T, initialPosition, "position"));
        }
        if (R != null && R.hasCurves()) {
            const rotationTrack = this.generateRotationTrack(rawTracks.modelName, R, rawTracks.preRotation,
                rawTracks.postRotation, rawTracks.eulerOrder);
            if (rotationTrack != null) tracks.push(rotationTrack!);
        }
        if (S != null && S.hasCurves()) {
            tracks.push(this.generateVectorTrack(rawTracks.modelName, S, initialScale, "scale"));
        }
        if (rawTracks.DeformPercent != null) {
            const morphTrack = this.generateMorphTrack(rawTracks);
            if (morphTrack != null) tracks.push(morphTrack!);
        }
    }

    generateVectorTrack(modelName: string, curves: FBXCurveNode, initialValue: Array<f64>, type: string): KeyframeTrack {
        const times = this.getTimesForAllAxes(curves);
        const values = this.getKeyframeTrackValues(times, curves, initialValue);
        return new VectorKeyframeTrack(modelName + "." + type, times, values);
    }

    // null where three.js returns a track with one value for a whole
    // quaternion (missing axes), which cannot play.
    generateRotationTrack(modelName: string, curves: FBXCurveNode, preRotationValues: Array<f64>?,
                          postRotationValues: Array<f64>?, eulerOrder: string): KeyframeTrack? {
        const times: Array<f64> = [];
        const values: Array<f64> = [];
        const x = curves.x, y = curves.y, z = curves.z;
        if (x == null || y == null || z == null) {
            this.state.warn("rotation of '" + modelName + "' animated on some axes only: skipped");
            return null;
        }
        this.interpolateRotations(x!, y!, z!, eulerOrder, times, values);
        // For Maya models using "Joint Orient", Euler order only applies to rotation, not pre/post-rotations
        const defaultEulerOrder = getEulerOrder(0);
        let preRotation: Quaternion? = null;
        if (preRotationValues != null) {
            const e = new Euler(MathUtils.degToRad(preRotationValues[0]), MathUtils.degToRad(preRotationValues[1]),
                MathUtils.degToRad(preRotationValues[2]), defaultEulerOrder);
            preRotation = new Quaternion().setFromEuler(e);
        }
        let postRotation: Quaternion? = null;
        if (postRotationValues != null) {
            const e = new Euler(MathUtils.degToRad(postRotationValues[0]), MathUtils.degToRad(postRotationValues[1]),
                MathUtils.degToRad(postRotationValues[2]), defaultEulerOrder);
            postRotation = new Quaternion().setFromEuler(e).invert();
        }
        const quaternion = new Quaternion();
        const euler = new Euler();
        const quaternionValues: Array<f64> = [];
        const prevQuat = new Quaternion();
        for (let i = 0; i + 2 < values.length; i += 3) {
            euler.set(values[i], values[i + 1], values[i + 2], eulerOrder);
            quaternion.setFromEuler(euler);
            if (preRotation != null) quaternion.premultiply(preRotation!);
            if (postRotation != null) quaternion.multiply(postRotation!);
            // Check unroll
            if (i > 2) {
                prevQuat.fromArray(quaternionValues, ((i - 3) / 3) * 4);
                if (prevQuat.dot(quaternion) < 0) quaternion.set(-quaternion.x, -quaternion.y, -quaternion.z, -quaternion.w);
            }
            quaternionValues.push(quaternion.x);
            quaternionValues.push(quaternion.y);
            quaternionValues.push(quaternion.z);
            quaternionValues.push(quaternion.w);
        }
        return new QuaternionKeyframeTrack(modelName + ".quaternion", times, quaternionValues);
    }

    generateMorphTrack(rawTracks: FBXRawTracks): KeyframeTrack? {
        const curves = rawTracks.DeformPercent!.morph;
        if (curves == null) return null;
        const values: Array<f64> = [];
        for (let i = 0; i < curves.values.length; i++) values.push(curves.values[i] / 100);
        const object = this.state.sceneGraph.getObjectByName(rawTracks.modelName);
        if (object == null || !(object instanceof Mesh)) return null;
        const dictionary = (object as Mesh).morphTargetDictionary;
        if (!dictionary.has(rawTracks.morphName)) {
            this.state.warn("no morph target '" + rawTracks.morphName + "' on '" + rawTracks.modelName + "'");
            return null;
        }
        const morphNum = dictionary.get(rawTracks.morphName);
        return new NumberKeyframeTrack(rawTracks.modelName + ".morphTargetInfluences[" + morphNum.toString() + "]", curves.times, values);
    }

    // Each axis has its own times: here they are joined, sorted and without
    // duplicates.
    getTimesForAllAxes(curves: FBXCurveNode): Array<f64> {
        let times: Array<f64> = [];
        const x = curves.x, y = curves.y, z = curves.z;
        if (x != null) times = times.concat(x.times);
        if (y != null) times = times.concat(y.times);
        if (z != null) times = times.concat(z.times);
        times.sort((a: f64, b: f64): i32 => (a < b ? -1 : a > b ? 1 : 0));
        if (times.length > 1) {
            let targetIndex = 1;
            let lastValue = times[0];
            for (let i = 1; i < times.length; i++) {
                const currentValue = times[i];
                if (currentValue != lastValue) {
                    times[targetIndex] = currentValue;
                    lastValue = currentValue;
                    targetIndex++;
                }
            }
            times = times.slice(0, targetIndex);
        }
        return times;
    }

    getKeyframeTrackValues(times: Array<f64>, curves: FBXCurveNode, initialValue: Array<f64>): Array<f64> {
        const prevValue = initialValue;
        const values: Array<f64> = [];
        let xIndex = -1;
        let yIndex = -1;
        let zIndex = -1;
        const x = curves.x, y = curves.y, z = curves.z;
        for (let t = 0; t < times.length; t++) {
            const time = times[t];
            if (x != null) xIndex = indexOfTime(x.times, time, xIndex);
            if (y != null) yIndex = indexOfTime(y.times, time, yIndex);
            if (z != null) zIndex = indexOfTime(z.times, time, zIndex);
            // the x value of this frame when defined, else the previous one
            if (xIndex != -1) {
                const xValue = at(x!.values, xIndex);
                values.push(xValue);
                prevValue[0] = xValue;
            } else values.push(prevValue[0]);
            if (yIndex != -1) {
                const yValue = at(y!.values, yIndex);
                values.push(yValue);
                prevValue[1] = yValue;
            } else values.push(prevValue[1]);
            if (zIndex != -1) {
                const zValue = at(z!.values, zIndex);
                values.push(zValue);
                prevValue[2] = zValue;
            } else values.push(prevValue[2]);
        }
        return values;
    }

    // Rotations are Euler angles of any size; quaternions do not hold more
    // than PI, so large rotations are interpolated. Fills `times` and
    // `values` (three.js returns them).
    interpolateRotations(curvex: FBXAnimationCurve, curvey: FBXAnimationCurve, curvez: FBXAnimationCurve,
                         eulerOrder: string, times: Array<f64>, values: Array<f64>): void {
        if (curvex.times.length == 0) return;
        const order = eulerOrder.length > 0 ? eulerOrder : "XYZ";
        // Add first frame
        times.push(curvex.times[0]);
        values.push(MathUtils.degToRad(at(curvex.values, 0)));
        values.push(MathUtils.degToRad(at(curvey.values, 0)));
        values.push(MathUtils.degToRad(at(curvez.values, 0)));
        for (let i = 1; i < curvex.values.length; i++) {
            const initialValue: Array<f64> = [at(curvex.values, i - 1), at(curvey.values, i - 1), at(curvez.values, i - 1)];
            if (isNaN(initialValue[0]) || isNaN(initialValue[1]) || isNaN(initialValue[2])) continue;
            const currentValue: Array<f64> = [at(curvex.values, i), at(curvey.values, i), at(curvez.values, i)];
            if (isNaN(currentValue[0]) || isNaN(currentValue[1]) || isNaN(currentValue[2])) continue;
            const absoluteSpan: Array<f64> = [
                Math.abs(currentValue[0] - initialValue[0]),
                Math.abs(currentValue[1] - initialValue[1]),
                Math.abs(currentValue[2] - initialValue[2]),
            ];
            if (absoluteSpan[0] >= 180 || absoluteSpan[1] >= 180 || absoluteSpan[2] >= 180) {
                const maxAbsSpan = Math.max(absoluteSpan[0], Math.max(absoluteSpan[1], absoluteSpan[2]));
                const numSubIntervals = maxAbsSpan / 180;
                const E1 = new Euler(MathUtils.degToRad(initialValue[0]), MathUtils.degToRad(initialValue[1]),
                    MathUtils.degToRad(initialValue[2]), order);
                const E2 = new Euler(MathUtils.degToRad(currentValue[0]), MathUtils.degToRad(currentValue[1]),
                    MathUtils.degToRad(currentValue[2]), order);
                const Q1 = new Quaternion().setFromEuler(E1);
                const Q2 = new Quaternion().setFromEuler(E2);
                // Check unroll (as three.js: on any non-zero dot)
                if (Q1.dot(Q2) != 0) Q2.set(-Q2.x, -Q2.y, -Q2.z, -Q2.w);
                // Interpolate
                const initialTime = at(curvex.times, i - 1);
                const timeSpan = at(curvex.times, i) - initialTime;
                const Q = new Quaternion();
                const E = new Euler();
                for (let t: f64 = 0; t < 1; t += 1 / numSubIntervals) {
                    Q.copy(Q1.clone().slerp(Q2.clone(), t));
                    times.push(initialTime + t * timeSpan);
                    E.setFromQuaternion(Q, order);
                    values.push(E.x);
                    values.push(E.y);
                    values.push(E.z);
                }
            } else {
                times.push(at(curvex.times, i));
                values.push(MathUtils.degToRad(at(curvex.values, i)));
                values.push(MathUtils.degToRad(at(curvey.values, i)));
                values.push(MathUtils.degToRad(at(curvez.values, i)));
            }
        }
    }
}

// =================================================================== parsers

/// Parses an FBX file in ASCII format.
export class TextParser {
    currentIndent: i32 = 0;
    allNodes: FBXTree = new FBXTree();
    nodeStack: Array<FBXNode> = [];
    currentProp: FBXNode? = null;
    currentPropName: string = "";

    getPrevNode(): FBXNode? {
        const i = this.currentIndent - 2;
        return i >= 0 && i < this.nodeStack.length ? this.nodeStack[i] : null;
    }

    getCurrentNode(): FBXNode? {
        const i = this.currentIndent - 1;
        return i >= 0 && i < this.nodeStack.length ? this.nodeStack[i] : null;
    }

    getCurrentProp(): FBXNode? {
        return this.currentProp;
    }

    pushStack(node: FBXNode): void {
        this.nodeStack.push(node);
        this.currentIndent += 1;
    }

    popStack(): void {
        if (this.nodeStack.length > 0) this.nodeStack.pop();
        this.currentIndent -= 1;
    }

    setCurrentProp(val: FBXNode, name: string): void {
        this.currentProp = val;
        this.currentPropName = name;
    }

    parse(text: string): FBXTree {
        this.currentIndent = 0;
        this.allNodes = new FBXTree();
        this.nodeStack = [];
        this.currentProp = null;
        this.currentPropName = "";
        const split = splitLines(text);
        for (let i = 0; i < split.length; i++) {
            const line = split[i];
            // comments and empty lines
            const first = firstNonBlank(line);
            if (first < 0 || line.charCodeAt(first) == 59 /* ; */) continue;
            const tabs = leadingTabs(line);
            const indent = this.currentIndent;
            // ^\t{indent}(\w+):(.*){
            if (tabs == indent) {
                const nameEnd = wordEnd(line, tabs);
                if (nameEnd > tabs && nameEnd < line.length && line.charCodeAt(nameEnd) == 58 /* : */) {
                    const name = line.substring(tabs, nameEnd);
                    const brace = line.lastIndexOf("{");
                    if (brace > nameEnd) {
                        this.parseNodeBegin(line, name, line.substring(nameEnd + 1, brace));
                        continue;
                    }
                    // ^\t{indent}(\w+):[\s\t\r\n](.*)
                    if (nameEnd + 1 < line.length && isBlank(line.charCodeAt(nameEnd + 1))) {
                        const contentLine = i + 1 < split.length ? split[i + 1] : "";
                        this.parseNodeProperty(line, name, line.substring(nameEnd + 2), contentLine);
                        continue;
                    }
                }
            }
            // ^\t{indent - 1}}
            if (indent > 0 && tabs == indent - 1 && tabs < line.length && line.charCodeAt(tabs) == 125 /* } */) {
                this.popStack();
                continue;
            }
            // ^[^\s\t}]: a large array continued on the next line ("," at the end)
            const c = line.charCodeAt(0);
            if (!isBlank(c) && c != 125) this.parseNodePropertyContinued(line);
        }
        return this.allNodes;
    }

    parseNodeBegin(line: string, name: string, attrsText: string): void {
        const nodeName = stripQuotes(name.trim());
        const parts = attrsText.split(",");
        const nodeAttrs: Array<string> = [];
        for (let i = 0; i < parts.length; i++) nodeAttrs.push(stripQuotes(parts[i].trim()));
        const node = new FBXNode();
        node.name = nodeName;
        this.parseNodeAttr(nodeAttrs, node);
        const currentNode = this.getCurrentNode();
        if (this.currentIndent == 0 || currentNode == null) {
            // a top node
            this.allNodes.add(nodeName, node);
        } else if (nodeName != "Properties70") {
            // a sub node (Properties70's properties go to its parent)
            currentNode.children.push(node);
        }
        this.pushStack(node);
    }

    /// Sets the node's id (when numeric), attrName and attrType from its
    /// attributes (three.js returns them).
    parseNodeAttr(attrs: Array<string>, node: FBXNode): void {
        if (attrs.length > 0 && attrs[0].length > 0) {
            const id = parseLeadingInt(attrs[0]);
            if (id.ok) {
                node.id = id.value;
                node.hasId = true;
            }
        }
        if (attrs.length > 1) {
            node.attrName = stripClassPrefix(attrs[1]);
            node.attrType = attrs.length > 2 ? attrs[2] : "";
        }
    }

    parseNodeProperty(line: string, name: string, value: string, contentLine: string): void {
        let propName = stripQuotes(name).trim();
        let propValue = stripQuotes(value).trim();
        // base64 image data follows a "Content: ," line
        if (propName == "Content" && propValue == ",") {
            propValue = contentLine.replaceAll("\"", "");
            if (propValue.endsWith(",")) propValue = propValue.substring(0, propValue.length - 1);
            propValue = propValue.trim();
        }
        const currentNode = this.getCurrentNode();
        if (currentNode == null) return;
        if (currentNode.name == "Properties70") {
            this.parseNodeSpecialProperty(line, propName, propValue);
            return;
        }
        // Connections
        if (propName == "C") {
            const parts = propValue.split(",");
            if (parts.length >= 3) {
                const relationship = parts.length > 3 ? stripLeadingQuote(parts[3].trim()) : "";
                currentNode.connections.push(new FBXConnection(parseLeadingInt(parts[1]).value, parseLeadingInt(parts[2]).value, relationship));
            }
            this.setCurrentProp(currentNode, "connections");
            return;
        }
        if (propName == "a") {
            // a string until it no longer ends with ",", then an array
            if (propValue.endsWith(",")) currentNode.aText = propValue;
            else currentNode.a = parseNumberArray(propValue);
        } else {
            const property = new FBXNode();
            property.name = propName;
            property.singleProperty = true;
            property.propertyList.push(FBXValue.ofString(propValue));
            currentNode.children.push(property);
        }
        this.setCurrentProp(currentNode, propName);
    }

    parseNodePropertyContinued(line: string): void {
        const currentNode = this.getCurrentNode();
        if (currentNode == null) return;
        currentNode.aText += line;
        // the value ends on the first line not ending in ","
        if (!line.endsWith(",")) {
            currentNode.a = parseNumberArray(currentNode.aText);
            currentNode.aText = "";
        }
    }

    // Parses a "Properties70" line:
    //     P: "Lcl Scaling", "Lcl Scaling", "", "A",1,1,1
    // into ["Lcl_Scaling", "Lcl_Scaling", "", "A", "1,1,1"], stored on the
    // node holding the Properties70.
    parseNodeSpecialProperty(line: string, propName: string, propValue: string): void {
        const parts = propValue.split("\",");
        const props: Array<string> = [];
        for (let i = 0; i < parts.length; i++) props.push(replaceFirstBlank(stripLeadingQuote(parts[i].trim())));
        const innerPropName = props.length > 0 ? props[0] : "";
        const innerPropType1 = props.length > 1 ? props[1] : "";
        const innerPropType2 = props.length > 2 ? props[2] : "";
        const innerPropFlag = props.length > 3 ? props[3] : "";
        let innerPropValue = new FBXValue();
        if (props.length > 4) {
            const text = props[4];
            // cast values where needed, otherwise leave as strings
            const t = innerPropType1;
            if (t == "int" || t == "enum" || t == "bool" || t == "ULongLong" || t == "double" || t == "Number" || t == "FieldOfView") {
                innerPropValue = FBXValue.ofNumber(parseFloat(text));
            } else if (t == "Color" || t == "ColorRGB" || t == "Vector3D" || t == "Vector" || t == "Lcl_Translation" ||
                t == "Lcl_Rotation" || t == "Lcl_Scaling") {
                innerPropValue = FBXValue.ofArray(parseNumberArray(text));
            } else {
                innerPropValue = FBXValue.ofString(text);
            }
        }
        // CAUTION: these props must append to parent's parent
        const prev = this.getPrevNode();
        if (prev == null) return;
        prev.properties.set(innerPropName, new FBXProperty(innerPropType1, innerPropType2, innerPropFlag, innerPropValue));
        this.setCurrentProp(prev, innerPropName);
    }
}

/// Parses an FBX file in binary format.
export class BinaryParser {
    error: string = "";
    /// Compressed arrays inflated ahead (by inflateFBX), used in file order
    /// instead of inflating them here.
    inflated: FBXInflated? = null;
    /// When set, every compressed array is also appended to it, in file order.
    collected: Array<Array<f64>>? = null;
    private inflatedIndex: i32 = 0;

    parse(buffer: ArrayBuffer): FBXTree? {
        const reader = new BinaryReader(buffer);
        reader.skip(23);   // skip magic 23 bytes
        const version = reader.getUint32();
        if (version < 6400) {
            this.error = "FBX version not supported, FileVersion: " + version.toString();
            return null;
        }
        const allNodes = new FBXTree();
        while (!this.endOfContent(reader)) {
            const node = this.parseNode(reader, version);
            if (this.error.length > 0) return null;
            if (reader.overflow) {
                this.error = "unexpected end of file at offset " + reader.getOffset().toString();
                return null;
            }
            if (node != null) allNodes.add(node.name, node!);
        }
        return allNodes;
    }

    // Whether the reader has reached the footer: 160 bytes and 16-byte
    // alignment padding (a 16-byte magic, padding, 4 bytes of magic, the
    // version, 120 zero bytes and a 16-byte magic).
    endOfContent(reader: BinaryReader): bool {
        if (reader.size() % 16 == 0) return ((reader.getOffset() + 160 + 16) & ~0xf) >= reader.size();
        return reader.getOffset() + 160 + 16 >= reader.size();
    }

    // Parses a node and its sub nodes, recursively.
    parseNode(reader: BinaryReader, version: u32): FBXNode? {
        const node = new FBXNode();
        // The first three sizes depend on the version.
        const endOffset: u64 = version >= 7500 ? reader.getUint64() : <u64>reader.getUint32();
        const numProperties: u64 = version >= 7500 ? reader.getUint64() : <u64>reader.getUint32();
        if (version >= 7500) reader.getUint64();
        else reader.getUint32();   // the property list's length, unused
        const nameLen = <i32>reader.getUint8();
        const name = reader.getString(nameLen);
        // A NULL record ends a list of nodes.
        if (endOffset == 0) return null;
        if (endOffset > <u64>reader.size() || numProperties > <u64>reader.size()) {
            this.error = "corrupt node record '" + name + "'";
            return null;
        }
        const propertyList: Array<FBXValue> = [];
        for (let i: u64 = 0; i < numProperties; i++) {
            propertyList.push(this.parseProperty(reader));
            if (this.error.length > 0 || reader.overflow) return null;
        }
        // The first three properties are the id, attrName and attrType.
        if (propertyList.length > 0 && propertyList[0].kind == FBX_NUMBER) {
            node.id = propertyList[0].asLong();
            node.hasId = true;
        }
        if (propertyList.length > 1 && propertyList[1].kind == FBX_STRING) node.attrName = propertyList[1].str;
        if (propertyList.length > 2 && propertyList[2].kind == FBX_STRING) node.attrType = propertyList[2].str;
        // a node holding a single property: (name, 0) or (name2, [0, 1, 2])
        node.singleProperty = numProperties == 1 && <u64>reader.getOffset() == endOffset;
        while (endOffset > <u64>reader.getOffset()) {
            const subNode = this.parseNode(reader, version);
            if (this.error.length > 0 || reader.overflow) return null;
            if (subNode != null) this.parseSubNode(name, node, subNode!);
        }
        node.propertyList = propertyList;
        node.name = name;
        return node;
    }

    parseSubNode(name: string, node: FBXNode, subNode: FBXNode): void {
        if (subNode.singleProperty) {
            // a single property: node.Name is its value, or a node with `a`
            const value = subNode.propertyList[0];
            if (value.kind == FBX_ARRAY) subNode.a = value.arr;
            node.children.push(subNode);
        } else if (name == "Connections" && subNode.name == "C") {
            // the first property is the connection type (OO, OP ...)
            const p = subNode.propertyList;
            if (p.length >= 3) {
                const relationship = p.length > 3 ? p[3].asString() : "";
                node.connections.push(new FBXConnection(p[1].asLong(), p[2].asLong(), relationship));
            }
        } else if (subNode.name == "Properties70") {
            const keys = subNode.properties.keys();
            for (let i = 0; i < keys.length; i++) node.properties.set(keys[i], subNode.properties.get(keys[i]));
        } else if (name == "Properties70" && subNode.name == "P") {
            const p = subNode.propertyList;
            let innerPropName = p.length > 0 ? p[0].asString() : "";
            let innerPropType1 = p.length > 1 ? p[1].asString() : "";
            const innerPropType2 = p.length > 2 ? p[2].asString() : "";
            const innerPropFlag = p.length > 3 ? p[3].asString() : "";
            if (innerPropName.startsWith("Lcl ")) innerPropName = "Lcl_" + innerPropName.substring(4);
            if (innerPropType1.startsWith("Lcl ")) innerPropType1 = "Lcl_" + innerPropType1.substring(4);
            let innerPropValue: FBXValue;
            if (innerPropType1 == "Color" || innerPropType1 == "ColorRGB" || innerPropType1 == "Vector" ||
                innerPropType1 == "Vector3D" || innerPropType1.startsWith("Lcl_")) {
                innerPropValue = FBXValue.ofArray([
                    p.length > 4 ? p[4].asNumber() : NaN,
                    p.length > 5 ? p[5].asNumber() : NaN,
                    p.length > 6 ? p[6].asNumber() : NaN,
                ]);
            } else {
                innerPropValue = p.length > 4 ? p[4] : new FBXValue();
            }
            // copied to the parent, see above
            node.properties.set(innerPropName, new FBXProperty(innerPropType1, innerPropType2, innerPropFlag, innerPropValue));
        } else {
            node.children.push(subNode);
        }
    }

    parseProperty(reader: BinaryReader): FBXValue {
        const type = reader.getUint8();
        if (type == 67 /* C */) return FBXValue.ofBool(reader.getBoolean());
        if (type == 68 /* D */) return FBXValue.ofNumber(reader.getFloat64());
        if (type == 70 /* F */) return FBXValue.ofNumber(reader.getFloat32());
        if (type == 73 /* I */) return FBXValue.ofNumber(<f64>reader.getInt32());
        if (type == 76 /* L */) return FBXValue.ofLong(reader.getInt64());
        if (type == 82 /* R */) {
            const length = <i32>reader.getUint32();
            return FBXValue.ofBytes(reader.getArrayBuffer(length));
        }
        if (type == 83 /* S */) {
            const length = <i32>reader.getUint32();
            return FBXValue.ofString(reader.getString(length));
        }
        if (type == 89 /* Y */) return FBXValue.ofNumber(<f64>reader.getInt16());
        if (type == 98 || type == 99 || type == 100 || type == 102 || type == 105 || type == 108) {   // b c d f i l
            const arrayLength = <i32>reader.getUint32();
            const encoding = reader.getUint32();   // 0: non-compressed, 1: compressed
            const compressedLength = <i32>reader.getUint32();
            if (encoding == 0) return FBXValue.ofArray(this.readArray(reader, type, arrayLength));
            const inflated = this.inflated;
            if (inflated != null) {
                reader.skip(compressedLength);
                const k = this.inflatedIndex++;
                if (k >= inflated.offsets.length || inflated.lengths[k] != arrayLength) {
                    this.error = "inflated arrays do not match the file";
                    return new FBXValue();
                }
                const array = new Array<f64>(arrayLength);
                const values = inflated.values;
                const offset = inflated.offsets[k];
                for (let j = 0; j < arrayLength; j++) array[j] = values[offset + j];
                return FBXValue.ofArray(array);
            }
            const compressed = Uint8Array.wrap(reader.getArrayBuffer(compressedLength));
            const elementSize = type == 100 || type == 108 ? 8 : type == 98 || type == 99 ? 1 : 4;
            const data = unzlibSync(compressed, arrayLength * elementSize);
            const reader2 = new BinaryReader(data.buffer, data.byteOffset, data.byteLength);
            const array = this.readArray(reader2, type, arrayLength);
            if (reader2.overflow) this.error = "corrupt compressed array";
            const collected = this.collected;
            if (collected != null) collected.push(array);
            return FBXValue.ofArray(array);
        }
        this.error = "Unknown property type " + String.fromCharCode(type);
        return new FBXValue();
    }

    private readArray(reader: BinaryReader, type: u32, arrayLength: i32): Array<f64> {
        if (type == 98 || type == 99) return reader.getBooleanArray(arrayLength);
        if (type == 100) return reader.getFloat64Array(arrayLength);
        if (type == 102) return reader.getFloat32Array(arrayLength);
        if (type == 105) return reader.getInt32Array(arrayLength);
        return reader.getInt64Array(arrayLength);
    }
}

/// Little-endian reads over a byte buffer. Reads past the end return 0 and
/// set `overflow` (three.js's DataView throws).
export class BinaryReader {
    dv: DataView;
    offset: i32 = 0;
    littleEndian: bool;
    overflow: bool = false;

    constructor(buffer: ArrayBuffer, byteOffset: i32 = 0, byteLength: i32 = -1, littleEndian: bool = true) {
        this.dv = new DataView(buffer, byteOffset, byteLength >= 0 ? byteLength : buffer.byteLength - byteOffset);
        this.littleEndian = littleEndian;
    }

    getOffset(): i32 { return this.offset; }

    size(): i32 { return this.dv.byteLength; }

    skip(length: i32): void { this.offset += length; }

    private take(bytes: i32): bool {
        if (bytes < 0 || this.offset + bytes > this.dv.byteLength || this.offset < 0) {
            this.overflow = true;
            this.offset = this.dv.byteLength;
            return false;
        }
        return true;
    }

    // true/false depend on the exporter: 1 or 'Y' (0x59), 0 or 'T' (0x54):
    // the low bit.
    getBoolean(): bool { return (this.getUint8() & 1) == 1; }

    getBooleanArray(size: i32): Array<f64> {
        const a = new Array<f64>(max(size, 0));
        if (!this.take(size)) return a;
        for (let i = 0; i < size; i++) a[i] = <f64>(this.dv.getUint8(this.offset + i) & 1);
        this.offset += size;
        return a;
    }

    getUint8(): u32 {
        if (!this.take(1)) return 0;
        const value = <u32>this.dv.getUint8(this.offset);
        this.offset += 1;
        return value;
    }

    getInt16(): i32 {
        if (!this.take(2)) return 0;
        const value = <i32>this.dv.getInt16(this.offset, this.littleEndian);
        this.offset += 2;
        return value;
    }

    getInt32(): i32 {
        if (!this.take(4)) return 0;
        const value = this.dv.getInt32(this.offset, this.littleEndian);
        this.offset += 4;
        return value;
    }

    getInt32Array(size: i32): Array<f64> {
        const a = new Array<f64>(max(size, 0));
        if (!this.take(size * 4)) return a;
        for (let i = 0; i < size; i++) a[i] = <f64>this.dv.getInt32(this.offset + i * 4, this.littleEndian);
        this.offset += size * 4;
        return a;
    }

    getUint32(): u32 {
        if (!this.take(4)) return 0;
        const value = this.dv.getUint32(this.offset, this.littleEndian);
        this.offset += 4;
        return value;
    }

    // Exact (three.js computes a JavaScript number).
    getInt64(): i64 {
        if (!this.take(8)) return 0;
        const value = this.dv.getInt64(this.offset, this.littleEndian);
        this.offset += 8;
        return value;
    }

    getInt64Array(size: i32): Array<f64> {
        const a = new Array<f64>(max(size, 0));
        if (!this.take(size * 8)) return a;
        for (let i = 0; i < size; i++) a[i] = <f64>this.dv.getInt64(this.offset + i * 8, this.littleEndian);
        this.offset += size * 8;
        return a;
    }

    getUint64(): u64 {
        if (!this.take(8)) return 0;
        const value = this.dv.getUint64(this.offset, this.littleEndian);
        this.offset += 8;
        return value;
    }

    getFloat32(): f64 {
        if (!this.take(4)) return 0;
        const value = <f64>this.dv.getFloat32(this.offset, this.littleEndian);
        this.offset += 4;
        return value;
    }

    getFloat32Array(size: i32): Array<f64> {
        const a = new Array<f64>(max(size, 0));
        if (!this.take(size * 4)) return a;
        for (let i = 0; i < size; i++) a[i] = <f64>this.dv.getFloat32(this.offset + i * 4, this.littleEndian);
        this.offset += size * 4;
        return a;
    }

    getFloat64(): f64 {
        if (!this.take(8)) return 0;
        const value = this.dv.getFloat64(this.offset, this.littleEndian);
        this.offset += 8;
        return value;
    }

    getFloat64Array(size: i32): Array<f64> {
        const a = new Array<f64>(max(size, 0));
        if (!this.take(size * 8)) return a;
        for (let i = 0; i < size; i++) a[i] = this.dv.getFloat64(this.offset + i * 8, this.littleEndian);
        this.offset += size * 8;
        return a;
    }

    getArrayBuffer(size: i32): ArrayBuffer {
        if (!this.take(size)) return new ArrayBuffer(0);
        const start = this.dv.byteOffset + this.offset;
        const value = this.dv.buffer.slice(start, start + size);
        this.offset += size;
        return value;
    }

    // UTF-8, up to the first NUL byte.
    getString(size: i32): string {
        if (!this.take(size)) return "";
        let length = 0;
        while (length < size && this.dv.getUint8(this.offset + length) != 0) length++;
        const start = this.dv.byteOffset + this.offset;
        this.offset += size;
        if (length == 0) return "";
        return String.UTF8.decode(this.dv.buffer.slice(start, start + length));
    }
}

// ====================================================================== tree

export const FBX_NONE: i32 = 0;
export const FBX_BOOL: i32 = 1;
export const FBX_NUMBER: i32 = 2;
export const FBX_STRING: i32 = 3;
export const FBX_ARRAY: i32 = 4;
export const FBX_BYTES: i32 = 5;

/// A property value of the FBX tree (three.js keeps JavaScript values):
/// a bool, a number (exact `long` for 64-bit integers), a string, a number
/// array or raw bytes.
export class FBXValue {
    kind: i32 = FBX_NONE;
    num: f64 = 0;
    long: i64 = 0;
    isLong: bool = false;
    str: string = "";
    arr: Array<f64> = [];
    bytes: ArrayBuffer? = null;

    static ofBool(value: bool): FBXValue {
        const v = new FBXValue();
        v.kind = FBX_BOOL;
        v.num = value ? 1 : 0;
        v.long = value ? 1 : 0;
        return v;
    }

    static ofNumber(value: f64): FBXValue {
        const v = new FBXValue();
        v.kind = FBX_NUMBER;
        v.num = value;
        v.long = isFinite(value) ? <i64>value : 0;
        return v;
    }

    static ofLong(value: i64): FBXValue {
        const v = new FBXValue();
        v.kind = FBX_NUMBER;
        v.num = <f64>value;
        v.long = value;
        v.isLong = true;
        return v;
    }

    static ofString(value: string): FBXValue {
        const v = new FBXValue();
        v.kind = FBX_STRING;
        v.str = value;
        return v;
    }

    static ofArray(value: Array<f64>): FBXValue {
        const v = new FBXValue();
        v.kind = FBX_ARRAY;
        v.arr = value;
        return v;
    }

    static ofBytes(value: ArrayBuffer): FBXValue {
        const v = new FBXValue();
        v.kind = FBX_BYTES;
        v.bytes = value;
        return v;
    }

    /// The number (a string is parsed, as the ASCII format stores them;
    /// NaN for other kinds).
    asNumber(): f64 {
        if (this.kind == FBX_NUMBER || this.kind == FBX_BOOL) return this.num;
        if (this.kind == FBX_STRING) return parseFloat(this.str);
        return NaN;
    }

    /// The 64-bit integer (ids), from a number or a string.
    asLong(): i64 {
        if (this.kind == FBX_NUMBER || this.kind == FBX_BOOL) return this.long;
        if (this.kind == FBX_STRING) return parseLeadingInt(this.str).value;
        return 0;
    }

    asString(): string {
        if (this.kind == FBX_STRING) return this.str;
        if (this.kind == FBX_NUMBER) return this.isLong ? this.long.toString() : this.num.toString();
        if (this.kind == FBX_BOOL) return this.num != 0 ? "true" : "false";
        return "";
    }
}

/// A Properties70 entry: `P: "Name", "type", "type2", "flag", value...`.
export class FBXProperty {
    type: string;
    type2: string;
    flag: string;
    value: FBXValue;

    constructor(type: string, type2: string, flag: string, value: FBXValue) {
        this.type = type;
        this.type2 = type2;
        this.flag = flag;
        this.value = value;
    }
}

/// A `C: "OO", from, to` or `C: "OP", from, to, "property"` record.
export class FBXConnection {
    from: i64;
    to: i64;
    relationship: string;

    constructor(from: i64, to: i64, relationship: string) {
        this.from = from;
        this.to = to;
        this.relationship = relationship;
    }
}

/// A node record of the FBX tree. Sub nodes keep their order; lookups by
/// name stand for three.js's `node.Name` (`value` and `array` for single
/// property sub nodes, `property` for Properties70 entries).
export class FBXNode {
    name: string = "";
    id: i64 = 0;
    hasId: bool = false;
    attrName: string = "";
    attrType: string = "";
    propertyList: Array<FBXValue> = [];
    singleProperty: bool = false;
    /// The array of a single array property (`node.Vertices.a`).
    a: Array<f64>? = null;
    children: Array<FBXNode> = [];
    properties: Map<string, FBXProperty> = new Map<string, FBXProperty>();
    connections: Array<FBXConnection> = [];
    /// An ASCII array still being read.
    aText: string = "";

    /// The first sub node named `name`.
    node(name: string): FBXNode? {
        for (let i = 0; i < this.children.length; i++) {
            if (this.children[i].name == name) return this.children[i];
        }
        return null;
    }

    nodesNamed(name: string): Array<FBXNode> {
        const nodes: Array<FBXNode> = [];
        for (let i = 0; i < this.children.length; i++) {
            if (this.children[i].name == name) nodes.push(this.children[i]);
        }
        return nodes;
    }

    /// The value of the (last) single property sub node named `name`.
    value(name: string): FBXValue? {
        for (let i = this.children.length - 1; i >= 0; i--) {
            const child = this.children[i];
            if (child.name == name && child.propertyList.length > 0) return child.propertyList[0];
        }
        return null;
    }

    /// The array of the sub node named `name` (its `a`).
    array(name: string): Array<f64>? {
        const child = this.node(name);
        return child != null ? child.a : null;
    }

    string(name: string, fallback: string): string {
        const value = this.value(name);
        return value != null ? value.asString() : fallback;
    }

    number(name: string, fallback: f64): f64 {
        const value = this.value(name);
        return value != null ? value.asNumber() : fallback;
    }

    property(name: string): FBXProperty? {
        return this.properties.has(name) ? this.properties.get(name) : null;
    }
}

/// The objects of one type (FBXTree.Objects.Model ...) by ID, in the order
/// JavaScript visits an object keyed by them (three.js iterates with
/// for-in): array-index IDs ascending, then the others in file order. A
/// repeated ID keeps its first node.
export class FBXObjects {
    map: Map<i64, FBXNode> = new Map<i64, FBXNode>();
    ids: Array<i64> = [];

    has(id: i64): bool { return this.map.has(id); }

    get(id: i64): FBXNode { return this.map.get(id); }
}

/// The parsed file: its top-level nodes by name (FBXHeaderExtension,
/// GlobalSettings, Objects, Connections ...).
export class FBXTree {
    nodes: Map<string, FBXNode> = new Map<string, FBXNode>();
    private objectsByType: Map<string, FBXObjects> = new Map<string, FBXObjects>();

    add(key: string, val: FBXNode): void {
        this.nodes.set(key, val);
        this.objectsByType.clear();
    }

    node(key: string): FBXNode? {
        return this.nodes.has(key) ? this.nodes.get(key) : null;
    }

    /// FBXTree.Objects[type] (empty when there are none).
    objects(type: string): FBXObjects {
        if (this.objectsByType.has(type)) return this.objectsByType.get(type);
        const result = new FBXObjects();
        const objects = this.node("Objects");
        if (objects != null) {
            const indexIds: Array<i64> = [];
            const otherIds: Array<i64> = [];
            for (let i = 0; i < objects.children.length; i++) {
                const child = objects.children[i];
                if (child.name != type || !child.hasId || result.map.has(child.id)) continue;
                result.map.set(child.id, child);
                if (child.id >= 0 && child.id < 4294967295) indexIds.push(child.id);
                else otherIds.push(child.id);
            }
            indexIds.sort((a: i64, b: i64): i32 => (a < b ? -1 : a > b ? 1 : 0));
            for (let i = 0; i < indexIds.length; i++) result.ids.push(indexIds[i]);
            for (let i = 0; i < otherIds.length; i++) result.ids.push(otherIds[i]);
        }
        this.objectsByType.set(type, result);
        return result;
    }
}

// ================================================================= utilities

const BINARY_MAGIC: string = "Kaydara FBX Binary  ";

export function isFbxFormatBinary(buffer: ArrayBuffer): bool {
    const length = BINARY_MAGIC.length + 1;   // and a NUL
    if (buffer.byteLength < length) return false;
    const bytes = Uint8Array.wrap(buffer);
    for (let i = 0; i < BINARY_MAGIC.length; i++) {
        if (<i32>bytes[i] != BINARY_MAGIC.charCodeAt(i)) return false;
    }
    return bytes[BINARY_MAGIC.length] == 0;
}

// As three.js: compares the characters at offsets 0, 1, 3, 6, 10 ... with
// "Kaydara\FBX\Binary\\"; any match means binary.
export function isFbxFormatASCII(text: string): bool {
    const CORRECT = "Kaydara\\FBX\\Binary\\\\";
    let position = 0;
    for (let i = 0; i < CORRECT.length; ++i) {
        if (position < text.length && text.charCodeAt(position) == CORRECT.charCodeAt(i)) return false;
        position += i + 1;
    }
    return true;
}

/// The FBXVersion of an ASCII file, -1 when it has none.
export function getFbxVersion(text: string): i32 {
    const key = "FBXVersion: ";
    const at = text.indexOf(key);
    if (at < 0) return -1;
    let i = at + key.length;
    let version = 0;
    const start = i;
    while (i < text.length) {
        const c = text.charCodeAt(i);
        if (c < 48 || c > 57) break;
        version = version * 10 + (c - 48);
        i++;
    }
    return i > start ? version : -1;
}

/// FBX ticks to seconds.
export function convertFBXTimeToSeconds(time: f64): f64 {
    return time / 46186158000;
}

// The data of one vertex, filled by getData (three.js returns a shared array).
const dataArray: Array<f64> = [0, 0, 0, 0];

// Fills dataArray with the vertex's data in `infoObject`, by its mapping
// and reference types (NaN where the data is missing).
function getData(polygonVertexIndex: i32, polygonIndex: i32, vertexIndex: i32, infoObject: FBXLayerInfo): void {
    let index = -1;
    const mappingType = infoObject.mappingType;
    if (mappingType == "ByPolygonVertex") index = polygonVertexIndex;
    else if (mappingType == "ByPolygon") index = polygonIndex;
    else if (mappingType == "ByVertice") index = vertexIndex;
    else if (mappingType == "AllSame") index = infoObject.indices.length > 0 ? <i32>infoObject.indices[0] : -1;
    if (infoObject.referenceType == "IndexToDirect") {
        index = index >= 0 && index < infoObject.indices.length ? <i32>infoObject.indices[index] : -1;
    }
    const from = index * infoObject.dataSize;
    for (let j = 0; j < infoObject.dataSize; j++) dataArray[j] = index >= 0 ? at(infoObject.buffer, from + j) : NaN;
}

const tempEuler = new Euler();
const tempVec = new Vector3();

function setFromArray(v: Vector3, a: Array<f64>): Vector3 {
    return v.set(a.length > 0 ? a[0] : 0, a.length > 1 ? a[1] : 0, a.length > 2 ? a[2] : 0);
}

function rotationMatrix(degrees: Array<f64>, order: string, target: Matrix4): void {
    tempEuler.set(MathUtils.degToRad(degrees.length > 0 ? degrees[0] : 0), MathUtils.degToRad(degrees.length > 1 ? degrees[1] : 0),
        MathUtils.degToRad(degrees.length > 2 ? degrees[2] : 0), order);
    target.makeRotationFromEuler(tempEuler);
}

// The transform of FBX transform data: translation, rotation offset and
// pivot, pre-rotation, rotation, post-rotation, scaling offset and pivot,
// scaling; inherit types 0 (RrSs), 1 (RSrs) and 2 (Rrs).
// ref: https://help.autodesk.com/view/FBX/2017/ENU/?guid=__files_GUID_10CDD63C_79C1_4F2D_BB28_AD2BE65A02ED_htm
export function generateTransform(transformData: FBXTransformData): Matrix4 {
    const lTranslationM = new Matrix4();
    const lPreRotationM = new Matrix4();
    const lRotationM = new Matrix4();
    const lPostRotationM = new Matrix4();
    const lScalingM = new Matrix4();
    const lScalingPivotM = new Matrix4();
    const lScalingOffsetM = new Matrix4();
    const lRotationOffsetM = new Matrix4();
    const lRotationPivotM = new Matrix4();
    const lParentGX = new Matrix4();
    const lParentLX = new Matrix4();
    const lGlobalT = new Matrix4();
    const inheritType = transformData.inheritType;
    const translation = transformData.translation;
    if (translation != null) {
        setFromArray(tempVec, translation!);
        lTranslationM.setPosition(tempVec.x, tempVec.y, tempVec.z);
    }
    // For Maya models using "Joint Orient", Euler order only applies to rotation, not pre/post-rotations
    const defaultEulerOrder = getEulerOrder(0);
    const preRotation = transformData.preRotation;
    if (preRotation != null) rotationMatrix(preRotation!, defaultEulerOrder, lPreRotationM);
    const rotation = transformData.rotation;
    if (rotation != null) {
        rotationMatrix(rotation!, transformData.eulerOrder.length > 0 ? transformData.eulerOrder : defaultEulerOrder, lRotationM);
    }
    const postRotation = transformData.postRotation;
    if (postRotation != null) {
        rotationMatrix(postRotation!, defaultEulerOrder, lPostRotationM);
        lPostRotationM.invert();
    }
    const scale = transformData.scale;
    if (scale != null) lScalingM.scale(setFromArray(tempVec, scale!));
    // Pivots and offsets
    const scalingOffset = transformData.scalingOffset;
    if (scalingOffset != null) {
        setFromArray(tempVec, scalingOffset!);
        lScalingOffsetM.setPosition(tempVec.x, tempVec.y, tempVec.z);
    }
    const scalingPivot = transformData.scalingPivot;
    if (scalingPivot != null) {
        setFromArray(tempVec, scalingPivot!);
        lScalingPivotM.setPosition(tempVec.x, tempVec.y, tempVec.z);
    }
    const rotationOffset = transformData.rotationOffset;
    if (rotationOffset != null) {
        setFromArray(tempVec, rotationOffset!);
        lRotationOffsetM.setPosition(tempVec.x, tempVec.y, tempVec.z);
    }
    const rotationPivot = transformData.rotationPivot;
    if (rotationPivot != null) {
        setFromArray(tempVec, rotationPivot!);
        lRotationPivotM.setPosition(tempVec.x, tempVec.y, tempVec.z);
    }
    // parent transform
    const parentMatrixWorld = transformData.parentMatrixWorld;
    const parentMatrix = transformData.parentMatrix;
    if (parentMatrixWorld != null) {
        if (parentMatrix != null) lParentLX.copy(parentMatrix!);
        lParentGX.copy(parentMatrixWorld!);
    }
    const lLRM = lPreRotationM.clone().multiply(lRotationM).multiply(lPostRotationM);
    // Global Rotation
    const lParentGRM = new Matrix4();
    lParentGRM.extractRotation(lParentGX);
    // Global Shear*Scaling
    const lParentTM = new Matrix4();
    lParentTM.copyPosition(lParentGX);
    const lParentGRSM = lParentTM.clone().invert().multiply(lParentGX);
    const lParentGSM = lParentGRM.clone().invert().multiply(lParentGRSM);
    const lLSM = lScalingM;
    const lGlobalRS = new Matrix4();
    if (inheritType == 0) {
        lGlobalRS.copy(lParentGRM).multiply(lLRM).multiply(lParentGSM).multiply(lLSM);
    } else if (inheritType == 1) {
        lGlobalRS.copy(lParentGRM).multiply(lParentGSM).multiply(lLRM).multiply(lLSM);
    } else {
        const lParentLSM = new Matrix4().scale(new Vector3().setFromMatrixScale(lParentLX));
        const lParentLSM_inv = lParentLSM.clone().invert();
        const lParentGSM_noLocal = lParentGSM.clone().multiply(lParentLSM_inv);
        lGlobalRS.copy(lParentGRM).multiply(lLRM).multiply(lParentGSM_noLocal).multiply(lLSM);
    }
    const lRotationPivotM_inv = lRotationPivotM.clone().invert();
    const lScalingPivotM_inv = lScalingPivotM.clone().invert();
    // Calculate the local transform matrix
    let lTransform = lTranslationM.clone().multiply(lRotationOffsetM).multiply(lRotationPivotM).multiply(lPreRotationM)
        .multiply(lRotationM).multiply(lPostRotationM).multiply(lRotationPivotM_inv).multiply(lScalingOffsetM)
        .multiply(lScalingPivotM).multiply(lScalingM).multiply(lScalingPivotM_inv);
    const lLocalTWithAllPivotAndOffsetInfo = new Matrix4().copyPosition(lTransform);
    const lGlobalTranslation = lParentGX.clone().multiply(lLocalTWithAllPivotAndOffsetInfo);
    lGlobalT.copyPosition(lGlobalTranslation);
    lTransform = lGlobalT.clone().multiply(lGlobalRS);
    // from global to local
    lTransform.premultiply(lParentGX.invert());
    return lTransform;
}

// The three.js intrinsic Euler order of an FBX extrinsic order
// (ref: FbxEuler). 6, SphericXYZ, cannot be supported: it reads as 0.
export function getEulerOrder(order: i32): string {
    if (order == 1) return "YZX";   // -> XZY extrinsic
    if (order == 2) return "XZY";   // -> YZX extrinsic
    if (order == 3) return "ZXY";   // -> YXZ extrinsic
    if (order == 4) return "YXZ";   // -> ZXY extrinsic
    if (order == 5) return "XYZ";   // -> ZYX extrinsic
    return "ZYX";   // 0 -> XYZ extrinsic
}

// Parses a comma separated list of numbers (the TextParser's arrays).
export function parseNumberArray(value: string): Array<f64> {
    const parts = value.split(",");
    const array = new Array<f64>(parts.length);
    for (let i = 0; i < parts.length; i++) array[i] = parseFloat(parts[i].trim());
    return array;
}

export function convertArrayBufferToString(buffer: ArrayBuffer, from: i32 = 0, to: i32 = -1): string {
    const end = to < 0 ? buffer.byteLength : to;
    return String.UTF8.decode(from == 0 && end == buffer.byteLength ? buffer : buffer.slice(from, end));
}

class ParsedInt {
    ok: bool = false;
    value: i64 = 0;
}

/// JavaScript's parseInt: optional blanks and sign, then digits.
function parseLeadingInt(s: string): ParsedInt {
    const result = new ParsedInt();
    let i = 0;
    while (i < s.length && isBlank(s.charCodeAt(i))) i++;
    let negative = false;
    if (i < s.length && (s.charCodeAt(i) == 45 || s.charCodeAt(i) == 43)) {
        negative = s.charCodeAt(i) == 45;
        i++;
    }
    let value: i64 = 0;
    const start = i;
    while (i < s.length) {
        const c = s.charCodeAt(i);
        if (c < 48 || c > 57) break;
        value = value * 10 + <i64>(c - 48);
        i++;
    }
    result.ok = i > start;
    result.value = negative ? -value : value;
    return result;
}

function isBlank(c: i32): bool {
    return c == 32 || c == 9 || c == 10 || c == 13 || c == 11 || c == 12;
}

function isWordChar(c: i32): bool {
    return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
}

function leadingTabs(line: string): i32 {
    let i = 0;
    while (i < line.length && line.charCodeAt(i) == 9) i++;
    return i;
}

function firstNonBlank(line: string): i32 {
    for (let i = 0; i < line.length; i++) {
        if (!isBlank(line.charCodeAt(i))) return i;
    }
    return -1;
}

function wordEnd(line: string, start: i32): i32 {
    let i = start;
    while (i < line.length && isWordChar(line.charCodeAt(i))) i++;
    return i;
}

/// The lines of `text`, split on runs of \r and \n.
function splitLines(text: string): Array<string> {
    const lines: Array<string> = [];
    let start = 0;
    for (let i = 0; i <= text.length; i++) {
        const c = i < text.length ? text.charCodeAt(i) : 10;
        if (c == 10 || c == 13) {
            if (i > start) lines.push(text.substring(start, i));
            start = i + 1;
        }
    }
    return lines;
}

/// Without one leading and one trailing double quote.
function stripQuotes(s: string): string {
    let start = 0, end = s.length;
    if (end > 0 && s.charCodeAt(0) == 34) start = 1;
    if (end > start && s.charCodeAt(end - 1) == 34) end--;
    return s.substring(start, end);
}

function stripLeadingQuote(s: string): string {
    return s.length > 0 && s.charCodeAt(0) == 34 ? s.substring(1) : s;
}

/// "Model::Cube" -> "Cube" (a leading word and "::").
function stripClassPrefix(s: string): string {
    const end = wordEnd(s, 0);
    if (end > 0 && end + 1 < s.length && s.charCodeAt(end) == 58 && s.charCodeAt(end + 1) == 58) return s.substring(end + 2);
    return s;
}

/// The first blank replaced by "_" ("Lcl Translation" -> "Lcl_Translation").
function replaceFirstBlank(s: string): string {
    for (let i = 0; i < s.length; i++) {
        if (isBlank(s.charCodeAt(i))) return s.substring(0, i) + "_" + s.substring(i + 1);
    }
    return s;
}

function base64Value(c: i32): i32 {
    if (c >= 65 && c <= 90) return c - 65;
    if (c >= 97 && c <= 122) return c - 71;
    if (c >= 48 && c <= 57) return c + 4;
    if (c == 43 || c == 45) return 62;
    if (c == 47 || c == 95) return 63;
    return -1;
}

/// The bytes of base64 text (the ASCII format's embedded images).
function base64Decode(text: string): Uint8Array {
    const out = new Uint8Array(text.length * 3 / 4 + 3);
    let n = 0, acc: u32 = 0, bits = 0;
    for (let i = 0; i < text.length; i++) {
        const v = base64Value(text.charCodeAt(i));
        if (v < 0) continue;   // padding, whitespace
        acc = (acc << 6) | <u32>v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[n++] = <u8>((acc >> <u32>bits) & 255);
        }
    }
    return out.slice(0, n);
}
