{-
This file is part of GRIFT (Galois RISC-V ISA Formal Tools).

GRIFT is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

GRIFT is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero Public License for more details.

You should have received a copy of the GNU Affero Public License
along with GRIFT.  If not, see <https://www.gnu.org/licenses/>.
-}

{-# LANGUAGE BinaryLiterals #-}
{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

{-|
Module      : RISCV.Simulation.MapMachine
Copyright   : (c) Benjamin Selfridge, 2018
                  Galois Inc.
License     : AGPLv3
Maintainer  : benselfridge@galois.com
Stability   : experimental
Portability : portable

An Map-based simulation backend for RISC-V machines. We use the 'BitVector' type
directly for the underlying values, which allows us to keep the architecture width
unspecified.
-}

module RISCV.Simulation.MapMachine
  ( MapMachine(..)
  , mkMapMachine
  , MapMachineM
  , runMapMachine
  ) where

import qualified Control.Monad.State.Class as S
import           Control.Monad.Trans.State
import           Data.BitVector.Sized
import qualified Data.ByteString as BS
import           Data.Foldable (for_)
import           Data.List (union)
import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)
import           Data.Parameterized
import           Data.Traversable (for)

import RISCV.InstructionSet
import RISCV.Types
import RISCV.Simulation
import RISCV.Semantics
import RISCV.Semantics.Exceptions

-- | IO-based machine state.
data MapMachine (rv :: RV) = MapMachine
  { pc        :: BitVector (RVWidth rv)
  , registers :: Map (BitVector 5) (BitVector (RVWidth rv))
  , memory    :: Map (BitVector (RVWidth rv)) (BitVector 8)
  , csrs      :: Map (BitVector 12) (BitVector (RVWidth rv))
  , priv      :: BitVector 2
  , maxAddr   :: BitVector (RVWidth rv)
  , exception :: Maybe Exception
  , steps     :: Int
  , testMap   :: Map (Some (Opcode rv)) [[BitVector 1]]
  }

-- | Construct an MapMachine with a given maximum address, entry point, and list of
-- (addr, bytestring) pairs to load into the memory.
mkMapMachine :: KnownRV rv
             => BitVector (RVWidth rv)
             -> BitVector (RVWidth rv)
             -> [(BitVector (RVWidth rv), BS.ByteString)]
             -> MapMachine rv
mkMapMachine maxAddr' entryPoint byteStrings =
  MapMachine { pc = entryPoint
             , registers = Map.fromList (zip [1..31] (repeat 0))
             , memory = Map.fromList memoryAssocs
             , csrs = Map.empty
             , priv = 0b00
             , maxAddr = maxAddr'
             , exception = Nothing
             , steps = 0
             , testMap = Map.empty
             }
  where memoryAssocs = concat (map zipBS byteStrings)
        zipBS (start, bs) = zip [start..] (map (bitVector . fromIntegral) (BS.unpack bs))

-- | The 'MapMachineM' monad instantiates the 'RVState' monad type class, tying the
-- 'RVState' interface functions to actual transformations on the underlying mutable
-- state.
newtype MapMachineM (rv :: RV) a =
  MapMachineM { runMapMachineM :: State (MapMachine rv) a }
  deriving (Functor, Applicative, Monad, S.MonadState (MapMachine rv))

instance KnownRV rv => RVStateM (MapMachineM rv) rv where
  getPC = MapMachineM $ pc <$> get
  getReg rid = MapMachineM $ Map.findWithDefault 0 rid <$> registers <$> get
  getMem bytes addr = MapMachineM $ do
    mem <- memory <$> get
    ma <- maxAddr <$> get
    case addr + fromIntegral (natValue bytes) < ma of
      True -> do
        val <- for [addr..addr+(fromIntegral (natValue bytes-1))] $ \a ->
          return $ Map.findWithDefault 0 a mem
        return $ bvConcatManyWithRepr ((knownNat @8) `natMultiply` bytes) val
      False -> do
        S.modify $ \m -> m { exception = Just LoadAccessFault }
        return (BV ((knownNat @8) `natMultiply` bytes) 0)
  getCSR csr = MapMachineM $ Map.findWithDefault 0 csr <$> csrs <$> get
  getPriv = MapMachineM $ priv <$> get

  setPC pcVal = MapMachineM $ do
    S.modify $ \m -> m { pc = pcVal, steps = steps m + 1 }
  setReg rid regVal = MapMachineM $ S.modify $ \m ->
    m { registers = Map.insert rid regVal (registers m) }
  setMem bytes addr val = MapMachineM $ do
    ma <- maxAddr <$> get
    case addr < ma of
      True -> do
        for_ addrValPairs $ \(a, byte) -> S.modify $ \m ->
          m { memory = Map.insert a byte (memory m) }
        where addrValPairs = zip
                [addr..addr+(fromIntegral (natValue bytes-1))]
                (bvGetBytesU (fromIntegral (natValue bytes)) val)
      False -> undefined
  setCSR csr csrVal = MapMachineM $ S.modify $ \m ->
    m { csrs = Map.insert csr csrVal (csrs m) }
  setPriv privVal = MapMachineM $ S.modify $ \m -> m { priv = privVal }

  logInstruction iset inst@(Inst opcode _) = do
    return ()
    let formula = semanticsFromOpcode iset opcode
        tests = getTests (getInstSemantics formula)
    testVals <- traverse (evalInstExpr iset inst 4) tests
    MapMachineM $ S.modify $ \m ->
      m { testMap = Map.insertWith union (Some opcode) [testVals] (testMap m) }

-- | Run the simulator for a given number of steps.
runMapMachine :: KnownRV rv=> Int -> MapMachine rv -> (Int, MapMachine rv)
runMapMachine maxSteps m = flip runState m $ runMapMachineM $ runRV maxSteps
