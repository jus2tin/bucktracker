module Main (main) where

-- | Fase 1 bouwt alleen de pure Domain-laag (zie DECISIONS.md). De Warp-
-- server, config en DB-verbinding volgen in een latere fase.
main :: IO ()
main =
  putStrLn
    "bucktracker: Api/Db laag volgt in een latere fase (zie DECISIONS.md, fase 1 = alleen Domain)."
