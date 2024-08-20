#if (SHADERPASS == SHADERPASS_SHADOWCASTER)
    // Shadow Casting Light geometric parameters. These variables are used when applying the shadow Normal Bias and are set by UnityEngine.Rendering.Universal.ShadowUtils.SetupShadowCasterConstantBuffer in com.unity.render-pipelines.universal/Runtime/ShadowUtils.cs
    // For Directional lights, _LightDirection is used when applying shadow Normal Bias.
    // For Spot lights and Point lights, _LightPosition is used to compute the actual light direction because it is different at each shadow caster geometry vertex.
#ifndef HAVE_VFX_MODIFICATION
    float3 _LightDirection;
#else
    //_LightDirection is already defined in com.unity.render-pipelines.universal\Runtime\VFXGraph\Shaders\VFXCommon.hlsl
#endif
    float3 _LightPosition;
#endif

#ifdef VARYINGS_NEED_PREVIOUS_POSITION_CS
    bool IsSmoothRotation(float3 prevAxis1, float3 prevAxis2, float3 currAxis1, float3 currAxis2)
    {
        float angleThreshold = 0.984f; // cos(10 degrees)
        float2 angleDot = float2(dot(normalize(prevAxis1), normalize(currAxis1)), dot(normalize(prevAxis2), normalize(currAxis2)));
        return all(angleDot > angleThreshold);
    }
#endif

#if defined(FEATURES_GRAPH_VERTEX)
#if defined(HAVE_VFX_MODIFICATION)
VertexDescription BuildVertexDescription(Attributes input, AttributesElement element, out GraphProperties properties)
{
    ZERO_INITIALIZE(GraphProperties, properties);
    // Fetch the vertex graph properties for the particle instance.
    GetElementVertexProperties(element, properties);

    // Evaluate Vertex Graph
    VertexDescriptionInputs vertexDescriptionInputs = BuildVertexDescriptionInputs(input);
    VertexDescription vertexDescription = VertexDescriptionFunction(vertexDescriptionInputs, properties);
    return vertexDescription;
}
#else
VertexDescription BuildVertexDescription(Attributes input)
{
    // Evaluate Vertex Graph
    VertexDescriptionInputs vertexDescriptionInputs = BuildVertexDescriptionInputs(input);
    VertexDescription vertexDescription = VertexDescriptionFunction(vertexDescriptionInputs);
    return vertexDescription;
}
#endif
#endif

#if (SHADERPASS == SHADERPASS_MOTION_VECTORS)
// We want to gather some internal data from the BuildVaryings call to
// avoid rereading and recalculating these values again in the ShaderGraph motion vector pass
struct MotionVectorPassOutput
{
    float3 positionOS;
    float3 positionWS;
#if defined(FEATURES_GRAPH_VERTEX_MOTION_VECTOR_OUTPUT)
    float3 motionVector;
#endif
#if defined(HAVE_VFX_MODIFICATION)
    float3 vfxParticlePositionOS;
    AttributesElement vfxElementAttributes;
    GraphProperties vfxGraphProperties;
#endif

};
#endif

Varyings BuildVaryings(Attributes input
#if (SHADERPASS == SHADERPASS_MOTION_VECTORS)
    , inout MotionVectorPassOutput motionVectorOutput
#endif
)
{
    Varyings output = (Varyings)0;

    UNITY_SETUP_INSTANCE_ID(input);

#if defined(HAVE_VFX_MODIFICATION)
    AttributesElement element;
    ZERO_INITIALIZE(AttributesElement, element);

    if (!GetMeshAndElementIndex(input, element))
        return output; // Culled index.

    if (!GetInterpolatorAndElementData(output, element))
        return output; // Dead particle.

    SetupVFXMatrices(element, output);

    #if (SHADERPASS == SHADERPASS_MOTION_VECTORS)
        motionVectorOutput.vfxParticlePositionOS = input.positionOS;
    #endif

#endif

    UNITY_TRANSFER_INSTANCE_ID(input, output);
    UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

#if defined(FEATURES_GRAPH_VERTEX)
    #if defined(HAVE_VFX_MODIFICATION)
        GraphProperties properties;
        VertexDescription vertexDescription = BuildVertexDescription(input, element, properties);
    #else
        VertexDescription vertexDescription = BuildVertexDescription(input);
    #endif

    #if defined(CUSTOMINTERPOLATOR_VARYPASSTHROUGH_FUNC)
        CustomInterpolatorPassThroughFunc(output, vertexDescription);
    #endif

    // Assign modified vertex attributes
    input.positionOS = vertexDescription.Position;
    #if defined(ATTRIBUTES_NEED_NORMAL) && defined(FEATURES_GRAPH_VERTEX_NORMAL_OUTPUT)
        input.normalOS = vertexDescription.Normal;
    #endif //FEATURES_GRAPH_NORMAL
    #if defined(ATTRIBUTES_NEED_TANGENT) && defined(FEATURES_GRAPH_VERTEX_TANGENT_OUTPUT)
        input.tangentOS.xyz = vertexDescription.Tangent.xyz;
    #endif //FEATURES GRAPH TANGENT
#endif //FEATURES_GRAPH_VERTEX

    // TODO: Avoid path via VertexPositionInputs (Universal)
    VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);

    // Returns the camera relative position (if enabled)
    float3 positionWS = TransformObjectToWorld(input.positionOS);

