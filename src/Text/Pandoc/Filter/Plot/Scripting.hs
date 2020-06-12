{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-|
Module      : $header$
Copyright   : (c) Laurent P René de Cotret, 2020
License     : GNU GPL, version 2 or above
Maintainer  : laurent.decotret@outlook.com
Stability   : internal
Portability : portable

Scripting
-}

module Text.Pandoc.Filter.Plot.Scripting
    ( ScriptResult(..)
    , runTempScript
    , runScriptIfNecessary
    , toImage
    ) where

import           Control.Monad.Reader

import           Data.ByteString.Lazy              (toStrict)
import           Data.Hashable                     (hash)
import           Data.Maybe                        (fromMaybe)
import qualified Data.Text                         as T
import qualified Data.Text.IO                      as T
import           Data.Text.Encoding                (decodeUtf8With)
import           Data.Text.Encoding.Error          (lenientDecode)

import           System.Directory                  (createDirectoryIfMissing,
                                                    doesFileExist, getTemporaryDirectory)
import           System.Exit                       (ExitCode (..))
import           System.FilePath                   (addExtension,
                                                    normalise, replaceExtension,
                                                    takeDirectory, (</>))
import           System.Process.Typed              ( readProcessInterleaved, shell
                                                   , setStdout, setStderr, byteStringOutput)

import           Text.Pandoc.Builder               (fromList, imageWith, link,
                                                    para, toList)
import           Text.Pandoc.Definition            (Block (..), Format)

import           Text.Pandoc.Filter.Plot.Parse     (captionReader)
import           Text.Pandoc.Filter.Plot.Renderers
import           Text.Pandoc.Filter.Plot.Monad


-- Run script as described by the spec, only if necessary
runScriptIfNecessary :: FigureSpec -> PlotM ScriptResult
runScriptIfNecessary spec = do
    liftIO $ createDirectoryIfMissing True . takeDirectory $ figurePath spec

    fileAlreadyExists <- liftIO . doesFileExist $ figurePath spec
    result <- if fileAlreadyExists
                then return ScriptSuccess
                else runTempScript spec

    logScriptResult result

    case result of
        ScriptSuccess -> liftIO $ T.writeFile (sourceCodePath spec) (script spec) >> return ScriptSuccess
        other         -> return other

    where
        logScriptResult ScriptSuccess = debug . T.pack . show $ ScriptSuccess 
        logScriptResult r             = err   . T.pack . show $ r


-- | Possible result of running a script
data ScriptResult
    = ScriptSuccess
    | ScriptChecksFailed String   -- Message
    | ScriptFailure String Int    -- Command and exit code
    | ToolkitNotInstalled Toolkit -- Script failed because toolkit is not installed

instance Show ScriptResult where
    show ScriptSuccess            = "Script success."
    show (ScriptChecksFailed msg) = "Script checks failed: " <> msg
    show (ScriptFailure msg ec)   = mconcat ["Script failed with exit code ", show ec, " and the following message: ", msg]
    show (ToolkitNotInstalled tk) = (show tk) <> " toolkit not installed."


-- Run script as described by the spec
-- Checks are performed, according to the renderer
-- Note that stdout from the script is suppressed, but not
-- stderr.
runTempScript :: FigureSpec -> PlotM ScriptResult
runTempScript spec@FigureSpec{..} = do
    let checks = scriptChecks toolkit
        checkResult = mconcat $ checks <*> [script]
    case checkResult of
        CheckFailed msg -> return $ ScriptChecksFailed msg
        CheckPassed -> do
            scriptPath <- tempScriptPath spec
            let captureFragment = (capture toolkit) spec (figurePath spec)
                -- Note: for gnuplot, the capture string must be placed
                --       BEFORE plotting happens. Since this is only really an
                --       issue for gnuplot, we have a special case.
                scriptWithCapture = if (toolkit == GNUPlot)
                                        then mconcat [captureFragment, "\n", script]
                                        else mconcat [script, "\n", captureFragment]
            liftIO $ T.writeFile scriptPath scriptWithCapture
            let outputSpec = OutputSpec { oFigureSpec = spec
                                        , oScriptPath = scriptPath
                                        , oFigurePath = figurePath spec
                                        }
            command_ <- T.unpack <$> (command toolkit outputSpec)
            debug $ "Running command " <> (T.pack command_)

            (ec, processOutput) <- liftIO 
                                    $ readProcessInterleaved 
                                    $ setStdout byteStringOutput
                                    $ setStderr byteStringOutput 
                                    $ shell command_

            debug $ "Command output: " <> (decodeUtf8With lenientDecode $ toStrict processOutput)

            case ec of
                ExitSuccess      -> return   ScriptSuccess
                ExitFailure code -> do
                    -- Two possible types of failures: either the script
                    -- failed because the toolkit was not available, or
                    -- because of a genuine error
                    toolkitInstalled <- toolkitAvailable toolkit 
                    if toolkitInstalled
                        then return $ ScriptFailure command_ code
                        else return $ ToolkitNotInstalled toolkit


-- | Convert a @FigureSpec@ to a Pandoc block component.
-- Note that the script to generate figure files must still
-- be run in another function.
toImage :: Format       -- ^ text format of the caption
        -> FigureSpec 
        -> Block
toImage fmt spec = head . toList $ para $ imageWith attrs' (T.pack target') "fig:" caption'
    -- To render images as figures with captions, the target title
    -- must be "fig:"
    -- Janky? yes
    where
        attrs'       = blockAttrs spec
        target'      = figurePath spec
        withSource'  = withSource spec
        srcLink      = link (T.pack $ replaceExtension target' ".txt") mempty "Source code"
        captionText  = fromList $ fromMaybe mempty (captionReader fmt $ caption spec)
        captionLinks = mconcat [" (", srcLink, ")"]
        caption'     = if withSource' then captionText <> captionLinks else captionText


-- | Determine the temp script path from Figure specifications
-- Note that for certain renderers, the appropriate file extension
-- is important.
tempScriptPath :: FigureSpec -> PlotM FilePath
tempScriptPath FigureSpec{..} = do
    let ext = scriptExtension toolkit
    -- Note that matlab will refuse to process files that don't start with
    -- a letter... so we append the renderer name
    -- Note that this hash is only so that we are running scripts from unique
    -- file names; it does NOT determine whether this figure should
    -- be rendered or not.
    let hashedPath = "pandocplot" <> (show . abs . hash $ script) <> ext
    liftIO $ (</> hashedPath) <$> getTemporaryDirectory


-- | Determine the path to the source code that generated the figure.
sourceCodePath :: FigureSpec -> FilePath
sourceCodePath = normalise . flip replaceExtension ".txt" . figurePath


-- | Determine the path a figure should have.
-- The path for this file is unique to the content of the figure,
-- so that @figurePath@ can be used to determine whether a figure should
-- be rendered again or not.
figurePath :: FigureSpec -> FilePath
figurePath spec = normalise $ directory spec </> stem spec
  where
    stem = flip addExtension ext . show . figureContentHash
    ext  = extension . saveFormat $ spec
