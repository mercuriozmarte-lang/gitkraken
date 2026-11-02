----------------------------------------------------------------------------------
-- video_clock.vhd
-- Envoltorio del IP clk_wiz_0 del proyecto AmigaW3:
--   clk_in1  = 50 MHz
--   clk_out1 = 28.375 MHz  (pixel)
--   clk_out2 = 141.875 MHz (serial TMDS, 5x)
--   locked   = PLL/MMCM locked
--
-- El IP clk_wiz_0 debe estar anadido al proyecto (Add IP / Add Sources).
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity video_clock is
    port (
        clk_in  : in  std_logic;
        clk_pix : out std_logic;
        clk_ser : out std_logic;
        locked  : out std_logic
    );
end video_clock;

architecture Behavioral of video_clock is

    signal locked_i : std_logic;

begin

    inst_clk : entity work.clk_wiz_0
        port map (
            clk_in1  => clk_in,
            clk_out1 => clk_pix,
            clk_out2 => clk_ser,
            locked   => locked_i,
            reset    => '0'
        );

    locked <= locked_i;

end Behavioral;