#if (SHADERPASS == SHADERPASS_MOTION_VECTORS)
    motionVectorOutput.positionOS = input.positionOS;
    motionVectorOutput.positionWS = positionWS;
    #if defined(FEATURES_GRAPH_VERTEX_MOTION_VECTOR_OUTPUT)
        motionVectorOutput.motionVector = vertexDescription.MotionVector;
    #endif
    #if defined(HAVE_VFX_MODIFICATION)
        motionVectorOutput.vfxElementAttributes = element;
        motionVectorOutput.vfxGraphProperties = properties;
    #endif
#endif

#ifdef ATTRIBUTES_NEED_NORMAL
    float3 normalWS = TransformObjectToWorldNormal(input.normalOS);
#else
    // Required to compile ApplyVertexModification that doesn't use normal.
    float3 normalWS = float3(0.0, 0.0, 0.0);
#endif

#ifdef ATTRIBUTES_NEED_TANGENT
    float4 tangentWS = float4(TransformObjectToWorldDir(input.tangentOS.xyz), input.tangentOS.w);
#endif

    // TODO: Change to inline ifdef
    // Do vertex modification in camera relative space (if enabled)
#if defined(HAVE_VERTEX_MODIFICATION)
    ApplyVertexModification(input, normalWS, positionWS, _TimeParameters.xyz);
#endif

#ifdef VARYINGS_NEED_POSITION_WS
    output.positionWS = positionWS;
#endif

#ifdef VARYINGS_NEED_NORMAL_WS
    output.normalWS = normalWS;         // normalized in TransformObjectToWorldNormal()
#endif

#ifdef VARYINGS_NEED_TANGENT_WS
    output.tangentWS = tangentWS;       // normalized in TransformObjectToWorldDir()
#endif

#if (SHADERPASS == SHADERPASS_SHADOWCASTER)
    // Define shadow pass specific clip position for Universal
    #if _CASTING_PUNCTUAL_LIGHT_SHADOW
        float3 lightDirectionWS = normalize(_LightPosition - positionWS);
    #else
        float3 lightDirectionWS = _LightDirection;
    #endif
    output.positionCS = TransformWorldToHClip(ApplyShadowBias(positionWS, normalWS, lightDirectionWS));
    #if UNITY_REVERSED_Z
        output.positionCS.z = min(output.positionCS.z, UNITY_NEAR_CLIP_VALUE);
    #else
        output.positionCS.z = max(output.positionCS.z, UNITY_NEAR_CLIP_VALUE);
    #endif
#elif (SHADERPASS == SHADERPASS_META)
    output.positionCS = UnityMetaVertexPosition(input.positionOS, input.uv1, input.uv2, unity_LightmapST, unity_DynamicLightmapST);
#else
    output.positionCS = TransformWorldToHClip(positionWS);
#endif

#if defined(VARYINGS_NEED_TEXCOORD0) || defined(VARYINGS_DS_NEED_TEXCOORD0)
    output.texCoord0 = input.uv0;
#endif
#ifdef EDITOR_VISUALIZATION
    float2 VizUV = 0;
    float4 LightCoord = 0;
    UnityEditorVizData(input.positionOS, input.uv0, input.uv1, input.uv2, VizUV, LightCoord);
#endif
#if defined(VARYINGS_NEED_TEXCOORD1) || defined(VARYINGS_DS_NEED_TEXCOORD1)
#ifdef EDITOR_VISUALIZATION
    output.texCoord1 = float4(VizUV, 0, 0);
