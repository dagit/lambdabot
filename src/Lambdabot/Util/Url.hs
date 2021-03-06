{-# LANGUAGE PatternGuards #-}

-- | URL Utility Functions

module Lambdabot.Util.Url
    ( getHtmlPage
    , urlPageTitle
    , urlTitlePrompt
    , runWebReq
    ) where

import Data.List
import Data.Maybe
import Lambdabot.Util.MiniHTTP
import Lambdabot.Util (limitStr)

import Control.Monad.Reader
import Text.HTML.TagSoup.Match
import Text.HTML.TagSoup
import Codec.Binary.UTF8.String

-- | The string that I prepend to the quoted page title.
urlTitlePrompt :: String
urlTitlePrompt = "Title: "

-- | Limit the maximum title length to prevent jokers from spamming
-- the channel with specially crafted HTML pages.
maxTitleLength :: Int
maxTitleLength = 80

-- | A web request monad transformer for keeping hold of the proxy.
type WebReq a = ReaderT Proxy IO a
runWebReq :: WebReq a -> Proxy -> IO a
runWebReq = runReaderT

-- | Fetches a page title suitable for display.  Ideally, other
-- plugins should make use of this function if the result is to be
-- displayed in an IRC channel because it ensures that a consistent
-- look is used (and also lets the URL plugin effectively ignore
-- contextual URLs that might be generated by another instance of
-- lambdabot; the URL plugin matches on 'urlTitlePrompt').
urlPageTitle :: String -> WebReq (Maybe String)
urlPageTitle url = do
    title <- rawPageTitle url
    return $ maybe Nothing prettyTitle title
    where
      prettyTitle = Just . (urlTitlePrompt ++) . limitStr maxTitleLength

-- | Fetches a page title for the specified URL.  This function should
-- only be used by other plugins if and only if the result is not to
-- be displayed in an IRC channel.  Instead, use 'urlPageTitle'.
rawPageTitle :: String -> WebReq (Maybe String)
rawPageTitle url 
    | Just uri <- parseURI url'  = do
        contents <- getHtmlPage uri
        case contentType contents of
          Just "text/html"       -> return $ extractTitle contents
          Just "application/pdf" -> rawPageTitle (googleCacheURL url)
          _                      -> return $ Nothing
    | otherwise = return Nothing
    -- URLs containing `#' fail to parse with parseURI, but
    -- these kind of URLs are commonly pasted, so we ought to try
    -- removing that part of provided URLs.
    where url' = takeWhile (/='#') url
          googleCacheURL = (gURL++) . escapeURIString (const False)
          gURL = "http://www.google.com/search?hl=en&q=cache:"

-- | Fetch the contents of a URL following HTTP redirects.  It returns
-- a list of strings comprising the server response which includes the
-- status line, response headers, and body.
getHtmlPage :: URI -> WebReq [String]
getHtmlPage u = getHtmlPage' u 5
  where
  getHtmlPage' :: URI -> Int -> WebReq [String]
  getHtmlPage' _   0 = return []
  getHtmlPage' uri n = do
    contents <- getURIContents uri
    case responseStatus contents of
      301       -> getHtmlPage' (redirectedUrl contents) (n-1)
      302       -> getHtmlPage' (redirectedUrl contents) (n-1)
      200       -> return contents
      _         -> return []
    where
      -- | Parse the HTTP response code from a line in the following
      -- format: HTTP/1.1 200 Success.
      responseStatus hdrs = (read . (!!1) . words . (!!0)) hdrs :: Int

      -- | Return the value of the "Location" header in the server
      -- response
      redirectedUrl hdrs
          | Just loc <- getHeader "Location" hdrs =
              case parseURI loc of
                Nothing   -> (fromJust . parseURI) $ fullUrl loc
                Just uri' -> uri'
          | otherwise = error("No Location header found in 3xx response.")

      -- | Construct a full absolute URL based on the current uri.  This is
      -- used when a Location header violates the HTTP RFC and does not send
      -- an absolute URI in the response, instead, a relative URI is sent, so
      -- we must manually construct the absolute URI.
      fullUrl loc = let auth = fromJust $ uriAuthority uri
                    in (uriScheme uri) ++ "//" ++
                       (uriRegName auth) ++
                       loc

-- | Fetch the contents of a URL returning a list of strings
-- comprising the server response which includes the status line,
-- response headers, and body.
getURIContents :: URI -> WebReq [String]
getURIContents uri = do
  proxy <- ask
  liftIO $ readNBytes 3048 proxy uri (request proxy) ""
    where
      request Nothing = ["GET " ++ abs_path ++ " HTTP/1.1",
                         "host: " ++ host,
                         "Connection: close", ""]
      request _       = ["GET " ++ show uri ++ " HTTP/1.0", ""]

      abs_path = case uriPath uri ++ uriQuery uri ++ uriFragment uri of
                   url@('/':_) -> url
                   url         -> '/':url

      host = uriRegName . fromJust $ uriAuthority uri

-- | Given a server response (list of Strings), return the text in
-- between the title HTML element, only if it is text/html content.
-- Now supports all(?) HTML entities thanks to TagSoup.
extractTitle :: [String] -> Maybe String
extractTitle = content . tags . decodeString . unlines where
    tags = closing . opening . canonicalizeTags . parseTags
    opening = dropWhile (not . tagOpenLit "title" (const True))
    closing = takeWhile (not . tagCloseLit "title")

    content = maybeText . format . innerText
    format = unwords . words
    maybeText [] = Nothing
    maybeText t  = Just (encodeString t)

-- | What is the type of the server response?
contentType :: [String] -> Maybe (String)
contentType []       = Nothing
contentType contents = Just val
    where
      val   = takeWhile (/=';') ctype
      ctype = case getHeader "Content-Type" contents of
                    Nothing -> error "Lib.URL.isTextHTML: getHeader failed"
                    Just c  -> c

-- | Retrieve the specified header from the server response being
-- careful to strip the trailing carriage return.  I swiped this code
-- from Search.hs, but had to modify it because it was not properly
-- stripping off the trailing CR (must not have manifested itself as a
-- bug in that code; however, parseURI will fail against CR-terminated
-- strings.
getHeader :: String -> [String] -> Maybe String
getHeader _   []     = Nothing
getHeader hdr (_:hs) = lookup hdr $ concatMap mkassoc hs
    where
      removeCR   = takeWhile (/='\r')
      mkassoc s  = case findIndex (==':') s of
                    Just n  -> [(take n s, removeCR $ drop (n+2) s)]
                    Nothing -> []
