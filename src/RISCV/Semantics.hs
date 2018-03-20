{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}


-- I'm doing something based on SemMC here. Might actually make sense to actually
-- use SemMC, but I'm not sure yet.
module RISCV.Semantics where

import Control.Lens ( (%=) )
import Control.Lens.TH (makeLenses)
import Control.Monad.State
import Data.BitVector.Sized
import Data.Parameterized
import qualified Data.Sequence as Seq
import           Data.Sequence (Seq)
import GHC.TypeLits

-- | Architecture types
data Arch = RV32
          | RV64

-- | Maps an architecture to its register width
type family ArchWidth (arch :: Arch) :: Nat where
  ArchWidth 'RV32 = 32
  ArchWidth 'RV64 = 64

----------------------------------------
-- Expressions, statements, and formulas

-- | Formula parameter (represents unknown operands)
data Parameter (arch :: Arch) (w :: Nat)
  = Parameter (NatRepr w) String

deriving instance Show (Parameter arch w)
instance ShowF (Parameter arch)

data BVExpr (arch :: Arch) (w :: Nat) where
  -- Basic constructors
  LitBV :: BitVector w -> BVExpr arch w
  ParamBV :: Parameter arch w -> BVExpr arch w

  -- Accessing state
  RegRead :: BVExpr arch 5 -> BVExpr arch (ArchWidth arch)
  MemRead :: BVExpr arch (ArchWidth arch)
          -> BVExpr arch (ArchWidth arch)

  -- Arithmetic operations
  Add :: BVExpr arch w -> BVExpr arch w -> BVExpr arch w

  -- Other operations
  Ite :: BVExpr arch 1
      -> BVExpr arch w
      -> BVExpr arch w
      -> BVExpr arch w

-- | A 'Stmt' represents an atomic state transformation.
data Stmt (arch :: Arch) where
  AssignReg :: BVExpr arch 5 -> BVExpr arch (ArchWidth arch) -> Stmt arch
  AssignMem :: BVExpr arch (ArchWidth arch) -- ^ address
            -> BVExpr arch (ArchWidth arch) -- ^ value
            -> Stmt arch
  AssignPC  :: BVExpr arch (ArchWidth arch) -> Stmt arch

  CondStmt  :: BVExpr arch 1 -> Stmt arch -> Stmt arch

-- | Formula representing the semantics of an instruction. A formula has a number of
-- parameters (potentially zero), which represent the input to the formula. These are
-- going to the be the operands of the instruction -- register ids, immediate values,
-- and so forth.
data Formula arch = Formula { _fComment :: Seq String
                              -- ^ multiline comment
                            , _fParams  :: Seq (Some (Parameter arch))
                              -- ^ the inputs to the formula
                            , _fDef     :: Seq (Stmt arch)
                              -- ^ sequence of statements defining the formula
                            }

makeLenses ''Formula

newtype Semantics arch a =
  Semantics { runSemantics :: State (Formula arch) a }
  deriving (Functor,
            Applicative,
            Monad,
            MonadState (Formula arch))

litBV :: BitVector w -> BVExpr arch w
litBV = LitBV

regRead :: BVExpr arch 5 -> BVExpr arch (ArchWidth arch)
regRead = RegRead

memRead :: BVExpr arch (ArchWidth arch)
        -> BVExpr arch (ArchWidth arch)
memRead = MemRead

add :: BVExpr arch w -> BVExpr arch w -> BVExpr arch w
add = Add

ite :: BVExpr arch 1
    -> BVExpr arch w
    -> BVExpr arch w
    -> BVExpr arch w
ite = Ite

comment :: String -> Semantics arch ()
comment c = fComment %= \cs -> cs Seq.|> c

addStmt :: Stmt arch -> Semantics arch ()
addStmt stmt = fDef %= \stmts -> stmts Seq.|> stmt

assignReg :: BVExpr arch 5
          -> BVExpr arch (ArchWidth arch)
          -> Semantics arch ()
assignReg r e = addStmt (AssignReg r e)

assignMem :: BVExpr arch (ArchWidth arch)
          -> BVExpr arch (ArchWidth arch)
          -> Semantics arch ()
assignMem addr val = addStmt (AssignMem addr val)

assignPC :: BVExpr arch (ArchWidth arch) -> Semantics arch ()
assignPC pc = addStmt (AssignPC pc)

condStmt :: BVExpr arch 1 -> Stmt arch -> Semantics arch ()
condStmt cond stmt = addStmt (CondStmt cond stmt)

param :: KnownNat w => String -> Semantics arch (BVExpr arch w)
param s = do
  let p = Parameter knownNat s
  fParams %= \params -> params Seq.|> (Some p)
  return (ParamBV p)

addSem :: Semantics arch ()
addSem = do
  rd    <- param "rd"
  x_rs1 <- regRead <$> param "rs1"
  x_rs2 <- regRead <$> param "rs2"

  assignReg rd (add x_rs1 x_rs2)