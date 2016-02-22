{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-}  -- TODO: remove
module LambdaCube.Compiler.CoreToIR
    ( compilePipeline
    ) where

import Data.Char
import Data.Monoid
import Data.Map (Map)
import Data.Maybe
import Data.Function
import Data.List
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Vector as Vector
import Control.Arrow hiding ((<+>))
import Control.Monad.Writer
import Control.Monad.State

import LambdaCube.IR(Backend(..))
import qualified LambdaCube.IR as IR
import qualified LambdaCube.Linear as IR

import LambdaCube.Compiler.Pretty
import Text.PrettyPrint.Compact (nest)
import LambdaCube.Compiler.Infer hiding (Con, Lam, Pi, TType, Var, ELit, Func)
import qualified LambdaCube.Compiler.Infer as I
import LambdaCube.Compiler.Parser (up, Up (..))

import Data.Version
import Paths_lambdacube_compiler (version)

--------------------------------------------------------------------------

compilePipeline :: IR.Backend -> ExpType -> IR.Pipeline
compilePipeline backend exp = IR.Pipeline
    { IR.info       = "generated by lambdacube-compiler " ++ showVersion version
    , IR.backend    = backend
    , IR.samplers   = mempty
    , IR.programs   = Vector.fromList . map fst . sortBy (compare `on` snd) . Map.toList $ programs
    , IR.slots      = Vector.fromList . map snd . sortBy (compare `on` fst) . Map.elems $ slots
    , IR.targets    = Vector.fromList . reverse . snd $ targets
    , IR.streams    = Vector.fromList . reverse . snd $ streams
    , IR.textures   = Vector.fromList . reverse . snd $ textures
    , IR.commands   = Vector.fromList $ subCmds <> cmds
    }
  where
    ((subCmds,cmds), (streams, programs, targets, slots, textures))
        = flip runState ((0, mempty), mempty, (0, mempty), mempty, (0, mempty)) $ case toExp exp of
            A1 "ScreenOut" a -> addTarget backend a [IR.TargetItem s $ Just $ IR.Framebuffer s | s <- getSemantics a]
            x -> error $ "ScreenOut expected inststead of " ++ ppShow x

type CG = State (List IR.StreamData, Map IR.Program Int, List IR.RenderTarget, Map String (Int, IR.Slot), List IR.TextureDescriptor)

type List a = (Int, [a])

streamLens  f (a,b,c,d,e) = f (,b,c,d,e) a
programLens f (a,b,c,d,e) = f (a,,c,d,e) b
targetLens  f (a,b,c,d,e) = f (a,b,,d,e) c
slotLens    f (a,b,c,d,e) = f (a,b,c,,e) d
textureLens f (a,b,c,d,e) = f (a,b,c,d,) e

modL gs f = state $ gs $ \fx -> second fx . f

