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
export const AlphaFormat: i32 = 1021;
export const RGBFormat: i32 = 1022;
export const RGBAFormat: i32 = 1023;
export const DepthFormat: i32 = 1026;
export const RedFormat: i32 = 1028;
export const RGFormat: i32 = 1030;
// Compressed formats (CompressedTexture.format).
export const RGB_S3TC_DXT1_Format: i32 = 33776;
export const RGBA_S3TC_DXT1_Format: i32 = 33777;
export const RGBA_S3TC_DXT5_Format: i32 = 33779;
export const RGBA_BPTC_Format: i32 = 36492;
export const RGB_ETC2_Format: i32 = 37492;
export const RGBA_ETC2_EAC_Format: i32 = 37496;
export const RGBA_ASTC_4x4_Format: i32 = 37808;
export const RGBA_ASTC_6x6_Format: i32 = 37812;
export const RGBA_ASTC_8x8_Format: i32 = 37818;

// Texture.type / RenderTarget type
export const UnsignedByteType: i32 = 1009;
export const UnsignedShortType: i32 = 1012;
export const UnsignedIntType: i32 = 1014;
export const FloatType: i32 = 1015;
export const HalfFloatType: i32 = 1016;

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

// Animation blend modes (kept on clips; additive blending is not ported)
export const NormalAnimationBlendMode: i32 = 2500;
export const AdditiveAnimationBlendMode: i32 = 2501;

// Material.combine (Basic, Lambert, Phong envMap)
export const MultiplyOperation: i32 = 0;
export const MixOperation: i32 = 1;
export const AddOperation: i32 = 2;

// Material.depthFunc
export const NeverDepth: i32 = 0;
export const AlwaysDepth: i32 = 1;
export const LessDepth: i32 = 2;
export const LessEqualDepth: i32 = 3;
export const EqualDepth: i32 = 4;
export const GreaterEqualDepth: i32 = 5;
export const GreaterDepth: i32 = 6;
export const NotEqualDepth: i32 = 7;

// Material.stencilFunc
export const NeverStencilFunc: i32 = 512;
export const LessStencilFunc: i32 = 513;
export const EqualStencilFunc: i32 = 514;
export const LessEqualStencilFunc: i32 = 515;
export const GreaterStencilFunc: i32 = 516;
export const NotEqualStencilFunc: i32 = 517;
export const GreaterEqualStencilFunc: i32 = 518;
export const AlwaysStencilFunc: i32 = 519;

// Material.stencilFail / stencilZFail / stencilZPass
export const ZeroStencilOp: i32 = 0;
export const KeepStencilOp: i32 = 7680;
export const ReplaceStencilOp: i32 = 7681;
export const IncrementStencilOp: i32 = 7682;
export const DecrementStencilOp: i32 = 7683;
export const IncrementWrapStencilOp: i32 = 34055;
export const DecrementWrapStencilOp: i32 = 34056;
export const InvertStencilOp: i32 = 5386;
