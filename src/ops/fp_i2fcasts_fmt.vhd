-------------------------------------------------------------------------------
-- Title      : Floating-Point Conversion Unit
-- Project    :
-------------------------------------------------------------------------------
-- File       : fp_i2fcasts.vhd
-- Author     : Stefan Mach  <smach@iis.ee.ethz.ch>
-- Company    : Integrated Systems Laboratory, ETH Zurich
-- Created    : 2018-03-22
-- Last update: 2018-11-08
-- Platform   : ModelSim (simulation), Synopsys (synthesis)
-- Standard   : VHDL'08
-------------------------------------------------------------------------------
-- Description: Parametric floating-point conversion unit for floating-point to
--              floating-point casts as well as integer-float and float-integer
--              casts.
--              Supported operations from fpnew_pkg.fpOp:
--              - I2F
-------------------------------------------------------------------------------
-- Copyright (C) 2018 ETH Zurich, University of Bologna
-- All rights reserved.
--
-- This code is under development and not yet released to the public.
-- Until it is released, the code is under the copyright of ETH Zurich and
-- the University of Bologna, and may contain confidential and/or unpublished
-- work. Any reuse/redistribution is strictly forbidden without written
-- permission from ETH Zurich.
--
-- Bug fixes and contributions will eventually be released under the
-- SolderPad open hardware license in the context of the PULP platform
-- (http://www.pulp-platform.org), under the copyright of ETH Zurich and the
-- University of Bologna.
-------------------------------------------------------------------------------

library IEEE, work;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.fpnew_pkg.all;
use work.fpnew_fmts_pkg.all;
use work.fpnew_comps_pkg.all;

--! @brief Floating-Point Conversion Unit
--! @details Parametric floating-point conversion unit for floating-point to
--! floating-point casts as well as integer-float and float-integer casts.
--! Supported operations from fpnew_pkg.fpOp:
--! - F2I
entity fp_i2fcasts_fmt is

  generic (
    DSTENCODING : fpFmtEncoding_t    := DEFAULTENCODING(FP32);
    INTFORMATS  : activeIntFormats_t := (Active => (others => true),
                                        Length  => INTFMTLENGTHS);
    LATENCY     : natural            := 0;
    TAG_WIDTH   : natural            := 0);

  port (
    Clk_CI       : in  std_logic;
    Reset_RBI    : in  std_logic;
    ---------------------------------------------------------------------------
    A_DI         : in  std_logic_vector(MAXWIDTH(INTFORMATS)-1 downto 0);
    RoundMode_SI : in  rvRoundingMode_t;
    OpMod_SI     : in  std_logic;
    SrcFmt_SI    : in  intFmt_t;
    Tag_DI       : in  std_logic_vector(TAG_WIDTH-1 downto 0);
    ---------------------------------------------------------------------------
    InValid_SI   : in  std_logic;
    InReady_SO   : out std_logic;
    Flush_SI     : in  std_logic;
    ---------------------------------------------------------------------------
    Z_DO         : out std_logic_vector(WIDTH(DSTENCODING)-1 downto 0);
    Status_DO    : out rvStatus_t;
    Tag_DO       : out std_logic_vector(TAG_WIDTH-1 downto 0);
    Zext_SO      : out std_logic;
    ---------------------------------------------------------------------------
    OutValid_SO  : out std_logic;
    OutReady_SI  : in  std_logic);

end entity fp_i2fcasts_fmt;


architecture rtl of fp_i2fcasts_fmt is

  -----------------------------------------------------------------------------
  -- Constants
  -----------------------------------------------------------------------------

  -- Largest integer format we need to handle
  constant INTWIDTH : natural := MAXWIDTH(INTFORMATS);

  -- Mantissa needs to be wide enough to hold mantissa or integer width
  constant MANTWIDTH : natural := maximum_t(DSTENCODING.ManBits, INTWIDTH);

  -- Make exponent wide enough to hold signed exponents or readjustment shift
  -- amount in signed form
  constant EXPWIDTH : natural := maximum_t(DSTENCODING.ExpBits+1, clog2(MANTWIDTH)+1);


  -----------------------------------------------------------------------------
  -- Type Definitions
  -----------------------------------------------------------------------------

  --! @brief Holds the internally encoded exponent for all formats
  type fmtExponent_t is array (fpFmt_t) of signed(EXPWIDTH-1 downto 0);

  --! @breif Holds a pre-round absolute result for each format
  type fmtPreRnd_t is array (fpFmt_t) of std_logic_vector(WIDTH(DSTENCODING)-2 downto 0);

  --! @breif Holds an input value for each format
  type intFmtValues_t is array (intFmt_t) of std_logic_vector(A_DI'range);

  -----------------------------------------------------------------------------
  -- Signal Declarations
  -----------------------------------------------------------------------------

  -- Sanitized formats (disabled formats default to first enabled one)
  signal SrcFmt_S : intFmt_t;

  -- input santitization
  signal IntFmtInputs_D : intFmtValues_t;
  signal A_D            : std_logic_vector(A_DI'range);

  -- Input Value as sign-magnitude
  signal Sign_D  : std_logic;
  signal Input_D : std_logic_vector(A_DI'range);

  -- LZC
  signal InputLeadingZeroes_S : unsigned(clog2(INTWIDTH)-1 downto 0);
  signal InputShamt_S         : natural;

  -- Internal Normalized representation
  signal InternalExp_D   : signed(EXPWIDTH-1 downto 0);  -- unbiased
  signal InputExtended_D : std_logic_vector(MANTWIDTH-1 downto 0);
  signal InternalMant_D  : std_logic_vector(InputExtended_D'range);

  -- Input classification
  signal InputZero_S : boolean;

  -- Destination shifter
  -- TODO: Actual number of required shiftout bits is MANTWIDTH minus the
  -- number of mantissa bits in the smallest FP format supported
  signal MantShamt_S    : natural;
  signal MantPreshift_D : std_logic_vector(2*MANTWIDTH-1 downto 0);
  signal ShiftedMant_D  : std_logic_vector(MantPreshift_D'range);
  signal FinalMant_D    : std_logic_vector(MANTWIDTH-1 downto 0);

  signal RoundSticky_S : std_logic_vector(1 downto 0);

  -- Result absolute value before rounding
  signal PreRndRes_D : std_logic_vector(WIDTH(DSTENCODING)-2 downto 0);

  -- Biased exponent for target format
  signal BiasedExp_D, FinalExp_D : signed(InternalExp_D'range);

  signal OFBeforeRound_S : boolean;
  signal OFAfterRound_S  : boolean;

-- roudned result
  signal ResRounded_D, ResRoundedSignCorr_D : std_logic_vector(Z_DO'range);
  signal RegularStatus_D                    : rvStatus_t;

  -- final result
  signal Result_D : std_logic_vector(Z_DO'range);
  signal Status_D : rvStatus_t;


begin  -- architecture rtl

  -----------------------------------------------------------------------------
  -- Limit available formats to active ones
  -----------------------------------------------------------------------------
  SrcFmt_S <= SrcFmt_SI when INTFORMATS.Active(SrcFmt_SI) else
              findFirstActive(INTFORMATS);

  -----------------------------------------------------------------------------
  -- Input acquisition
  -----------------------------------------------------------------------------
  -- sign extend narrower formats
  p_intInputs : process (all) is
  begin  -- process p_intInputs

    for ifmt in intFmt_t loop
      if INTFORMATS.Active(ifmt) then

        -- Sign extend the input value into the whole input vector
        IntFmtInputs_D(ifmt)(INTFORMATS.Length(ifmt)-1 downto 0)
          <= A_DI(INTFORMATS.Length(ifmt)-1 downto 0);

        if INTWIDTH > INTFORMATS.Length(ifmt) then
          IntFmtInputs_D(ifmt)(INTWIDTH-1 downto INTFORMATS.Length(ifmt))
            <= (others => A_DI(INTFORMATS.Length(ifmt)-1) and not OpMod_SI);
        end if;

      end if;
    end loop;
  end process p_intInputs;


  -- Sanitized input pattern (depends on input integer length)
  A_D <= IntFmtInputs_D(SrcFmt_S);

  -- Get the sign from the sanitized input pattern - only in signed casts
  Sign_D <= A_D(A_D'high) and not OpMod_SI;

  -- Get the input value's magnitude
  Input_D <= A_D when Sign_D = '0' else
             std_logic_vector(-signed(A_D));

  -----------------------------------------------------------------------------
  -- Normalization
  -----------------------------------------------------------------------------

  -- Use a LZC for normalization
  i_lzc : find_first_one
    generic map (
      WIDTH => INTWIDTH,
      FLIP  => 1)
    port map (
      in_i        => Input_D,
      first_one_o => InputLeadingZeroes_S,
      no_ones_o   => InputZero_S);

  -- Exponent is calculated from the leading zeroes and depends on width of int
  InternalExp_D <= (INTWIDTH - 1) - signed(resize(InputLeadingZeroes_S, EXPWIDTH));

  -- Normalization shift amount
  InputShamt_S <= to_integer(MANTWIDTH-INTWIDTH+InputLeadingZeroes_S+1);

  -- Normalize Mantissa into internal width representation, cut off implicit bit
  InputExtended_D <= std_logic_vector(resize(unsigned(Input_D), MANTWIDTH));
  InternalMant_D  <= std_logic_vector(unsigned(InputExtended_D) sll InputShamt_S);


  -----------------------------------------------------------------------------
  -- Bias and clip exponent to target format, shift mantissa into proper place
  -----------------------------------------------------------------------------
  BiasedExp_D <= InternalExp_D + BIAS(DSTENCODING);

  p_clipExponent : process (all) is
  begin  -- process p_finalAdjust

    -- Default assignments
    FinalExp_D      <= BiasedExp_D;
    OFBeforeRound_S <= false;

    -- Extend shifter space to the right of the mantissa
    MantPreshift_D <= std_logic_vector(resize(unsigned(InternalMant_D), MantPreshift_D'length) sll MANTWIDTH);

    -- Check for exponent overflow and clip
    if (BiasedExp_D >= signed("0" & MAXEXP(DSTENCODING))) then
      -- set up largest normal number, MAXEXP of superformat is still MAXEXP if
      -- clipped to shorter exponent width -> such smart
      FinalExp_D      <= resize(signed("0" & MAXEXP(DSTENCODING)), FinalExp_D'length) - 1;
      MantPreshift_D  <= (others => '1');
      OFBeforeRound_S <= true;

    -- Exponent underflow cannot happen by design.
    end if;

  end process p_clipExponent;

  -- Mantissa shift amount is only dependent on target float format
  MantShamt_S <= MANTWIDTH - DSTENCODING.ManBits;

  -- Do the acutal shift
  ShiftedMant_D <= std_logic_vector(unsigned(MantPreshift_D) srl MantShamt_S);

  -- Final mantissa before rounding
  FinalMant_D <= ShiftedMant_D(ShiftedMant_D'high downto MANTWIDTH);

  RoundSticky_S <= ShiftedMant_D(MANTWIDTH-1) & or_reduce(ShiftedMant_D(MANTWIDTH-2 downto 0));


  -- Concatenates the exponent to the right position in the final mantissa
  p_preRndAssemble : process (all) is
  begin  -- process

    -- default: fill with ones (NaN boxing)
    PreRndRes_D <= (others => '1');

    -- Assemble the preround result
    PreRndRes_D(WIDTH(DSTENCODING)-2 downto DSTENCODING.ManBits)
      <= std_logic_vector(FinalExp_D(DSTENCODING.ExpBits-1 downto 0));

    PreRndRes_D(DSTENCODING.ManBits-1 downto 0)
      <= FinalMant_D(DSTENCODING.ManBits-1 downto 0);  -- RS are behind

  end process;

  -----------------------------------------------------------------------------
  -- Rounding and Postprocessing
  -----------------------------------------------------------------------------

  -- Round the result
  i_fp_rounding : fp_rounding
    generic map (
      EXP_BITS => DSTENCODING.ExpBits,
      MAN_BITS => DSTENCODING.ManBits)
    port map (
      ResultAbs_DI     => PreRndRes_D,
      ResultSign_DI    => Sign_D,
      RoundSticky_SI   => RoundSticky_S,
      RoundMode_SI     => RoundMode_SI,
      OFBeforeRnd_SI   => false,        -- we handled this already
      ResZero_SI       => false,        -- we don't round zeroes
      EffSub_SI        => false,        -- dito
      RoundedResult_DO => ResRounded_D);

  p_fixSign : process (all) is
  begin  -- process

    ResRoundedSignCorr_D <= ResRounded_D;

    -- the rounding block injects the sign in the topmost position
    -- restore the potentially nan-boxed value by writing one
    ResRoundedSignCorr_D(ResRoundedSignCorr_D'high) <= '1';

    -- this will put it where it belongs (maybe topmost again)
    ResRoundedSignCorr_D(WIDTH(DSTENCODING)-1) <= Sign_D;

  end process;

  -- Classify final result
  OFAfterRound_S <= unsigned(ResRoundedSignCorr_D(WIDTH(DSTENCODING)-2 downto DSTENCODING.ManBits)) = unsigned'(MAXEXP(DSTENCODING));

  RegularStatus_D <= (NX     => or_reduce(RoundSticky_S),
                      NV     => to_sl(OFAfterRound_S or OFBeforeRound_S),
                      others => '0');

  -----------------------------------------------------------------------------
  -- Pipelining at outputs
  -----------------------------------------------------------------------------

  -- Select final result
  Result_D <= (others => '0') when InputZero_S else
              ResRoundedSignCorr_D;

  Status_D <= (others => '0') when InputZero_S else
              RegularStatus_D;

  i_fp_pipe : fp_pipe
    generic map (
      WIDTH     => WIDTH(DSTENCODING),
      LATENCY   => LATENCY,
      TAG_WIDTH => TAG_WIDTH)
    port map (
      Clk_CI         => Clk_CI,
      Reset_RBI      => Reset_RBI,
      Result_DI      => Result_D,
      Status_DI      => Status_D,
      Tag_DI         => Tag_DI,
      InValid_SI     => InValid_SI,
      InReady_SO     => InReady_SO,
      Flush_SI       => Flush_SI,
      ResultPiped_DO => Z_DO,
      StatusPiped_DO => Status_DO,
      TagPiped_DO    => Tag_DO,
      OutValid_SO    => OutValid_SO,
      OutReady_SI    => OutReady_SI);

  -- Always one-extend output (NaN-boxing)
  Zext_SO <= '0';

end architecture rtl;
