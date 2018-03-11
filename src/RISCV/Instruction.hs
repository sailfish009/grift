{-# LANGUAGE BinaryLiterals    #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE KindSignatures    #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeFamilies      #-}

module RISCV.Instruction
  ( -- * Instructions
    Instruction(..)
  , Format(..)
  , FormatRepr(..)
    -- * Opcodes
  , Opcode(..)
  , OpBits(..)
    -- * Operands
  , Operands(..)
    -- * Opcode / OpBits conversion
  , opcodeFromOpBits
  , opBitsFromOpcode
  ) where

import Data.BitVector.Sized
import Data.Maybe (fromJust)
import Data.Parameterized
import qualified Data.Parameterized.Map as Map
import Data.Parameterized.Map (MapF)
import Data.Parameterized.TH.GADT

----------------------------------------
-- Formats

-- | The seven RV32I instruction formats. Each RV32I opcode has one of seven encoding
-- formats, corresponding to its operands and the way those operands are laid out as
-- bits in the instruction word. We include an additional (eighth) format, X,
-- inhabited only by an illegal instruction.
--
-- NOTE: Although the RISC-V spec only lists 6, in our formulation, the ecall and
-- ebreak instructions are slightly distinct from the other I-format instructions; in
-- particular, they don't have any operands, and they each actually use the same
-- opcode AND funct3 bits, and therefore have to have one extra bit to distinguish
-- between the two of them. Therefore, we invented an extra format, E, to represent
-- them.

data Format = R | I | S | B | U | J | E | X

-- | A type-level representative of the format. Particularly useful when decoding
-- instructions since we won't know ahead of time what format to classify them as.
data FormatRepr (k :: Format) where
  RRepr :: FormatRepr 'R
  IRepr :: FormatRepr 'I
  SRepr :: FormatRepr 'S
  BRepr :: FormatRepr 'B
  URepr :: FormatRepr 'U
  JRepr :: FormatRepr 'J
  ERepr :: FormatRepr 'E
  XRepr :: FormatRepr 'X

----------------------------------------
-- Operands

-- TODO: Consider making the operand arguments lists of bit vector types???
-- | RV32I Operand lists, parameterized by format. There is exactly one constructor
-- per format.
data Operands :: Format -> * where
  ROperands :: BitVector 5 -> BitVector 5  -> BitVector 5  -> Operands 'R
  IOperands :: BitVector 5 -> BitVector 5  -> BitVector 12 -> Operands 'I
  SOperands :: BitVector 5 -> BitVector 5  -> BitVector 12 -> Operands 'S
  BOperands :: BitVector 5 -> BitVector 5  -> BitVector 12 -> Operands 'B
  UOperands :: BitVector 5 -> BitVector 20                 -> Operands 'U
  JOperands :: BitVector 5 -> BitVector 20                 -> Operands 'J
  EOperands ::                                                Operands 'E
  XOperands :: BitVector 32                                -> Operands 'X

----------------------------------------
-- Opcodes

-- | RV32I Opcodes, parameterized by format.
data Opcode (f :: Format) :: * where

  -- R type
  Add  :: Opcode 'R
  Sub  :: Opcode 'R
  Sll  :: Opcode 'R
  Slt  :: Opcode 'R
  Sltu :: Opcode 'R
  Xor  :: Opcode 'R
  Srl  :: Opcode 'R
  Sra  :: Opcode 'R
  Or   :: Opcode 'R
  And  :: Opcode 'R

  -- I type
  Jalr    :: Opcode 'I
  Lb      :: Opcode 'I
  Lh      :: Opcode 'I
  Lw      :: Opcode 'I
  Lbu     :: Opcode 'I
  Lhu     :: Opcode 'I
  Addi    :: Opcode 'I
  Slti    :: Opcode 'I
  Sltiu   :: Opcode 'I
  Xori    :: Opcode 'I
  Ori     :: Opcode 'I
  Andi    :: Opcode 'I
  -- TODO: the shift instructions are also a slightly different format, we accept
  -- that for the time being.
  Slli    :: Opcode 'I
  Srli    :: Opcode 'I
  Srai    :: Opcode 'I
  -- TODO: Fence and Fence_i are both slightly wonky; we might need to separate them
  -- out into separate formats like we did with Ecall and Ebreak. Fence uses the
  -- immediate bits to encode additional operands and Fence_i requires them to be 0,
  -- so ideally we'd capture that in the type.
  Fence   :: Opcode 'I
  Fence_i :: Opcode 'I
  Csrrw   :: Opcode 'I
  Csrrs   :: Opcode 'I
  Csrrc   :: Opcode 'I
  Csrrwi  :: Opcode 'I
  Csrrsi  :: Opcode 'I
  Csrrci  :: Opcode 'I

  -- S type
  Sb :: Opcode 'S
  Sh :: Opcode 'S
  Sw :: Opcode 'S

  -- B type
  Beq  :: Opcode 'B
  Bne  :: Opcode 'B
  Blt  :: Opcode 'B
  Bge  :: Opcode 'B
  Bltu :: Opcode 'B
  Bgeu :: Opcode 'B

  -- U type
  Lui   :: Opcode 'U
  Auipc :: Opcode 'U

  -- J type
  Jal :: Opcode 'J

  -- E type
  Ecall   :: Opcode 'E
  Ebreak  :: Opcode 'E

  -- X type (illegal instruction)
  Illegal :: Opcode 'X

----------------------------------------
-- OpBits

-- | Bits fixed by an opcode.
-- Holds all the bits that are fixed by a particular opcode. Each format maps to a
-- potentially different set of bits.
data OpBits :: Format -> * where
  ROpBits :: BitVector 7 -> BitVector 3 -> BitVector 7 -> OpBits 'R
  IOpBits :: BitVector 7 -> BitVector 3                -> OpBits 'I
  SOpBits :: BitVector 7 -> BitVector 3                -> OpBits 'S
  BOpBits :: BitVector 7 -> BitVector 3                -> OpBits 'B
  UOpBits :: BitVector 7                               -> OpBits 'U
  JOpBits :: BitVector 7                               -> OpBits 'J
  EOpBits :: BitVector 7 -> BitVector 25               -> OpBits 'E
  XOpBits ::                                              OpBits 'X

----------------------------------------
-- Instructions

-- | RV32I Instruction, parameterized by format.
data Instruction (k :: Format) = Inst { instOpcode   :: Opcode k
                                      , instOperands :: Operands k
                                      }

swap :: Pair (k :: Format -> *) (v :: Format -> *) -> Pair v k
swap (Pair k v) = Pair v k

transMap :: OrdF v => MapF (k :: Format -> *) (v :: Format -> *) -> MapF v k
transMap = Map.fromList . map swap . Map.toList

-- | Get the OpBits of an Opcode (the bits that are fixed by that opcode in all
-- instances)
opBitsFromOpcode :: Opcode k -> OpBits k
opBitsFromOpcode opcode = case Map.lookup opcode opcodeOpBitsMap of
  Just opBits -> opBits
  Nothing     -> error $ "Opcode " ++ show opcode ++
                 "does not have corresponding OpBits defined."

-- TODO: fix this; if we get Nothing we need to return an illegal instruction?
-- | Get the Opcode of an OpBits. Throws an error if given an invalid OpBits.
opcodeFromOpBits :: OpBits k -> Opcode k
opcodeFromOpBits opBits = fromJust $ Map.lookup opBits opBitsOpcodeMap

opcodeOpBitsMap :: MapF Opcode OpBits
opcodeOpBitsMap = Map.fromList $

  [ Pair Add (ROpBits (bv 0b0110011) (bv 0b000) (bv 0b0000000))
  , Pair Sub (ROpBits (bv 0b0110011) (bv 0b000) (bv 0b0100000))
  , Pair Sll (ROpBits (bv 0b0110011) (bv 0b001) (bv 0b0000000))
  , Pair Slt (ROpBits (bv 0b0110011) (bv 0b010) (bv 0b0000000))
  , Pair Sltu (ROpBits (bv 0b0110011) (bv 0b011) (bv 0b0000000))
  , Pair Xor (ROpBits (bv 0b0110011) (bv 0b100) (bv 0b0000000))
  , Pair Srl (ROpBits (bv 0b0110011) (bv 0b101) (bv 0b0000000))
  , Pair Sra (ROpBits (bv 0b0110011) (bv 0b101) (bv 0b0100000))
  , Pair Or (ROpBits (bv 0b0110011) (bv 0b110) (bv 0b0000000))
  , Pair And (ROpBits (bv 0b0110011) (bv 0b111) (bv 0b0000000))

-- I type
  , Pair Jalr (IOpBits (bv 0b1100111) (bv 0b000))
  , Pair Lb (IOpBits (bv 0b0000011) (bv 0b000))
  , Pair Lh (IOpBits (bv 0b0000011) (bv 0b001))
  , Pair Lw (IOpBits (bv 0b0000011) (bv 0b010))
  , Pair Lbu (IOpBits (bv 0b0000011) (bv 0b100))
  , Pair Lhu (IOpBits (bv 0b0000011) (bv 0b101))
  , Pair Addi (IOpBits (bv 0b0010011) (bv 0b000))
  , Pair Slti (IOpBits (bv 0b0010011) (bv 0b010))
  , Pair Sltiu (IOpBits (bv 0b0010011) (bv 0b011))
  , Pair Xori (IOpBits (bv 0b0010011) (bv 0b100))
  , Pair Ori (IOpBits (bv 0b0010011) (bv 0b110))
  , Pair Andi (IOpBits (bv 0b0010011) (bv 0b111))
  , Pair Slli (IOpBits (bv 0b0010011) (bv 0b001))
  , Pair Srli (IOpBits (bv 0b0010011) (bv 0b101))
  , Pair Srai (IOpBits (bv 0b0010011) (bv 0b101))
  , Pair Fence (IOpBits (bv 0b0001111) (bv 0b000))
  , Pair Fence (IOpBits (bv 0b0001111) (bv 0b001))
  , Pair Csrrw (IOpBits (bv 0b1110011) (bv 0b001))
  , Pair Csrrs (IOpBits (bv 0b1110011) (bv 0b010))
  , Pair Csrrc (IOpBits (bv 0b1110011) (bv 0b011))
  , Pair Csrrwi (IOpBits (bv 0b1110011) (bv 0b101))
  , Pair Csrrsi (IOpBits (bv 0b1110011) (bv 0b110))
  , Pair Csrrci (IOpBits (bv 0b1110011) (bv 0b111))

-- S type
  , Pair Sb (SOpBits (bv 0b0100011) (bv 0b000))
  , Pair Sh (SOpBits (bv 0b0100011) (bv 0b001))
  , Pair Sw (SOpBits (bv 0b0100011) (bv 0b010))

-- B type
  , Pair Beq (BOpBits (bv 0b1100011) (bv 0b000))
  , Pair Bne (BOpBits (bv 0b1100011) (bv 0b001))
  , Pair Blt (BOpBits (bv 0b1100011) (bv 0b100))
  , Pair Bge (BOpBits (bv 0b1100011) (bv 0b101))
  , Pair Bltu (BOpBits (bv 0b1100011) (bv 0b110))
  , Pair Bgeu (BOpBits (bv 0b1100011) (bv 0b111))

-- U type
  , Pair Lui (UOpBits (bv 0b0110111))
  , Pair Auipc (UOpBits (bv 0b0010111))

-- J type
  , Pair Jal (JOpBits (bv 0b1101111))

-- E type
  , Pair Ecall (EOpBits (bv 0b1110011) (bv 0b0000000000000000000000000))
  , Pair Ebreak (EOpBits (bv 0b1110011) (bv 0b0000000000010000000000000))

-- X type
  , Pair Illegal (XOpBits)
  ]

opBitsOpcodeMap :: MapF OpBits Opcode
opBitsOpcodeMap = transMap opcodeOpBitsMap

----------------------------------------
-- Instances

-- Force types to be in context for TH stuff below.
$(return [])

instance Show (FormatRepr k) where
  show RRepr = "RRepr"
  show IRepr = "IRepr"
  show SRepr = "SRepr"
  show BRepr = "BRepr"
  show URepr = "URepr"
  show JRepr = "JRepr"
  show ERepr = "ERepr"
  show XRepr = "XRepr"

instance ShowF FormatRepr

-- TODO: KnownRepr instance for FormatRepr?


instance Show (Operands k) where
  show (ROperands rd rs1 rs2) =
    "[ rd = "  ++ show rd ++
    ", rs1 = " ++ show rs1 ++
    ", rs2 = " ++ show rs2 ++ " ]"
  show (IOperands rd rs1 imm) =
    "[ rd = "  ++ show rd ++
    ", rs1 = " ++ show rs1 ++
    ", imm = " ++ show imm ++ " ]"
  show (SOperands rs1 rs2 imm) =
    "[ rs1 = " ++ show rs1 ++
    ", rs2 = " ++ show rs2 ++
    ", imm = " ++ show imm ++ " ]"
  show (BOperands rs1 rs2 imm) =
    "[ rs1 = " ++ show rs1 ++
    ", rs2 = " ++ show rs2 ++
    ", imm = " ++ show imm ++ " ]"
  show (UOperands rd imm) =
    "[ rd = "  ++ show rd ++
    ", imm = " ++ show imm ++ " ]"
  show (JOperands rd imm) =
    "[ rd = "  ++ show rd ++
    ", imm = " ++ show imm ++ " ]"
  show (EOperands) = "[]"
  show (XOperands ill) = "[ ill = " ++ show ill ++ "]"

instance ShowF Operands

instance Show (Opcode k) where
  -- R type
  show Add  = "Add"
  show Sub  = "Sub"
  show Sll  = "Sll"
  show Slt  = "Slt"
  show Sltu = "Sltu"
  show Xor  = "Xor"
  show Srl  = "Srl"
  show Sra  = "Sra"
  show Or   = "Or"
  show And  = "And"

  -- I type
  show Jalr    = "Jalr"
  show Lb      = "Lb"
  show Lh      = "Lh"
  show Lw      = "Lw"
  show Lbu     = "Lbu"
  show Lhu     = "Lhu"
  show Addi    = "Addi"
  show Slti    = "Slti"
  show Sltiu   = "Sltiu"
  show Xori    = "Xori"
  show Ori     = "Ori"
  show Andi    = "Andi"
  show Slli    = "Slli"
  show Srli    = "Srli"
  show Srai    = "Srai"
  show Fence   = "Fence"
  show Fence_i = "Fence.i"
  show Csrrw   = "Csrrw"
  show Csrrs   = "Csrrs"
  show Csrrc   = "Csrrc"
  show Csrrwi  = "Csrrwi"
  show Csrrsi  = "Csrrsi"
  show Csrrci  = "Csrrci"

  -- S type
  show Sb = "Sb"
  show Sh = "Sh"
  show Sw = "Sw"

  -- B type
  show Beq  = "Beq"
  show Bne  = "Bne"
  show Blt  = "Blt"
  show Bge  = "Bge"
  show Bltu = "Bltu"
  show Bgeu = "Bgeu"

  -- U type
  show Lui   = "Lui"
  show Auipc = "Auipc"

  -- J type
  show Jal = "Jal"

  -- E type
  show Ecall   = "Ecall"
  show Ebreak  = "Ebreak"

  -- X type (illegal instruction)
  show Illegal = "Illegal"

instance ShowF Opcode

instance EqF Opcode where
  -- R type
  Add `eqF` Add = True
  Sub `eqF` Sub = True
  Slt `eqF` Slt = True
  Sltu `eqF` Sltu = True
  Xor `eqF` Xor = True
  Srl `eqF` Srl = True
  Sra `eqF` Sra = True
  Or `eqF` Or = True
  And `eqF` And = True

  -- I type
  Jalr `eqF` Jalr = True
  Lb `eqF` Lb = True
  Lh `eqF` Lh = True
  Lw `eqF` Lw = True
  Lbu `eqF` Lbu = True
  Lhu `eqF` Lhu = True
  Addi `eqF` Addi = True
  Slti `eqF` Slti = True
  Sltiu `eqF` Sltiu = True
  Xori `eqF` Xori = True
  Ori `eqF` Ori = True
  Andi `eqF` Andi = True
  Slli `eqF` Slli = True
  Srli `eqF` Srli = True
  Srai `eqF` Srai = True
  Fence `eqF` Fence = True
  Fence_i `eqF` Fence_i = True
  Csrrw `eqF` Csrrw = True
  Csrrs `eqF` Csrrs = True
  Csrrc `eqF` Csrrc = True
  Csrrwi `eqF` Csrrwi = True
  Csrrsi `eqF` Csrrsi = True
  Csrrci `eqF` Csrrci = True

  -- S type
  Sb `eqF` Sb = True
  Sh `eqF` Sh = True
  Sw `eqF` Sw = True

  -- B type
  Beq `eqF` Beq = True
  Bne `eqF` Bne = True
  Blt `eqF` Blt = True
  Bge `eqF` Bge = True
  Bltu `eqF` Bltu = True
  Bgeu `eqF` Bgeu = True

  -- U type
  Lui `eqF` Lui = True
  Auipc `eqF` Auipc = True

  -- J type
  Jal `eqF` Jal = True

  -- E type
  Ecall `eqF` Ecall = True
  Ebreak `eqF` Ebreak = True

  -- X type (illegal instruction)
  Illegal `eqF` Illegal = True

  _ `eqF` _ = False


instance TestEquality Opcode where
  testEquality = $(structuralTypeEquality [t|Opcode|] [])

instance OrdF Opcode where
  compareF = $(structuralTypeOrd [t|Opcode|] [])

instance Show (OpBits k) where
  show (ROpBits opcode funct3 funct7) =
    "[ opcode = " ++ show opcode ++
    ", funct3 = " ++ show funct3 ++
    ", funct7 = " ++ show funct7 ++ "]"
  show (IOpBits opcode funct3) =
    "[ opcode = " ++ show opcode ++
    ", funct3 = " ++ show funct3 ++ "]"
  show (SOpBits opcode funct3) =
    "[ opcode = " ++ show opcode ++
    ", funct3 = " ++ show funct3 ++ "]"
  show (BOpBits opcode funct3) =
    "[ opcode = " ++ show opcode ++
    ", funct3 = " ++ show funct3 ++ "]"
  show (UOpBits opcode) =
    "[ opcode = " ++ show opcode ++ "]"
  show (JOpBits opcode) =
    "[ opcode = " ++ show opcode ++ "]"
  show (EOpBits opcode b) =
    "[ opcode = " ++ show opcode ++
    ", b = " ++ show b ++ "]"
  show (XOpBits) = "[]"

instance ShowF OpBits

instance TestEquality OpBits where
  testEquality = $(structuralTypeEquality [t|OpBits|] [])

instance OrdF OpBits where
  compareF = $(structuralTypeOrd [t|OpBits|] [])

instance Show (Instruction k) where
  show (Inst opcode operands) = show opcode ++ " " ++ show operands

instance ShowF Instruction