addL' l p f x = modL l $ \sv -> maybe (length sv, Map.insert p (length sv, x) sv) (\(i, x') -> (i, Map.insert p (i, f x x') sv)) $ Map.lookup p sv
addL l x = modL l $ \(i, sv) -> (i, (i+1, x: sv))
addLEq l x = modL l $ \sv -> maybe (let i = length sv in i `seq` (i, Map.insert x i sv)) (\i -> (i, sv)) $ Map.lookup x sv

---------------------------------------------------------

addTarget backend a tl = do
    rt <- addL targetLens $ IR.RenderTarget $ Vector.fromList tl
    second (IR.SetRenderTarget rt:) <$> getCommands backend a

getCommands :: Backend -> ExpTV{-FrameBuffer-} -> CG ([IR.Command],[IR.Command])
getCommands backend e = case e of

    A1 "FrameBuffer" a -> return ([], [IR.ClearRenderTarget $ Vector.fromList $ map compFrameBuffer $ eTuple a])

    A3 "Accumulate" actx (getFragmentShader -> (frag, getFragFilter -> (ffilter, x1))) fbuf -> case x1 of

      A3 "foldr" (A0 "++") (A0 "Nil") (A2 "map" (EtaPrim3 "rasterizePrimitive" ints rctx) (getVertexShader -> (vert, input_))) -> mdo

        let 
            (vertexInput, pUniforms, vertSrc, fragSrc) = genGLSLs backend (compRC' rctx) ints vert frag ffilter

            pUniforms' = snd <$> Map.filter ((\case UTexture2D{} -> False; _ -> True) . fst) pUniforms

            prg = IR.Program
                { IR.programUniforms    = pUniforms'
                , IR.programStreams     = Map.fromList $ zip vertexInput $ map (uncurry IR.Parameter) input
                , IR.programInTextures  = snd <$> Map.filter ((\case UUniform{} -> False; _ -> True) . fst) pUniforms
                , IR.programOutput      = pure $ IR.Parameter "f0" IR.V4F -- TODO
                , IR.vertexShader       = show vertSrc
                , IR.geometryShader     = mempty -- TODO
                , IR.fragmentShader     = show fragSrc
                }

            textureUniforms = [IR.SetSamplerUniform n textureUnit | ((n,IR.FTexture2D),textureUnit) <- zip (Map.toList pUniforms') [0..]]
            cmds =
              [ IR.SetProgram prog ] <>
              textureUniforms <>
              concat -- TODO: generate IR.SetSamplerUniform commands for texture slots
              [ [ IR.SetTexture textureUnit texture
                , IR.SetSamplerUniform name textureUnit
                ] | (textureUnit,(name,IR.TextureImage texture _ _)) <- zip [length textureUniforms..] smpBindings
              ] <>
              [ IR.SetRasterContext (compRC rctx)
              , IR.SetAccumulationContext (compAC actx)
              , renderCommand
              ]

        (smpBindings, txtCmds) <- mconcat <$> traverse (uncurry getRenderTextureCommands) (Map.toList $ fst <$> pUniforms)

        (renderCommand,input) <- case input_ of
            A2 "fetch_" (EString slotName) attrs -> do
                i <- IR.RenderSlot <$> addL' slotLens slotName (flip mergeSlot) IR.Slot
                    { IR.slotName       = slotName
                    , IR.slotUniforms   = IR.programUniforms prg
                    , IR.slotPrograms   = pure prog
                    , IR.slotStreams    = Map.fromList input
                    , IR.slotPrimitive  = compFetchPrimitive $ getPrim $ tyOf input_
                    }
                return (i, input)
              where
                input = compInputType'' attrs
                mergeSlot a b = a
                  { IR.slotUniforms = IR.slotUniforms a <> IR.slotUniforms b
                  , IR.slotStreams  = IR.slotStreams a <> IR.slotStreams b
                  , IR.slotPrograms = IR.slotPrograms a <> IR.slotPrograms b
                  }
            A1 "fetchArrays_" (unzip . compAttributeValue -> (tys, values)) -> do
                i <- IR.RenderStream <$> addL streamLens IR.StreamData
                    { IR.streamData       = Map.fromList $ zip names values
                    , IR.streamType       = Map.fromList input
                    , IR.streamPrimitive  = compFetchPrimitive $ getPrim $ tyOf input_
                    , IR.streamPrograms   = pure prog
                    }
                return (i, input)
              where
                names = ["attribute_" ++ show i | i <- [0..]]
                input = zip names tys
            e -> error $ "getSlot: " ++ ppShow e

        prog <- addLEq programLens prg

        (<> (txtCmds, cmds)) <$> getCommands backend fbuf

      x -> error $ "getCommands': " ++ ppShow x
    x -> error $ "getCommands: " ++ ppShow x
  where
    getRenderTextureCommands :: String -> Uniform -> CG ([SamplerBinding],[IR.Command])
    getRenderTextureCommands n = \case
        UTexture2D (fromIntegral -> width) (fromIntegral -> height) img -> do

            let (a, tf) = case img of
                    A1 "PrjImageColor" a -> (,) a $ \[_, x] -> x
                    A1 "PrjImage" a      -> (,) a $ \[x] -> x
            tl <- forM (getSemantics a) $ \semantic -> do
                texture <- addL textureLens IR.TextureDescriptor
                    { IR.textureType      = IR.Texture2D (if semantic == IR.Color then IR.FloatT IR.RGBA else IR.FloatT IR.Red) 1
                    , IR.textureSize      = IR.VV2U $ IR.V2 (fromIntegral width) (fromIntegral height)
                    , IR.textureSemantic  = semantic
                    , IR.textureSampler   = IR.SamplerDescriptor
                        { IR.samplerWrapS       = IR.Repeat
                        , IR.samplerWrapT       = Nothing
                        , IR.samplerWrapR       = Nothing
                        , IR.samplerMinFilter   = IR.Linear 
                        , IR.samplerMagFilter   = IR.Linear
                        , IR.samplerBorderColor = IR.VV4F (IR.V4 0 0 0 1)
                        , IR.samplerMinLod      = Nothing
                        , IR.samplerMaxLod      = Nothing
                        , IR.samplerLodBias     = 0
                        , IR.samplerCompareFunc = Nothing
                        }
                    , IR.textureBaseLevel = 0
                    , IR.textureMaxLevel  = 0
                    }
                return $ IR.TargetItem semantic $ Just $ IR.TextureImage texture 0 Nothing
            (subCmds, cmds) <- addTarget backend a tl
            let (IR.TargetItem IR.Color (Just tx)) = tf tl
            return ([(n, tx)], subCmds ++ cmds)
        _ -> return mempty

type SamplerBinding = (IR.UniformName,IR.ImageRef)

----------------------------------------------------------------

frameBufferType (A2 "FrameBuffer" _ ty) = ty
frameBufferType x = error $ "illegal target type: " ++ ppShow x

getSemantics = compSemantics . frameBufferType . tyOf

getFragFilter (A2 "map" (EtaPrim2 "filterFragment" p) x) = (Just p, x)
getFragFilter x = (Nothing, x)

getVertexShader (A2 "map" (EtaPrim2 "mapPrimitive" f@(etaReds -> Just (_, o))) x) = ((Just f, tyOf o), x)
--getVertexShader (A2 "map" (EtaPrim2 "mapPrimitive" f) x) = error $ "gff: " ++ show (case f of ExpTV x _ _ -> x) --ppShow (mapVal unFunc' f)
--getVertexShader x = error $ "gf: " ++ ppShow x
getVertexShader x = ((Nothing, getPrim' $ tyOf x), x)

getFragmentShader (A2 "map" (EtaPrim2 "mapFragment" f@(etaReds -> Just (_, o))) x) = ((Just f, tyOf o), x)
--getFragmentShader (A2 "map" (EtaPrim2 "mapFragment" f) x) = error $ "gff: " ++ ppShow f
--getFragmentShader x = error $ "gf: " ++ ppShow x
getFragmentShader x = ((Nothing, getPrim'' $ tyOf x), x)

getPrim (A1 "List" (A2 "Primitive" _ p)) = p
getPrim' (A1 "List" (A2 "Primitive" a _)) = a
getPrim'' (A1 "List" (A2 "Vector" _ (A1 "Maybe" (A1 "SimpleFragment" a)))) = a
getPrim'' x = error $ "getPrim'':" ++ ppShow x

compFrameBuffer = \case
  A1 "DepthImage" a -> IR.ClearImage IR.Depth $ compValue a
  A1 "ColorImage" a -> IR.ClearImage IR.Color $ compValue a
  x -> error $ "compFrameBuffer " ++ ppShow x

compSemantics = map compSemantic . compList

compList (A2 "Cons" a x) = a : compList x
compList (A0 "Nil") = []
compList x = error $ "compList: " ++ ppShow x

compSemantic = \case
  A1 "Depth" _   -> IR.Depth
  A1 "Stencil" _ -> IR.Stencil
  A1 "Color" _   -> IR.Color
  x -> error $ "compSemantic: " ++ ppShow x

compAC x = IR.AccumulationContext Nothing $ map compFrag $ eTuple x

compBlending x = case x of
  A0 "NoBlending" -> IR.NoBlending
  A1 "BlendLogicOp" a -> IR.BlendLogicOp (compLO a)
  A3 "Blend" (ETuple [a,b]) (ETuple [ETuple [c,d],ETuple [e,f]]) (compValue -> IR.VV4F g) -> IR.Blend (compBE a) (compBE b) (compBF c) (compBF d) (compBF e) (compBF f) g
  x -> error $ "compBlending " ++ ppShow x

compBF x = case x of
  A0 "Zero'" -> IR.Zero
  A0 "One" -> IR.One
  A0 "SrcColor" -> IR.SrcColor
  A0 "OneMinusSrcColor" -> IR.OneMinusSrcColor
  A0 "DstColor" -> IR.DstColor
  A0 "OneMinusDstColor" -> IR.OneMinusDstColor
  A0 "SrcAlpha" -> IR.SrcAlpha
  A0 "OneMinusSrcAlpha" -> IR.OneMinusSrcAlpha
  A0 "DstAlpha" -> IR.DstAlpha
  A0 "OneMinusDstAlpha" -> IR.OneMinusDstAlpha
  A0 "ConstantColor" -> IR.ConstantColor
  A0 "OneMinusConstantColor" -> IR.OneMinusConstantColor
  A0 "ConstantAlpha" -> IR.ConstantAlpha
  A0 "OneMinusConstantAlpha" -> IR.OneMinusConstantAlpha
  A0 "SrcAlphaSaturate" -> IR.SrcAlphaSaturate
  x -> error $ "compBF " ++ ppShow x

compBE x = case x of
  A0 "FuncAdd" -> IR.FuncAdd
  A0 "FuncSubtract" -> IR.FuncSubtract
  A0 "FuncReverseSubtract" -> IR.FuncReverseSubtract
  A0 "Min" -> IR.Min
  A0 "Max" -> IR.Max
  x -> error $ "compBE " ++ ppShow x

compLO x = case x of
  A0 "Clear" -> IR.Clear
  A0 "And" -> IR.And
  A0 "AndReverse" -> IR.AndReverse
  A0 "Copy" -> IR.Copy
  A0 "AndInverted" -> IR.AndInverted
  A0 "Noop" -> IR.Noop
  A0 "Xor" -> IR.Xor
  A0 "Or" -> IR.Or
  A0 "Nor" -> IR.Nor
  A0 "Equiv" -> IR.Equiv
  A0 "Invert" -> IR.Invert
  A0 "OrReverse" -> IR.OrReverse
  A0 "CopyInverted" -> IR.CopyInverted
  A0 "OrInverted" -> IR.OrInverted
  A0 "Nand" -> IR.Nand
  A0 "Set" -> IR.Set
  x -> error $ "compLO " ++ ppShow x

compComparisonFunction x = case x of
  A0 "Never" -> IR.Never
  A0 "Less" -> IR.Less
  A0 "Equal" -> IR.Equal
  A0 "Lequal" -> IR.Lequal
  A0 "Greater" -> IR.Greater
  A0 "Notequal" -> IR.Notequal
  A0 "Gequal" -> IR.Gequal
  A0 "Always" -> IR.Always
  x -> error $ "compComparisonFunction " ++ ppShow x

pattern EBool a <- (compBool -> Just a)

compBool x = case x of
  A0 "True" -> Just True
  A0 "False" -> Just False
  x -> Nothing

compFrag x = case x of
  A2 "DepthOp" (compComparisonFunction -> a) (EBool b) -> IR.DepthOp a b
  A2 "ColorOp" (compBlending -> b) (compValue -> v) -> IR.ColorOp b v
  x -> error $ "compFrag " ++ ppShow x

-- todo: remove
toGLSLType msg (TTuple []) = "void"
toGLSLType msg x = showGLSLType msg $ compInputType msg x

-- move to lambdacube-ir?
showGLSLType msg = \case
    IR.Bool  -> "bool"
    IR.Word  -> "uint"
    IR.Int   -> "int"
    IR.Float -> "float"
    IR.V2F   -> "vec2"
    IR.V3F   -> "vec3"
    IR.V4F   -> "vec4"
    IR.V2B   -> "bvec2"
    IR.V3B   -> "bvec3"
    IR.V4B   -> "bvec4"
    IR.V2U   -> "uvec2"
    IR.V3U   -> "uvec3"
    IR.V4U   -> "uvec4"
    IR.V2I   -> "ivec2"
    IR.V3I   -> "ivec3"
    IR.V4I   -> "ivec4"
    IR.M22F  -> "mat2"
    IR.M33F  -> "mat3"
    IR.M44F  -> "mat4"
    IR.M23F  -> "mat2x3"
    IR.M24F  -> "mat2x4"
    IR.M32F  -> "mat3x2"
    IR.M34F  -> "mat3x4"
    IR.M42F  -> "mat4x2"
    IR.M43F  -> "mat4x3"
    IR.FTexture2D -> "sampler2D"
    t -> error $ "toGLSLType: " ++ msg ++ " " ++ show t

supType = isJust . compInputType_

compInputType_ x = case x of
  TFloat          -> Just IR.Float
  TVec 2 TFloat   -> Just IR.V2F
  TVec 3 TFloat   -> Just IR.V3F
  TVec 4 TFloat   -> Just IR.V4F
  TBool           -> Just IR.Bool
  TVec 2 TBool    -> Just IR.V2B
  TVec 3 TBool    -> Just IR.V3B
  TVec 4 TBool    -> Just IR.V4B
  TInt            -> Just IR.Int
  TVec 2 TInt     -> Just IR.V2I
  TVec 3 TInt     -> Just IR.V3I
  TVec 4 TInt     -> Just IR.V4I
  TWord           -> Just IR.Word
  TVec 2 TWord    -> Just IR.V2U
  TVec 3 TWord    -> Just IR.V3U
  TVec 4 TWord    -> Just IR.V4U
  TMat 2 2 TFloat -> Just IR.M22F
  TMat 2 3 TFloat -> Just IR.M23F
  TMat 2 4 TFloat -> Just IR.M24F
  TMat 3 2 TFloat -> Just IR.M32F
  TMat 3 3 TFloat -> Just IR.M33F
  TMat 3 4 TFloat -> Just IR.M34F
  TMat 4 2 TFloat -> Just IR.M42F
  TMat 4 3 TFloat -> Just IR.M43F
  TMat 4 4 TFloat -> Just IR.M44F
  -- hack
  A1 "HList" (compList -> [x]) -> compInputType_ x
  _ -> Nothing

compInputType msg x = fromMaybe (error $ "compInputType " ++ msg ++ " " ++ ppShow x) $ compInputType_ x

is234 = (`elem` [2,3,4])

compInputType'' attrs@(A1 "Attribute" (EString s)) | A1 "HList" (compList -> [ty]) <- tyOf attrs = [(s, compInputType "cit" ty)]
compInputType'' attrs = map compAttribute $ eTuple attrs

compAttribute = \case
  x@(A1 "Attribute" (EString s)) -> (s, compInputType "compAttr" $ tyOf x)
  x -> error $ "compAttribute " ++ ppShow x

compAttributeValue :: ExpTV -> [(IR.InputType,IR.ArrayValue)]
compAttributeValue x = checkLength $ map go $ eTuple x
  where
    emptyArray t | t `elem` [IR.Float,IR.V2F,IR.V3F,IR.V4F,IR.M22F,IR.M23F,IR.M24F,IR.M32F,IR.M33F,IR.M34F,IR.M42F,IR.M43F,IR.M44F] = IR.VFloatArray mempty
    emptyArray t | t `elem` [IR.Int,IR.V2I,IR.V3I,IR.V4I] = IR.VIntArray mempty
    emptyArray t | t `elem` [IR.Word,IR.V2U,IR.V3U,IR.V4U] = IR.VWordArray mempty
    emptyArray t | t `elem` [IR.Bool,IR.V2B,IR.V3B,IR.V4B] = IR.VBoolArray mempty
    emptyArray _ = error "compAttributeValue - emptyArray"

    flatten IR.Float (IR.VFloat x) (IR.VFloatArray l) = IR.VFloatArray $ pure x <> l
    flatten IR.V2F (IR.VV2F (IR.V2 x y)) (IR.VFloatArray l) = IR.VFloatArray $ pure x <> pure y <> l
    flatten IR.V3F (IR.VV3F (IR.V3 x y z)) (IR.VFloatArray l) = IR.VFloatArray $ pure x <> pure y <> pure z <> l
    flatten IR.V4F (IR.VV4F (IR.V4 x y z w)) (IR.VFloatArray l) = IR.VFloatArray $ pure x <> pure y <> pure z <> pure w <> l
    flatten _ _ _ = error "compAttributeValue"

    checkLength l@((a,_):_) = case all (\(i,_) -> i == a) l of
      True  -> snd $ unzip l
      False -> error "FetchArrays array length mismatch!"

    go a = (length values,(t,foldr (flatten t) (emptyArray t) values))
      where (A1 "List" (compInputType "compAV" -> t)) = tyOf a
            values = map compValue $ compList a

compFetchPrimitive x = case x of
  A0 "Point" -> IR.Points
  A0 "Line" -> IR.Lines
  A0 "Triangle" -> IR.Triangles
  A0 "LineAdjacency" -> IR.LinesAdjacency
  A0 "TriangleAdjacency" -> IR.TrianglesAdjacency
  x -> error $ "compFetchPrimitive " ++ ppShow x

compValue x = case x of
  EFloat a -> IR.VFloat $ realToFrac a
  EInt a -> IR.VInt $ fromIntegral a
  A2 "V2" (EFloat a) (EFloat b) -> IR.VV2F $ IR.V2 (realToFrac a) (realToFrac b)
  A3 "V3" (EFloat a) (EFloat b) (EFloat c) -> IR.VV3F $ IR.V3 (realToFrac a) (realToFrac b) (realToFrac c)
  A4 "V4" (EFloat a) (EFloat b) (EFloat c) (EFloat d) -> IR.VV4F $ IR.V4 (realToFrac a) (realToFrac b) (realToFrac c) (realToFrac d)
  A2 "V2" (EBool a) (EBool b) -> IR.VV2B $ IR.V2 a b
  A3 "V3" (EBool a) (EBool b) (EBool c) -> IR.VV3B $ IR.V3 a b c
  A4 "V4" (EBool a) (EBool b) (EBool c) (EBool d) -> IR.VV4B $ IR.V4 a b c d
  x -> error $ "compValue " ++ ppShow x

compRC x = case x of
  A3 "PointCtx" a (EFloat b) c -> IR.PointCtx (compPS a) (realToFrac b) (compPSCO c)
  A2 "LineCtx" (EFloat a) b -> IR.LineCtx (realToFrac a) (compPV b)
  A4 "TriangleCtx" a b c d -> IR.TriangleCtx (compCM a) (compPM b) (compPO c) (compPV d)
  x -> error $ "compRC " ++ ppShow x

compRC' x = case x of
  A3 "PointCtx" a _ _ -> compPS' a
  A4 "TriangleCtx" _ b _ _ -> compPM' b
  x -> Nothing

compPSCO x = case x of
  A0 "LowerLeft" -> IR.LowerLeft
  A0 "UpperLeft" -> IR.UpperLeft
  x -> error $ "compPSCO " ++ ppShow x

compCM x = case x of
  A0 "CullNone" -> IR.CullNone
  A0 "CullFront" -> IR.CullFront IR.CCW
  A0 "CullBack" -> IR.CullBack IR.CCW
  x -> error $ "compCM " ++ ppShow x

compPM x = case x of
  A0 "PolygonFill" -> IR.PolygonFill
  A1 "PolygonLine" (EFloat a) -> IR.PolygonLine $ realToFrac a
  A1 "PolygonPoint" a  -> IR.PolygonPoint $ compPS a
  x -> error $ "compPM " ++ ppShow x

compPM' x = case x of
  A1 "PolygonPoint" a  -> compPS' a
  x -> Nothing

compPS x = case x of
  A1 "PointSize" (EFloat a) -> IR.PointSize $ realToFrac a
  A1 "ProgramPointSize" _ -> IR.ProgramPointSize
  x -> error $ "compPS " ++ ppShow x

compPS' x = case x of
  A1 "ProgramPointSize" x -> Just x
  x -> Nothing

compPO x = case x of
  A2 "Offset" (EFloat a) (EFloat b) -> IR.Offset (realToFrac a) (realToFrac b)
  A0 "NoOffset" -> IR.NoOffset
  x -> error $ "compPO " ++ ppShow x

compPV x = case x of
    A0 "FirstVertex" -> IR.FirstVertex
    A0 "LastVertex" -> IR.LastVertex
    x -> error $ "compPV " ++ ppShow x

--------------------------------------------------------------- GLSL generation

genGLSLs backend
    rp                  -- program point size
    ints                -- interpolations
    (vert, tvert)       -- vertex shader
    (frag, tfrag)       -- fragment shader
    ffilter             -- fragment filter
    = ( -- vertex input
        vertInNames

      , -- uniforms
        vertUniforms <> fragUniforms

      , -- vertex shader code
        shader $
           uniformDecls vertUniforms
        <> [shaderDecl (caseWO "attribute" "in") (text t) (text n) | (n, t) <- zip vertInNames vertIns]
        <> vertOutDecls "out"
        <> vertFuncs
        <> [mainFunc $
               [shaderLet (text n) x | (n, x) <- zip vertOutNamesWithPosition vertGLSL]
            <> [shaderLet "gl_PointSize" x | Just x <- [ptGLSL]]
           ]

      , -- fragment shader code
        shader $
           uniformDecls fragUniforms
        <> vertOutDecls "in"
--        <> [shaderDecl "out" (toGLSLType "4" tfrag) fragColorName | Just{} <- [fragGLSL], backend == OpenGL33]
        <> [shaderDecl "out" (text t) (text n) | (n, t) <- zip fragOutNames fragOuts, backend == OpenGL33]
        <> fragFuncs
        <> [mainFunc $
               [shaderStmt $ "if" <+> parens ("!" <> parens filt) <+> "discard" | Just filt <- [filtGLSL]]
            <> [shaderLet (text n) x | (n, x) <- zip fragOutNames fragGLSL ]
           ]
      )
  where
    uniformDecls us = [shaderDecl "uniform" (text $ showGLSLType "2" t) (text n) | (n, (_, t)) <- Map.toList us]
    vertOutDecls io = [shaderDecl (caseWO "varying" $ text i <+> io) (text t) (text n) | (n, (i, t)) <- zip vertOutNames vertOuts]

    fragOutNames = case length frags of
        0 -> []
        1 -> [fragColorName]

    (vertIns, verts) = case vert of
        Just (etaReds -> Just (xs, ys)) -> (toGLSLType "3" <$> xs, eTuple ys)
        Nothing -> ([toGLSLType "4" tvert], [mkTVar 0 tvert])

    (fragOuts, frags) = case frag of
        Just (etaReds -> Just (xs, eTuple -> ys)) -> (toGLSLType "3" . tyOf <$> ys, ys)
        Nothing -> ([toGLSLType "4" tfrag], [mkTVar 0 tfrag])

    (((vertGLSL, ptGLSL), (vertUniforms, vertFuncs)), ((filtGLSL, fragGLSL), (fragUniforms, fragFuncs))) = flip evalState shaderNames $ do
        ((g1, (us1, verts)), (g2, (us2, frags))) <- (,)
            <$> runWriterT ((,)
                <$> traverse (genGLSL' "1" vertInNames . (,) vertIns) verts
                <*> traverse (genGLSL' "2" vertOutNamesWithPosition . reds) rp)
            <*> runWriterT ((,)
                <$> traverse (genGLSL' "3" vertOutNames . red) ffilter
                <*> traverse (genGLSL' "4" vertOutNames . (,) (snd <$> vertOuts)) frags)
        (,) <$> ((,) g1 <$> fixFuncs us1 mempty [] verts) <*> ((,) g2 <$> fixFuncs us2 mempty [] frags)

    fixFuncs :: Uniforms -> Set.Set SName -> [Doc] -> Map.Map SName (ExpTV, ExpTV, [ExpTV]) -> State [SName] (Uniforms, [Doc])
    fixFuncs us ns fsb (Map.toList -> fsa)
        | null fsa = return (us, fsb)
        | otherwise = do
            (unzip -> (defs, unzip -> (us', fs'))) <- forM fsa $ \(fn, (def, ty, tys)) ->
                runWriterT $ genGLSL (reverse $ take (length tys) funArgs) $ removeLams (length tys) def
            let fsb' = zipWith combine fsa defs <> fsb
                ns' = ns <> Set.fromList (map fst fsa)
            fixFuncs (us <> mconcat us') ns' fsb' (mconcat fs' `Map.difference` Map.fromSet (const undefined) ns')
      where
        combine (fn, (_, ty, tys)) def =
            shaderFunc' (toGLSLType "44" ty) (text fn)
                        (zipWith (<+>) (map (toGLSLType "45") tys) (map text funArgs))
                        def

    funArgs      = map (("z" ++) . show) [0..]
    shaderNames  = map (("s" ++) . show)  [0..]
    vertInNames  = map (("vi" ++) . show) [1..length vertIns]
    vertOutNames = map (("vo" ++) . show) [1..length vertOuts]
    vertOutNamesWithPosition = "gl_Position": vertOutNames

    red (etaReds -> Just (ps, o)) = (ps, o)
    red x = error $ "red: " ++ ppShow x
    reds (etaReds -> Just (ps, o)) = (ps, o)
    reds x = error $ "red: " ++ ppShow x
    genGLSL' err vertOuts (ps, o)
        | length ps == length vertOuts = genGLSL (reverse vertOuts) o
        | otherwise = error $ "makeSubst illegal input " ++ err ++ "  " ++ show ps ++ "\n" ++ show vertOuts

    noUnit TTuple0 = False
    noUnit _ = True

    vertOuts = zipWith go (eTuple ints) $ tail verts
      where
        go (A0 n) e = (interpName n, toGLSLType "3" $ tyOf e)

    interpName "Smooth" = "smooth"
    interpName "Flat"   = "flat"
    interpName "NoPerspective" = "noperspective"

    shader xs = vcat $
         ["#version" <+> caseWO "100" "330 core"]
      <> ["precision highp float;" | backend == WebGL1]
      <> ["precision highp int;"   | backend == WebGL1]
      <> [shaderFunc "vec4" "texture2D" ["sampler2D s", "vec2 uv"] [shaderReturn "texture(s,uv)"] | backend == OpenGL33]
      <> xs

    shaderFunc' ot n [] b = shaderLet (ot <+> n) b
    shaderFunc' ot n ps b = shaderFunc ot n ps [shaderReturn b]

    shaderFunc outtype name pars body = nest 4 (outtype <+> name <> tupled pars <+> "{" <$$> vcat body) <$$> "}"
    mainFunc xs = shaderFunc "void" "main" [] xs
    shaderStmt xs = nest 4 $ xs <> ";"
    shaderReturn xs = shaderStmt $ "return" <+> xs
    shaderLet a b = shaderStmt $ a <+> "=" </> b
    shaderDecl a b c = shaderStmt $ a <+> b <+> c

    fragColorName = caseWO "gl_FragColor" "f0"

    caseWO w o = case backend of WebGL1 -> w; OpenGL33 -> o

data Uniform
    = UUniform
    | UTexture2DSlot
    | UTexture2D Integer Integer ExpTV
    deriving (Show)

type Uniforms = Map String (Uniform, IR.InputType)

tellUniform x = tell (x, mempty)

simpleExpr = \case
    Con cn xs -> case cn of
        "Uniform" -> True
        _ -> False
    _ -> False

genGLSL :: [SName] -> ExpTV -> WriterT (Uniforms, Map.Map SName (ExpTV, ExpTV, [ExpTV])) (State [String]) Doc
genGLSL dns e = case e of

  ELit a -> pure $ text $ show a
  Var i _ -> pure $ text $ dns !! i

  Func fn def ty xs | not (simpleExpr def) -> tell (mempty, Map.singleton fn (def, ty, map tyOf xs)) >> call fn xs

  Con cn xs -> case cn of
    "primIfThenElse" -> case xs of [a, b, c] -> hsep <$> sequence [gen a, pure "?", gen b, pure ":", gen c]

    "swizzscalar" -> case xs of [e, getSwizzChar -> Just s] -> showSwizzProj [s] <$> gen e
    "swizzvector" -> case xs of [e, Con ((`elem` ["V2","V3","V4"]) -> True) (traverse getSwizzChar -> Just s)] -> showSwizzProj s <$> gen e

    "Uniform" -> case xs of
        [EString s] -> do
            tellUniform $ Map.singleton s $ (,) UUniform $ compInputType "unif" $ tyOf e
            pure $ text s
    "Sampler" -> case xs of
        [_, _, A1 "Texture2DSlot" (EString s)] -> do
            tellUniform $ Map.singleton s $ (,) UTexture2DSlot IR.FTexture2D{-compInputType $ tyOf e  -- TODO-}
            pure $ text s
        [_, _, A2 "Texture2D" (A2 "V2" (EInt w) (EInt h)) b] -> do
            s <- newName
            tellUniform $ Map.singleton s $ (,) (UTexture2D w h b) IR.FTexture2D
            pure $ text s

    'P':'r':'i':'m':n | n'@(_:_) <- trName (dropS n) -> call n' xs
     where
      ifType p a b = if all (p . tyOf) xs then a else b

      dropS n
        | last n == 'S' && init n `elem` ["Add", "Sub", "Div", "Mod", "BAnd", "BOr", "BXor", "BShiftL", "BShiftR", "Min", "Max", "Clamp", "Mix", "Step", "SmoothStep"] = init n
        | otherwise = n

      trName = \case

        -- Arithmetic Functions
        "Add"               -> "+"
        "Sub"               -> "-"
        "Neg"               -> "-_"
        "Mul"               -> ifType isMatrix "matrixCompMult" "*"
        "MulS"              -> "*"
        "Div"               -> "/"
        "Mod"               -> ifType isIntegral "%" "mod"

        -- Bit-wise Functions
        "BAnd"              -> "&"
        "BOr"               -> "|"
        "BXor"              -> "^"
        "BNot"              -> "~_"
        "BShiftL"           -> "<<"
        "BShiftR"           -> ">>"

        -- Logic Functions
        "And"               -> "&&"
        "Or"                -> "||"
        "Xor"               -> "^"
        "Not"               -> ifType isScalar "!_" "not"

        -- Integer/Float Conversion Functions
        "FloatBitsToInt"    -> "floatBitsToInt"
        "FloatBitsToUInt"   -> "floatBitsToUint"
        "IntBitsToFloat"    -> "intBitsToFloat"
        "UIntBitsToFloat"   -> "uintBitsToFloat"

        -- Matrix Functions
        "OuterProduct"      -> "outerProduct"
        "MulMatVec"         -> "*"
        "MulVecMat"         -> "*"
        "MulMatMat"         -> "*"

        -- Fragment Processing Functions
        "DFdx"              -> "dFdx"
        "DFdy"              -> "dFdy"

        -- Vector and Scalar Relational Functions
        "LessThan"          -> ifType isScalarNum "<"  "lessThan"
        "LessThanEqual"     -> ifType isScalarNum "<=" "lessThanEqual"
        "GreaterThan"       -> ifType isScalarNum ">"  "greaterThan"
        "GreaterThanEqual"  -> ifType isScalarNum ">=" "greaterThanEqual"
        "Equal"             -> "=="
        "EqualV"            -> ifType isScalar "==" "equal"
        "NotEqual"          -> "!="
        "NotEqualV"         -> ifType isScalar "!=" "notEqual"

        -- Angle and Trigonometry Functions
        "ATan2"             -> "atan"
        -- Exponential Functions
        "InvSqrt"           -> "inversesqrt"
        -- Common Functions
        "RoundEven"         -> "roundEven"
        "ModF"              -> error "PrimModF is not implemented yet!" -- TODO
        "MixB"              -> "mix"

        n | n `elem`
            -- Logic Functions
            [ "Any", "All"
            -- Angle and Trigonometry Functions
            , "ACos", "ACosH", "ASin", "ASinH", "ATan", "ATanH", "Cos", "CosH", "Degrees", "Radians", "Sin", "SinH", "Tan", "TanH"
            -- Exponential Functions
            , "Pow", "Exp", "Exp2", "Log2", "Sqrt"
            -- Common Functions
            , "IsNan", "IsInf", "Abs", "Sign", "Floor", "Trunc", "Round", "Ceil", "Fract", "Min", "Max", "Mix", "Step", "SmoothStep"
            -- Geometric Functions
            , "Length", "Distance", "Dot", "Cross", "Normalize", "FaceForward", "Reflect", "Refract"
            -- Matrix Functions
            , "Transpose", "Determinant", "Inverse"
            -- Fragment Processing Functions
            , "FWidth"
            -- Noise Functions
            , "Noise1", "Noise2", "Noise3", "Noise4"
            ] -> map toLower n

        _ -> ""

    n | n@(_:_) <- trName n -> call n xs
      where
        trName n = case n of
            "texture2D" -> "texture2D"

            "True"  -> "true"
            "False" -> "false"

            "M22F" -> "mat2"
            "M33F" -> "mat3"
            "M44F" -> "mat4"

            "==" -> "=="

            n | n `elem` ["primNegateWord", "primNegateInt", "primNegateFloat"] -> "-_"
            n | n `elem` ["V2", "V3", "V4"] -> toGLSLType (n ++ " " ++ show (length xs)) $ tyOf e
            _ -> ""

    -- not supported
    n | n `elem` ["primIntToWord", "primIntToFloat", "primCompareInt", "primCompareWord", "primCompareFloat"] -> error $ "WebGL 1 does not support: " ++ ppShow e
    n | n `elem` ["M23F", "M24F", "M32F", "M34F", "M42F", "M43F"] -> error "WebGL 1 does not support matrices with this dimension"
    x -> error $ "GLSL codegen - unsupported function: " ++ ppShow x

  x -> error $ "GLSL codegen - unsupported expression: " ++ ppShow x
  where
    newName = gets head <* modify tail

    call f xs = case f of
      (c:_) | isAlpha c -> case xs of
            [] -> return $ text f
            xs -> (text f </>) . tupled <$> mapM gen xs
      [op, '_'] -> case xs of [a] -> (text [op] <+>) . parens <$> gen a
      o         -> case xs of [a, b] -> hsep <$> sequence [parens <$> gen a, pure $ text o, parens <$> gen b]

    gen = genGLSL dns

    isMatrix :: Ty -> Bool
    isMatrix TMat{} = True
    isMatrix _ = False

    isIntegral :: Ty -> Bool
    isIntegral TWord = True
    isIntegral TInt = True
    isIntegral (TVec _ TWord) = True
    isIntegral (TVec _ TInt) = True
    isIntegral _ = False

    isScalarNum :: Ty -> Bool
    isScalarNum = \case
        TInt -> True
        TWord -> True
        TFloat -> True
        _ -> False

    isScalar :: Ty -> Bool
    isScalar TBool = True
    isScalar x = isScalarNum x

    getSwizzChar = \case
        A0 "Sx" -> Just 'x'
        A0 "Sy" -> Just 'y'
        A0 "Sz" -> Just 'z'
        A0 "Sw" -> Just 'w'
        _ -> Nothing

    showSwizzProj x a = parens a <> "." <> text x

--------------------------------------------------------------------------------

-- expression + type + type of local variables
data ExpTV = ExpTV_ Exp Exp [Exp]
  deriving (Show, Eq)

pattern ExpTV a b c <- ExpTV_ a b c where ExpTV a b c = ExpTV_ (a) (unLab' b) c

type Ty = ExpTV

tyOf :: ExpTV -> Ty
tyOf (ExpTV _ t vs) = t .@ vs

expOf (ExpTV x _ _) = x

mapVal f (ExpTV a b c) = ExpTV (f a) b c

toExp :: ExpType -> ExpTV
toExp (x, xt) = ExpTV x xt []

pattern Pi h a b    <- (mkPi . mapVal unLab'  -> Just (h, a, b))
pattern Lam h a b   <- (mkLam . mapVal unFunc' -> Just (h, a, b))
pattern Con h b     <- (mkCon . mapVal unLab' -> Just (h, b))
pattern App a b     <- (mkApp . mapVal unLab' -> Just (a, b))
pattern Var a b     <- (mkVar . mapVal unLab' -> Just (a, b))
pattern ELit l      <- ExpTV (I.ELit l) _ _
pattern TType       <- ExpTV (unLab' -> I.TType) _ _
pattern Func fn def ty xs <- (mkFunc -> Just (fn, def, ty, xs))

pattern EString s <- ELit (LString s)
pattern EFloat s  <- ELit (LFloat s)
pattern EInt s    <- ELit (LInt s)

t .@ vs = ExpTV t I.TType vs
infix 1 .@

mkVar (ExpTV (I.Var i) t vs) = Just (i, t .@ vs)
mkVar _ = Nothing

mkPi (ExpTV (I.Pi b x y) _ vs) = Just (b, x .@ vs, y .@ addToEnv x vs)
mkPi _ = Nothing

mkLam (ExpTV (I.Lam y) (I.Pi b x yt) vs) = Just (b, x .@ vs, ExpTV y yt $ addToEnv x vs)
mkLam _ = Nothing

mkCon (ExpTV (I.Con s n xs) et vs) = Just (untick $ show s, chain vs (conType et s) $ mkConPars n et ++ xs)
mkCon (ExpTV (TyCon s xs) et vs) = Just (untick $ show s, chain vs (nType s) xs)
mkCon (ExpTV (Neut (I.Fun s i (reverse -> xs) def)) et vs) = Just (untick $ show s, chain vs (nType s) xs)
mkCon (ExpTV (CaseFun s xs n) et vs) = Just (untick $ show s, chain vs (nType s) $ makeCaseFunPars' (mkEnv vs) n ++ xs ++ [Neut n])
mkCon (ExpTV (TyCaseFun s [m, t, f] n) et vs) = Just (untick $ show s, chain vs (nType s) [m, t, Neut n, f])
mkCon _ = Nothing

mkApp (ExpTV (Neut (I.App_ a b)) et vs) = Just (ExpTV (Neut a) t vs, head $ chain vs t [b])
  where t = neutType' (mkEnv vs) a
mkApp _ = Nothing

mkFunc r@(ExpTV (I.Func (show -> n) def nt xs) ty vs) | all (supType . tyOf) (r: xs') && n `notElem` ["typeAnn"] && all validChar n
    = Just (untick n +++ intercalate "_" (filter (/="TT") $ map (filter isAlphaNum . removeEscs . ppShow) hs), toExp (foldl app_ def hs, foldl appTy nt hs), tyOf r, xs')
  where
    a +++ [] = a
    a +++ b = a ++ "_" ++ b
    (map (expOf . snd) -> hs, map snd -> xs') = span ((==Hidden) . fst) $ chain' vs nt $ reverse xs
    validChar = isAlphaNum
mkFunc _ = Nothing

chain vs t@(I.Pi Hidden at y) (a: as) = chain vs (appTy t a) as
chain vs t xs = map snd $ chain' vs t xs

chain' vs t [] = []
chain' vs t@(I.Pi b at y) (a: as) = (b, ExpTV a at vs): chain' vs (appTy t a) as
chain' vs t _ = error $ "chain: " ++ show t

mkTVar i (ExpTV t _ vs) = ExpTV (I.Var i) t vs

unLab' (FL x) = unLab' x
unLab' (LabelEnd x) = unLab' x
unLab' x = x

unFunc' (FL x) = unFunc' x   -- todo: remove?
unFunc' (UFL x) = unFunc' x
unFunc' (LabelEnd x) = unFunc' x
unFunc' x = x

instance Subst Exp ExpTV where
    subst i0 x (ExpTV a at vs) = ExpTV (subst i0 x a) (subst i0 x at) (zipWith (\i -> subst (i0+i) $ up i x{-todo: review-}) [1..] vs)

addToEnv x xs = x: xs
mkEnv xs = {-trace_ ("mk " ++ show (length xs)) $ -} zipWith up [1..] xs

instance Up ExpTV where
    up_ n i (ExpTV x xt vs) = error "up @ExpTV" --ExpTV (up_ n i x) (up_ n i xt) (up_ n i <$> vs)
    used i (ExpTV x xt vs) = used i x || used i xt -- || any (used i) vs{-?-}
    fold = error "fold @ExpTV"
    maxDB_ (ExpTV a b cs) = maxDB_ a <> maxDB_ b -- <> foldMap maxDB_ cs{-?-}
    closedExp (ExpTV a b cs) = ExpTV (closedExp a) (closedExp b) cs

instance PShow ExpTV where
    pShowPrec p (ExpTV x t _) = pShowPrec p (x, t)

isSampler (TyCon n _) = show n == "'Sampler"
isSampler _ = False

untick ('\'': s) = s
untick s = s

-------------------------------------------------------------------------------- ExpTV conversion -- TODO: remove

removeLams 0 x = x
removeLams i (ELam _ x) = removeLams (i-1) x
removeLams i (Lam Hidden _ x) = removeLams i x

etaReds (ELam _ (App (down 0 -> Just f) (EVar 0))) = etaReds f
etaReds (ELam _ (hlistLam -> x@Just{})) = x
etaReds (ELam p i) = Just ([p], i)
etaReds x = Nothing

hlistLam :: ExpTV -> Maybe ([ExpTV], ExpTV)
hlistLam (A3 "hlistNilCase" _ (down 0 -> Just x) (EVar 0)) = Just ([], x)
hlistLam (A3 "hlistConsCase" _ (down 0 -> Just (getPats 2 -> Just ([p, px], x))) (EVar 0)) = first (p:) <$> hlistLam x
hlistLam _ = Nothing

getPats 0 e = Just ([], e)
getPats i (ELam p e) = first (p:) <$> getPats (i-1) e
getPats i (Lam Hidden p (down 0 -> Just e)) = getPats i e
getPats i x = error $ "getPats: " ++ show i ++ " " ++ ppShow x

pattern EtaPrim1 s <- (getEtaPrim -> Just (s, []))
pattern EtaPrim2 s x <- (getEtaPrim -> Just (s, [x]))
pattern EtaPrim3 s x1 x2 <- (getEtaPrim -> Just (s, [x1, x2]))
pattern EtaPrim4 s x1 x2 x3 <- (getEtaPrim -> Just (s, [x1, x2, x3]))
pattern EtaPrim5 s x1 x2 x3 x4 <- (getEtaPrim -> Just (s, [x1, x2, x3, x4]))
pattern EtaPrim2_2 s <- (getEtaPrim2 -> Just (s, []))

getEtaPrim (ELam _ (Con s (initLast -> Just (traverse (down 0) -> Just xs, EVar 0)))) = Just (s, xs)
getEtaPrim _ = Nothing

getEtaPrim2 (ELam _ (ELam _ (Con s (initLast -> Just (initLast -> Just (traverse (down 0) -> Just (traverse (down 0) -> Just xs), EVar 0), EVar 0))))) = Just (s, xs)
getEtaPrim2 _ = Nothing

initLast [] = Nothing
initLast xs = Just (init xs, last xs)

-------------

pattern EVar n <- Var n _
pattern ELam t b <- Lam Visible t b

pattern A0 n <- Con n []
pattern A1 n a <- Con n [a]
pattern A2 n a b <- Con n [a, b]
pattern A3 n a b c <- Con n [a, b, c]
pattern A4 n a b c d <- Con n [a, b, c, d]
pattern A5 n a b c d e <- Con n [a, b, c, d, e]

pattern TTuple0     <- A1 "HList" (A0 "Nil")
pattern TBool       <- A0 "Bool"
pattern TWord       <- A0 "Word"
pattern TInt        <- A0 "Int"
pattern TNat        <- A0 "Nat"
pattern TFloat      <- A0 "Float"
pattern TString     <- A0 "String"
pattern TVec n a    <- A2 "VecS" a (Nat n)
pattern TMat i j a  <- A3 "Mat" (Nat i) (Nat j) a

pattern Nat n <- (fromNat -> Just n)

fromNat :: ExpTV -> Maybe Int
fromNat (A0 "Zero") = Just 0
fromNat (A1 "Succ" n) = (1 +) <$> fromNat n
fromNat _ = Nothing

pattern TTuple xs <- ETuple xs
pattern ETuple xs <- (getTuple -> Just xs)

eTuple (ETuple l) = l
eTuple x | A1 "HList" _ <- tyOf x = error $ "eTuple: " ++ ppShow x --[x]
eTuple x = [x]

getTuple (A1 "HList" l) = Just $ compList l
getTuple (A0 "HNil") = Just []
getTuple (A2 "HCons" x (getTuple -> Just xs)) = Just (x: xs)
getTuple _ = Nothing

