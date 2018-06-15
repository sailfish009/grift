{-# LANGUAGE BinaryLiterals #-}
{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

{-|
Module      : RISCV.Simulation.LogMachine
Copyright   : (c) Benjamin Selfridge, 2018
                  Galois Inc.
License     : None (yet)
Maintainer  : benselfridge@galois.com
Stability   : experimental
Portability : portable

An IO-based simulation backend for RISC-V machines. We use the 'BitVector' type
directly for the underlying values, which allows us to keep the architecture width
unspecified.

This variant of LogMachine runs slower because it also logs coverage statistics.
-}

module RISCV.Simulation.LogMachine
  ( LogMachine(..)
  , mkLogMachine
  , LogMachineM
  , freezeRegisters
  , freezeMemory
  , runLogMachine
  , getTests
  ) where

import           Control.Lens ((^.))
import           Control.Monad (forM_)
import qualified Control.Monad.Reader.Class as R
import           Control.Monad.Trans
import           Control.Monad.Trans.Reader
import           Data.Array.IArray
import           Data.Array.IO
import           Data.BitVector.Sized
import           Data.BitVector.Sized.App
import qualified Data.ByteString as BS
import           Data.Foldable (toList)
import           Data.IORef
import           Data.List (nub, union)
import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)
import           Data.Parameterized
import qualified Data.Parameterized.Map as MapF

import RISCV.Extensions
import RISCV.InstructionSet
import RISCV.Types
import RISCV.Simulation
import RISCV.Semantics
import RISCV.Semantics.Exceptions


-- | IO-based machine state.
data LogMachine (arch :: BaseArch) (exts :: Extensions) = LogMachine
  { ioPC        :: IORef (BitVector (ArchWidth arch))
  , ioRegisters :: IOArray (BitVector 5) (BitVector (ArchWidth arch))
  , ioMemory    :: IOArray (BitVector (ArchWidth arch)) (BitVector 8)
  , ioCSRs      :: IORef (Map (BitVector 12) (BitVector (ArchWidth arch)))
  , ioPriv      :: IORef (BitVector 2)
  , ioMaxAddr   :: BitVector (ArchWidth arch)
  , ioException :: IORef (Maybe Exception)
  , ioSteps     :: IORef Int
  , ioTestMap   :: IORef (Map (Some (Opcode arch)) [[BitVector 1]])
  }

writeBS :: (Enum i, Num i, Ix i) => i -> BS.ByteString -> IOArray i (BitVector 8) -> IO ()
writeBS ix bs arr = do
  case BS.null bs of
    True -> return ()
    _    -> do
      writeArray arr ix (fromIntegral (BS.head bs))
      writeBS (ix+1) (BS.tail bs) arr

-- | Construct an LogMachine with a given maximum address, entry point, and list of
-- (addr, bytestring) pairs to load into the memory.
mkLogMachine :: forall arch exts .(KnownArch arch, KnownExtensions exts)
             => BitVector (ArchWidth arch)
             -> BitVector (ArchWidth arch)
             -> [(BitVector (ArchWidth arch), BS.ByteString)]
             -> IO (LogMachine arch exts)
mkLogMachine maxAddr entryPoint byteStrings = do
  pc        <- newIORef entryPoint
  registers <- newArray (1, 31) 0
  memory    <- newArray (0, maxAddr) 0
  csrs      <- newIORef $ Map.fromList $
    [ ]
  priv      <- newIORef 0b00
  e         <- newIORef Nothing
  steps     <- newIORef 0
  testMap   <- newIORef Map.empty -- $ Map.fromList (zip opcodes (repeat []))

  forM_ byteStrings $ \(addr, bs) -> do
    writeBS addr bs memory
  return (LogMachine pc registers memory csrs priv maxAddr e steps testMap)

-- | The 'LogMachineM' monad instantiates the 'RVState' monad type class, tying the
-- 'RVState' interface functions to actual transformations on the underlying mutable
-- state.
newtype LogMachineM (arch :: BaseArch) (exts :: Extensions) a =
  LogMachineM { runLogMachineM :: ReaderT (LogMachine arch exts) IO a }
  deriving (Functor, Applicative, Monad, R.MonadReader (LogMachine arch exts))

instance KnownArch arch => RVStateM (LogMachineM arch exts) arch exts where
  getPC = LogMachineM $ do
    pcRef <- ioPC <$> ask
    pcVal <- lift $ readIORef pcRef
    return pcVal
  getReg rid = LogMachineM $ do
    regArray <- ioRegisters <$> ask
    regVal   <- lift $ readArray regArray rid
    return regVal
  getMem addr = LogMachineM $ do
    memArray <- ioMemory <$> ask
    maxAddr <- ioMaxAddr <$> ask
    case addr < maxAddr of
      True -> do byte <- lift $ readArray memArray addr
                 return byte
      False -> do
        eRef <- ioException <$> ask
        lift $ writeIORef eRef (Just LoadAccessFault)
        return 0
  getCSR csr = LogMachineM $ do
    csrsRef <- ioCSRs <$> ask
    csrMap  <- lift $ readIORef csrsRef
    let csrVal = case Map.lookup csr csrMap of
          Just val -> val
          Nothing  -> 0 -- TODO: throw exception in this case
    return csrVal
  getPriv = LogMachineM $ do
    privRef <- ioPriv <$> ask
    privVal <- lift $ readIORef privRef
    return privVal

  setPC pcVal = LogMachineM $ do
    -- We assume that every time we are setting the PC, we have just finished
    -- executing an instruction, so increment steps.
    pcRef <- ioPC <$> ask
    stepsRef <- ioSteps <$> ask
    stepsVal <- lift $ readIORef stepsRef
    lift $ writeIORef pcRef pcVal
    lift $ writeIORef stepsRef (stepsVal+1)
  setReg rid regVal = LogMachineM $ do
    regArray <- ioRegisters <$> ask
    lift $ writeArray regArray rid regVal
  setMem addr byte = LogMachineM $ do
    memArray <- ioMemory <$> ask
    maxAddr <- ioMaxAddr <$> ask
    case addr < maxAddr of
      True -> lift $ writeArray memArray addr byte
      False -> do
        eRef <- ioException <$> ask
        lift $ writeIORef eRef (Just StoreAccessFault)
  setCSR csr csrVal = LogMachineM $ do
    csrsRef <- ioCSRs <$> ask
    csrMap  <- lift $ readIORef csrsRef
    case Map.member csr csrMap of
      True -> lift $ writeIORef csrsRef (Map.insert csr csrVal csrMap)
      False -> lift $ writeIORef csrsRef (Map.insert csr csrVal csrMap) -- TODO:
               -- throw exception in this case
  setPriv privVal = LogMachineM $ do
    privRef <- ioPriv <$> ask
    lift $ writeIORef privRef privVal

  logInstruction (Some (Inst opcode operands)) iset = do
    testMap <- LogMachineM (ioTestMap <$> ask)
    let formula = semanticsFromOpcode iset opcode
        tests = getTests formula
    testVals <- traverse (evalExpr operands 4) tests
    LogMachineM $ lift $ modifyIORef testMap $ \m ->
      Map.insertWith union (Some opcode) [testVals] m

-- | Create an immutable copy of the register file.
freezeRegisters :: LogMachine arch exts
                -> IO (Array (BitVector 5) (BitVector (ArchWidth arch)))
freezeRegisters = freeze . ioRegisters

-- TODO: Why does this need KnownNat (ArchWidth arch) but freezeRegisters does not?
-- | Create an immutable copy of the memory.
freezeMemory :: KnownArch arch
             => LogMachine arch exts
             -> IO (Array (BitVector (ArchWidth arch)) (BitVector 8))
freezeMemory = freeze . ioMemory

-- | Run the simulator for a given number of steps.
runLogMachine :: (KnownArch arch, KnownExtensions exts)
             => Int
             -> LogMachine arch exts
             -> IO Int
runLogMachine steps m =
  flip runReaderT m $ runLogMachineM $ runRV steps

----------------------------------------
-- Analysis

-- | Given a formula, constructs a list of all the tests that affect the execution of
-- that formula.
getTests :: Formula arch fmt -> [Expr arch fmt 1]
getTests formula = nub (concat $ getTestsStmt <$> formula ^. fDefs)

getTestsStmt :: Stmt arch fmt -> [Expr arch fmt 1]
getTestsStmt (AssignStmt le e) = getTestsLocExpr le ++ getTestsExpr e
getTestsStmt (BranchStmt t l r) =
  t : concat ((toList $ getTestsStmt <$> l) ++ (toList $ getTestsStmt <$> r))

getTestsLocExpr :: LocExpr arch fmt w -> [Expr arch fmt 1]
getTestsLocExpr (RegExpr e) = getTestsExpr e
getTestsLocExpr (MemExpr e) = getTestsExpr e
getTestsLocExpr (ResExpr e) = getTestsExpr e
getTestsLocExpr (CSRExpr e) = getTestsExpr e
getTestsLocExpr _ = []

getTestsExpr :: Expr arch fmt w -> [Expr arch fmt 1]
getTestsExpr (OperandExpr _) = []
getTestsExpr InstBytes = []
getTestsExpr (LocExpr le) = getTestsLocExpr le
getTestsExpr (AppExpr bvApp) = getTestsBVApp bvApp

getTestsBVApp :: BVApp (Expr arch fmt) w -> [Expr arch fmt 1]
getTestsBVApp (IteApp t l r) = t : getTestsExpr l ++ getTestsExpr r
getTestsBVApp app = foldMapFC getTestsExpr app