#else
    output.texCoord1 = input.uv1;
#endif
#endif
#if defined(VARYINGS_NEED_TEXCOORD2) || defined(VARYINGS_DS_NEED_TEXCOORD2)
#ifdef EDITOR_VISUALIZATION
    output.texCoord2 = LightCoord;
#else
    output.texCoord2 = input.uv2;
#endif
#endif
#if defined(VARYINGS_NEED_TEXCOORD3) || defined(VARYINGS_DS_NEED_TEXCOORD3)
    output.texCoord3 = input.uv3;
#endif

#if defined(VARYINGS_NEED_COLOR) || defined(VARYINGS_DS_NEED_COLOR)
    output.color = input.color;
#endif

#ifdef VARYINGS_NEED_SCREENPOSITION
    output.screenPosition = vertexInput.positionNDC;
#endif

#if (SHADERPASS == SHADERPASS_FORWARD) || (SHADERPASS == SHADERPASS_GBUFFER)
    OUTPUT_LIGHTMAP_UV(input.uv1, unity_LightmapST, output.staticLightmapUV);
#if defined(DYNAMICLIGHTMAP_ON)
    output.dynamicLightmapUV.xy = input.uv2.xy * unity_DynamicLightmapST.xy + unity_DynamicLightmapST.zw;
#endif
    OUTPUT_SH4(vertexInput.positionWS, normalWS.xyz, GetWorldSpaceNormalizeViewDir(vertexInput.positionWS), output.sh);
#endif

#ifdef VARYINGS_NEED_FOG_AND_VERTEX_LIGHT
    half fogFactor = 0;
#if !defined(_FOG_FRAGMENT)
        fogFactor = ComputeFogFactor(output.positionCS.z);
#endif
    half3 vertexLight = VertexLighting(positionWS, normalWS);
    output.fogFactorAndVertexLight = half4(fogFactor, vertexLight);
#endif

#ifdef VARYINGS_NEED_CURRENT_POSITION_CS
    float3 curWS = TransformObjectToWorld(input.positionOS.xyz);
    output.curPositionCS = TransformWorldToHClip(curWS);
#endif

#ifdef VARYINGS_NEED_PREVIOUS_POSITION_CS
    if (unity_MotionVectorsParams.y == 0.0)
    {
        output.prevPositionCS = float4(0.0, 0.0, 0.0, 1.0);
    }
    else
    {
        bool hasDeformation = unity_MotionVectorsParams.x > 0.0;
        float3 effectivePositionOS = (hasDeformation ? input.uv4.xyz : input.positionOS.xyz);
        float3 previousWS = TransformPreviousObjectToWorld(effectivePositionOS);

        float4x4 previousOTW = GetPrevObjectToWorldMatrix();
        float4x4 currentOTW = GetObjectToWorldMatrix();
        if (!IsSmoothRotation(previousOTW._11_21_31, previousOTW._12_22_32, currentOTW._11_21_31, currentOTW._12_22_32))
        {
            output.prevPositionCS = output.curPositionCS;
        }
        else
        {
            output.prevPositionCS = TransformWorldToPrevHClip(previousWS);
        }
    }
#endif

#if defined(VARYINGS_NEED_SHADOW_COORD) && defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
    output.shadowCoord = GetShadowCoord(vertexInput);
#endif

#if defined(VARYINGS_NEED_SIX_WAY_DIFFUSE_GI_DATA)
    GatherDiffuseGIData(vertexInput.positionWS, normalWS.xyz, tangentWS.xyz, output.diffuseGIData0, output.diffuseGIData1, output.diffuseGIData2);
#endif
    return output;
}

SurfaceDescription BuildSurfaceDescription(Varyings varyings)
{
    SurfaceDescriptionInputs surfaceDescriptionInputs = BuildSurfaceDescriptionInputs(varyings);
#if defined(HAVE_VFX_MODIFICATION)
    GraphProperties properties;
    ZERO_INITIALIZE(GraphProperties, properties);
    GetElementPixelProperties(surfaceDescriptionInputs, properties);
    SurfaceDescription surfaceDescription = SurfaceDescriptionFunction(surfaceDescriptionInputs, properties);
#else
    SurfaceDescription surfaceDescription = SurfaceDescriptionFunction(surfaceDescriptionInputs);
#endif
    return surfaceDescription;
}
