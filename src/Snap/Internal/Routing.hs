module Snap.Internal.Routing where


------------------------------------------------------------------------------
import           Data.ByteString (ByteString)
import           Data.ByteString.Internal (c2w)
import qualified Data.ByteString as B
import           Data.Monoid
import qualified Data.Map as Map

------------------------------------------------------------------------------
import           Snap.Internal.Http.Types
import           Snap.Internal.Types


------------------------------------------------------------------------------
{-|

The internal data type you use to build a routing tree.  Matching is
done unambiguously.

'Capture' and 'Dir' routes can have a "fallback" route:

  - For 'Capture', the fallback is routed when there is nothing to capture
  - For 'Dir', the fallback is routed when we can't find a route in its map

Fallback routes are stacked: i.e. for a route like:

> Dir [("foo", Capture "bar" (Action bar) NoRoute)] baz

visiting the URI foo/ will result in the "bar" capture being empty and
triggering its fallback. It's NoRoute, so we go to the nearest parent
fallback and try that, which is the baz action.

-}
data Route a = Action (Snap a)                        -- wraps a 'Snap' action
             | Capture ByteString (Route a) (Route a) -- captures the dir in a param
             | Dir (Map.Map ByteString (Route a)) (Route a)  -- match on a dir
             | NoRoute


instance Monoid (Route a) where
    mempty = NoRoute

    -- Unions two routes, favoring the right-hand side
    mappend NoRoute r = r

    mappend l@(Action _) r = case r of
      (Action _)        -> r
      (Capture p r' fb) -> Capture p r' (mappend fb l)
      (Dir _ _)         -> mappend (Dir Map.empty l) r
      NoRoute           -> l

    mappend (Capture p r' fb) r = Capture p (mappend r' r) fb

    mappend l@(Dir rm fb) r = case r of
      (Action _)      -> Dir rm (mappend fb r)
      (Capture _ _ _) -> Dir rm (mappend fb r)
      (Dir rm' fb')   -> Dir (Map.unionWith mappend rm rm') (mappend fb fb')
      NoRoute         -> l


------------------------------------------------------------------------------
-- | A web handler which, given a mapping from URL entry points to web
-- handlers, efficiently routes requests to the correct handler.
--
-- The URL entry points are given as relative paths, for example:
--
-- > route [ ("foo/bar/quux", fooBarQuux) ]
--
-- If the URI of the incoming request is
--
-- > /foo/bar/quux
--
-- or
--
-- > /foo/bar/quux/...anything...
--
-- then the request will be routed to \"@fooBarQuux@\", with 'rqContextPath'
-- set to \"@\/foo\/bar\/quux\/@\" and 'rqPathInfo' set to
-- \"@...anything...@\".
--
-- @FIXME@\/@TODO@: we need a version with and without the context path setting
-- behaviour; if the route is \"@article\/:id\/print@\", we probably want the
-- contextPath to be \"@\/article@\" instead of \"@\/article\/:id\/print@\".
--
-- A path component within an URL entry point beginning with a colon (\"@:@\")
-- is treated as a /variable capture/; the corresponding path component within
-- the request URI will be entered into the 'rqParams' parameters mapping with
-- the given name. For instance, if the routes were:
--
-- > route [ ("foo/:bar/baz", fooBazHandler) ]
--
-- Then a request for \"@\/foo\/saskatchewan\/baz@\" would be routed to
-- @fooBazHandler@ with a mapping for:
--
-- > "bar" => "sasketchewan"
--
-- in its parameters table.
--
-- Longer paths are matched first, and specific routes are matched before
-- captures. That is, if given routes:
--
-- > [ ("a", h1), ("a/b", h2), ("a/:x", h3) ]
--
-- a request for \"@\/a\/b@\" will go to @h2@, \"@\/a\/s@\" for any /s/ will go
-- to @h3@, and \"@\/a@\" will go to @h1@.
--
-- The following example matches \"@\/article@\" to an article index,
-- \"@\/login@\" to a login, and \"@\/article\/...@\" to an article renderer.
--
-- > route [ ("article",     renderIndex)
-- >       , ("article/:id", renderArticle)
-- >       , ("login",       method POST doLogin) ]
--
route :: [(ByteString, Snap a)] -> Snap a
route rts = route' rts' []
  where
    rts' = mconcat (map pRoute rts)


------------------------------------------------------------------------------
pRoute :: (ByteString, Snap a) -> Route a
pRoute (r, a) = foldr f (Action a) hier
  where
    hier   = filter (not . B.null) $ B.splitWith (== (c2w '/')) r
    f s rt = if B.head s == c2w ':'
        then Capture (B.tail s) rt NoRoute
        else Dir (Map.fromList [(s, rt)]) NoRoute


------------------------------------------------------------------------------
route' :: Route a -> [Route a] -> Snap a
route' (Action action) _ = action

route' (Capture param rt fb) fbs = do
    cwd <- getRequest >>= return . B.takeWhile (/= (c2w '/')) . rqPathInfo
    if B.null cwd
      then route' fb fbs
      else do modifyRequest $ updateContextPath (B.length cwd) . (f cwd)
              route' rt (fb:fbs)
  where
    f v req = req { rqParams = Map.insertWith (++) param [v] (rqParams req) }

route' (Dir rtm fb) fbs = do
    cwd <- getRequest >>= return . B.takeWhile (/= (c2w '/')) . rqPathInfo
    case Map.lookup cwd rtm of
      Just rt -> do
          modifyRequest $ updateContextPath (B.length cwd)
          route' rt (fb:fbs)
      Nothing -> route' fb fbs

route' NoRoute       [] = pass
route' NoRoute (fb:fbs) = route' fb fbs

