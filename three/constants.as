// Constants, with three.js's names and values.

export const REVISION: string = "170-rive.1";

// Material.side
export const FrontSide: i32 = 0;
export const BackSide: i32 = 1;
export const DoubleSide: i32 = 2;

// Texture.colorSpace
export const NoColorSpace: string = "";
export const SRGBColorSpace: string = "srgb";
export const LinearSRGBColorSpace: string = "srgb-linear";

// Texture.wrapS / wrapT
export const RepeatWrapping: i32 = 1000;
export const ClampToEdgeWrapping: i32 = 1001;
export const MirroredRepeatWrapping: i32 = 1002;

// Texture.magFilter / minFilter
export const NearestFilter: i32 = 1003;
export const NearestMipmapNearestFilter: i32 = 1004;
export const NearestMipmapLinearFilter: i32 = 1005;
export const LinearFilter: i32 = 1006;
export const LinearMipmapNearestFilter: i32 = 1007;
export const LinearMipmapLinearFilter: i32 = 1008;

// Texture.format
export const RGBAFormat: i32 = 1023;

// Texture.type
export const UnsignedByteType: i32 = 1009;

// Texture.mapping
export const UVMapping: i32 = 300;
export const CubeReflectionMapping: i32 = 301;
export const CubeRefractionMapping: i32 = 302;
export const EquirectangularReflectionMapping: i32 = 303;
export const EquirectangularRefractionMapping: i32 = 304;

// Material.blending
export const NoBlending: i32 = 0;
export const NormalBlending: i32 = 1;
export const AdditiveBlending: i32 = 2;
export const SubtractiveBlending: i32 = 3;
export const MultiplyBlending: i32 = 4;
export const CustomBlending: i32 = 5;

// GPURenderer.toneMapping
export const NoToneMapping: i32 = 0;
export const LinearToneMapping: i32 = 1;
export const ReinhardToneMapping: i32 = 2;
export const CineonToneMapping: i32 = 3;
export const ACESFilmicToneMapping: i32 = 4;
export const CustomToneMapping: i32 = 5;
export const AgXToneMapping: i32 = 6;
export const NeutralToneMapping: i32 = 7;

// GPURenderer.shadowMap.type
export const BasicShadowMap: i32 = 0;
export const PCFShadowMap: i32 = 1;
export const PCFSoftShadowMap: i32 = 2;
export const VSMShadowMap: i32 = 3;

// MeshDepthMaterial.depthPacking
export const BasicDepthPacking: i32 = 3200;
export const RGBADepthPacking: i32 = 3201;

// Material.normalMapType
export const TangentSpaceNormalMap: i32 = 0;
export const ObjectSpaceNormalMap: i32 = 1;

// AnimationAction.loop
export const LoopOnce: i32 = 2200;
export const LoopRepeat: i32 = 2201;
export const LoopPingPong: i32 = 2202;

// KeyframeTrack interpolation
export const InterpolateDiscrete: i32 = 2300;
export const InterpolateLinear: i32 = 2301;
export const InterpolateSmooth: i32 = 2302;
