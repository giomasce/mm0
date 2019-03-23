module Main (main) where

import System.IO
import System.Environment
import qualified Data.ByteString.Lazy as B
import Parser
import AST
import Util
import Elaborator
import Verifier
import ProofTextParser

liftIO :: Either String a -> IO a
liftIO (Left e) = fail e
liftIO (Right e) = return e

main :: IO ()
main = do
  (mm0, rest) <- getArgs >>= \case
    [] -> return (stdin, [])
    (mm0:r) -> (\h -> (h, r)) <$> openFile mm0 ReadMode
  s <- B.hGetContents mm0
  ast <- either fail pure (parse s)
  env <- liftIO (elabAST ast)
  putStrLn "spec checked"
  case rest of
    [] -> fail "error: no proof file"
    (mmp:_) -> do
      pf <- readFile mmp
      pf <- liftIO (fromJustError "mmu parse failure" (parseProof pf))
      print pf
      liftIO (verify env pf)
      putStrLn "verified"
