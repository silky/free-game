{-# LANGUAGE BangPatterns #-}
module FreeGame.Internal.GLFW where
import Control.Concurrent
import Control.Bool
import Control.Applicative
import Control.Monad.IO.Class
import Data.Color
import Data.IORef
import FreeGame.Types
import Graphics.Rendering.OpenGL.GL.StateVar
import Graphics.Rendering.OpenGL.Raw.ARB.Compatibility
import Linear
import qualified Graphics.Rendering.OpenGL.GL as GL
import qualified Graphics.UI.GLFW as GLFW
import Unsafe.Coerce
import qualified Data.Vector.Storable as V
import qualified Data.Vector.Storable.Mutable as MV
import Codec.Picture
import Codec.Picture.RGBA8

data System = System
    { refFrameCounter :: IORef Int
    , refFPS :: IORef Int
    , theFPS :: IORef Int
    , currentFPS :: IORef Int
    , theRegion :: BoundingBox Double
    , theWindow :: GLFW.Window
    }

type Texture = (GL.TextureObject, Double, Double)

runVertices :: MonadIO m => [V2 Double] -> m ()
runVertices = liftIO . mapM_ (GL.vertex . mkVertex2)
{-# INLINE runVertices #-}

preservingMatrix' :: MonadIO m => m a -> m a
preservingMatrix' m = do
    liftIO glPushMatrix
    r <- m
    liftIO glPopMatrix
    return r
{-# INLINE preservingMatrix' #-}

drawTexture :: Texture -> IO ()
drawTexture (tex, !w, !h) = drawTextureAt tex (V2 (-w) (-h)) (V2 w (-h)) (V2 w h) (V2 (-w) h)
{-# INLINE drawTexture #-}

drawTextureAt :: GL.TextureObject -> V2 Double -> V2 Double -> V2 Double -> V2 Double -> IO ()
drawTextureAt tex a b c d = do
    GL.texture GL.Texture2D $= GL.Enabled
    GL.textureFilter GL.Texture2D $= ((GL.Nearest, Nothing), GL.Nearest)
    GL.textureBinding GL.Texture2D $= Just tex
    GL.unsafeRenderPrimitive GL.TriangleStrip $ do
        GL.texCoord $ GL.TexCoord2 (0 :: GL.GLdouble) 0
        GL.vertex $ mkVertex2 a
        GL.texCoord $ GL.TexCoord2 (1 :: GL.GLdouble) 0
        GL.vertex $ mkVertex2 b
        GL.texCoord $ GL.TexCoord2 (0 :: GL.GLdouble) 1
        GL.vertex $ mkVertex2 d
        GL.texCoord $ GL.TexCoord2 (1 :: GL.GLdouble) 1
        GL.vertex $ mkVertex2 c
    GL.texture GL.Texture2D $= GL.Disabled

mkVertex2 :: V2 Double -> GL.Vertex2 GL.GLdouble
{-# INLINE mkVertex2 #-}
mkVertex2 = unsafeCoerce

gf :: Float -> GL.GLfloat
{-# INLINE gf #-}
gf = unsafeCoerce

gd :: Double -> GL.GLdouble
{-# INLINE gd #-}
gd = unsafeCoerce

gsizei :: Int -> GL.GLsizei
{-# INLINE gsizei #-}
gsizei = unsafeCoerce

translate :: V2 Double -> IO a -> IO a
translate (V2 tx ty) m = preservingMatrix' $ GL.translate (GL.Vector3 (gd tx) (gd ty) 0) >> m

rotateD :: Double -> IO a -> IO a
rotateD theta m = preservingMatrix' $ GL.rotate (gd (-theta)) (GL.Vector3 0 0 1) >> m

scale :: V2 Double -> IO a -> IO a
scale (V2 sx sy) m = preservingMatrix' $ GL.scale (gd sx) (gd sy) 1 >> m

circle :: Double -> IO ()
circle r = do
    let s = 2 * pi / 64
    GL.renderPrimitive GL.Polygon $ runVertices [V2 (cos t * r) (sin t * r) | t <- [0,s..2 * pi]]

circleOutline :: Double -> IO ()
circleOutline r = do
    let s = 2 * pi / 64
    GL.renderPrimitive GL.LineLoop $ runVertices [V2 (cos t * r) (sin t * r) | t <- [0,s..2 * pi]]

color :: Color -> IO a -> IO a
color col m = do
    oldColor <- liftIO $ get GL.currentColor
    liftIO $ GL.currentColor $= unsafeCoerce col
    res <- m
    liftIO $ GL.currentColor $= oldColor
    return res

polygon :: [V2 Double] -> IO ()
polygon path = GL.renderPrimitive GL.Polygon $ runVertices path

polygonOutline :: [V2 Double] -> IO ()
polygonOutline path = GL.renderPrimitive GL.LineLoop $ runVertices path

line :: [V2 Double] -> IO ()
line path = GL.renderPrimitive GL.LineStrip $ runVertices path

thickness :: Float -> IO a -> IO a
thickness t m = do
    oldWidth <- liftIO $ get GL.lineWidth
    liftIO $ GL.lineWidth $= gf t
    res <- m
    liftIO $ GL.lineWidth $= oldWidth
    return res

installTexture :: Image PixelRGBA8 -> IO Texture
installTexture (Image w h v) = do
    [tex] <- GL.genObjectNames 1
    GL.textureBinding GL.Texture2D GL.$= Just tex
    let siz = GL.TextureSize2D (gsizei w) (gsizei h)
    V.unsafeWith v
        $ GL.texImage2D GL.Texture2D GL.NoProxy 0 GL.RGBA8 siz 0
        . GL.PixelData GL.ABGR GL.UnsignedInt8888
    return (tex, fromIntegral w / 2, fromIntegral h / 2)

releaseTexture :: Texture -> IO ()
releaseTexture (tex, _, _) = GL.deleteObjectNames [tex]

beginFrame :: System -> IO ()
beginFrame sys = do
    GL.matrixMode $= GL.Projection
    GL.loadIdentity
    let BoundingBox wl wt wr wb = fmap realToFrac (theRegion sys)
    GL.ortho wl wr wb wt 0 (-100)
    GL.matrixMode $= GL.Modelview 0
    GL.clear [GL.ColorBuffer]

endFrame :: System -> IO Bool
endFrame sys = do
    GLFW.swapBuffers $ theWindow sys
    GLFW.pollEvents
    Just t <- GLFW.getTime
    n <- readIORef (refFrameCounter sys)
    fps <- readIORef (theFPS sys)
    threadDelay $ max 0 $ floor $ (1000000 *) $ fromIntegral n / fromIntegral fps - t
    if t > 1
        then GLFW.setTime 0 >> writeIORef (currentFPS sys) n >> writeIORef (refFrameCounter sys) 0
        else writeIORef (refFrameCounter sys) (succ n)
    GLFW.windowShouldClose (theWindow sys)

withGLFW :: WindowMode -> BoundingBox Double -> (System -> IO a) -> IO a
withGLFW full bbox@(BoundingBox x0 y0 x1 y1) m = do
    let title = "free-game"
        ww = floor $ x1 - x0
        wh = floor $ y1 - y0
    () <- unlessM GLFW.init (fail "Failed to initialize")

    mon <- case full of
        FullScreen -> GLFW.getPrimaryMonitor
        Windowed -> return Nothing

    GLFW.windowHint (GLFW.WindowHint'Resizable False)
    Just win <- GLFW.createWindow ww wh title mon Nothing
    GLFW.makeContextCurrent (Just win)
    GL.lineSmooth $= GL.Enabled
    GL.blend      $= GL.Enabled
    GL.blendFunc  $= (GL.SrcAlpha, GL.OneMinusSrcAlpha)
    GL.shadeModel $= GL.Flat
    GL.textureFunction $= GL.Combine

    GLFW.swapInterval 1
    GL.clearColor $= GL.Color4 1 1 1 1

    sys <- System
        <$> newIORef 0
        <*> newIORef 0
        <*> newIORef 60
        <*> newIORef 60
        <*> pure bbox
        <*> pure win

    res <- m sys

    GLFW.destroyWindow win
    GLFW.terminate
    return res

screenshotFlipped :: System -> IO (Image PixelRGBA8)
screenshotFlipped sys = do
    let BoundingBox x0 y0 x1 y1 = theRegion sys
        w = floor $ x1 - x0
        h = floor $ y1 - y0
    
    mv <- MV.unsafeNew (w * h * 4)
    GL.readBuffer $= GL.FrontBuffers
    MV.unsafeWith mv
        $ \ptr -> GL.readPixels (GL.Position 0 0) (GL.Size (gsizei w) (gsizei h))
            (GL.PixelData GL.RGBA GL.UnsignedByte ptr)

    Image w h <$> V.unsafeFreeze mv

screenshot :: System -> IO (Image PixelRGBA8)
screenshot sys = flipVertically <$> screenshotFlipped sys

blendMode2BlendingFactors :: BlendMode -> (GL.BlendingFactor, GL.BlendingFactor)
blendMode2BlendingFactors Normal = (GL.SrcAlpha, GL.OneMinusSrcAlpha)
blendMode2BlendingFactors Inverse = (GL.OneMinusDstColor, GL.Zero)
blendMode2BlendingFactors Add = (GL.SrcAlpha, GL.One)
blendMode2BlendingFactors Multiply = (GL.Zero, GL.SrcColor)
blendMode2BlendingFactors Screen = (GL.One, GL.OneMinusSrcColor)

blendMode :: BlendMode -> IO a -> IO a
blendMode mode m = do
    oldFunc <- get GL.blendFunc
    GL.blendFunc $= blendMode2BlendingFactors mode
    a <- m
    GL.blendFunc $= oldFunc
    return a