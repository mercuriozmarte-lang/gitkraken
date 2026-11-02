---------------------------------------------------
-- FICHERO: video_subsystem.vhd
-- VERSION: 1.1 CORREGIDA
-- CORRECCIONES:
--   [FIX-VS1] Eliminada metastabilidad critica en deteccion
--             de flanco de pixel_clk dentro del dominio serial_clk.
--             La señal pclk_prev muestreaba pixel_clk (dominio
--             lento) directamente con serial_clk (dominio rapido)
--             sin sincronizador → fallos aleatorios en hardware.
--             Solucion: como pixel_clk y serial_clk provienen del
--             mismo MMCM con ratio exacto 5:1, se usa un contador
--             mod-5 puro en el dominio serial_clk. No hace falta
--             detectar flancos: cada 5 ciclos de serial_clk = 1
--             ciclo de pixel_clk, garantizado por el PLL.
--   [FIX-VS2] Eliminada señal pclk_prev (fuente del problema).
--   [FIX-VS3] Secuencia de serialización verificada:
--             El contador mod5 carga el nuevo dato de 10 bits
--             cuando llega a 4 (transicion 4→0). En cada ciclo
--             se envian 2 bits por DDR, completando los 10 bits
--             en exactamente 5 ciclos. Orden: LSB primero (TMDS).
--
-- REQUISITO: pixel_clk y serial_clk DEBEN provenir del mismo
--            MMCM/PLL con ratio 1:5 exacto y sin desfase.
--            Generacion recomendada en clk_wiz_0:
--              Input: 50 MHz
--              VCO: 50 × 14 = 700 MHz (MMCM)
--              Output0: 700/25 = 28 MHz  (pixel_clk)
--              Output1: 700/5  = 140 MHz (serial_clk)
---------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
library UNISIM;
use UNISIM.VComponents.all;

entity video_subsystem is
    Port (
        pixel_clk  : in  std_logic; -- 28 MHz  (1 pixel por ciclo)
        serial_clk : in  std_logic; -- 140 MHz (5x pixel_clk, TMDS serializado)
        reset_n    : in  std_logic;

        -- Entradas de video (desde Amiga/test pattern)
        red_in     : in  std_logic_vector(7 downto 0);
        green_in   : in  std_logic_vector(7 downto 0);
        blue_in    : in  std_logic_vector(7 downto 0);
        hsync_in   : in  std_logic;
        vsync_in   : in  std_logic;
        blank_in   : in  std_logic; -- '1' = blanking (no pintar)

        -- Salida HDMI diferencial
        hdmi_tx_p  : out std_logic_vector(3 downto 0);
        hdmi_tx_n  : out std_logic_vector(3 downto 0)
    );
end video_subsystem;

architecture Behavioral of video_subsystem is

    signal vde        : std_logic;
    signal tmds_r     : std_logic_vector(9 downto 0);
    signal tmds_g     : std_logic_vector(9 downto 0);
    signal tmds_b     : std_logic_vector(9 downto 0);
    signal encoder_rst: std_logic;

begin

    vde         <= not blank_in;
    encoder_rst <= not reset_n;

    -- ============================================================
    -- 1. ENCODERS TMDS (8b → 10b, dominio pixel_clk)
    --    Canal R: pC0=pC1=0 (sin syncs)
    --    Canal G: pC0=pC1=0 (sin syncs)
    --    Canal B: pC0=Hsync, pC1=Vsync (HDMI spec: syncs en azul)
    -- ============================================================
    enc_r: entity work.TMDS_Encoder
    port map(
        PixelClk    => pixel_clk,
        SerialClk   => serial_clk,
        aRst        => encoder_rst,
        pDataOutRaw => tmds_r,
        pDataOut    => red_in,
        pC0         => '0',
        pC1         => '0',
        pVde        => vde
    );

    enc_g: entity work.TMDS_Encoder
    port map(
        PixelClk    => pixel_clk,
        SerialClk   => serial_clk,
        aRst        => encoder_rst,
        pDataOutRaw => tmds_g,
        pDataOut    => green_in,
        pC0         => '0',
        pC1         => '0',
        pVde        => vde
    );

    enc_b: entity work.TMDS_Encoder
    port map(
        PixelClk    => pixel_clk,
        SerialClk   => serial_clk,
        aRst        => encoder_rst,
        pDataOutRaw => tmds_b,
        pDataOut    => blue_in,
        pC0         => hsync_in,  -- Hsync en canal azul (HDMI spec)
        pC1         => vsync_in,  -- Vsync en canal azul
        pVde        => vde
    );

    -- ============================================================
    -- 2. SERIALIZADORES DDR (dominio serial_clk)
    --    4 canales: 0=Azul, 1=Verde, 2=Rojo, 3=Reloj TMDS
    --
    --    [FIX-VS1] Contador mod-5 puro, sin deteccion de flancos
    --    de pixel_clk. Funciona porque serial_clk = 5 × pixel_clk
    --    con fase garantizada por el MMCM.
    --
    --    Secuencia de envio (LSB primero, TMDS spec):
    --      mod5=4→0: carga  tmds[9:0]
    --      mod5=0→1: envia  tmds[0] (rising), tmds[1] (falling)
    --      mod5=1→2: envia  tmds[2], tmds[3]
    --      mod5=2→3: envia  tmds[4], tmds[5]
    --      mod5=3→4: envia  tmds[6], tmds[7]
    --      mod5=4→0: envia  tmds[8], tmds[9] + carga siguiente
    -- ============================================================
    gen_channels: for i in 0 to 3 generate

        signal tmds_load : std_logic_vector(9 downto 0);
        signal shift_reg : std_logic_vector(9 downto 0) := (others => '0');
        signal mod5_cnt  : integer range 0 to 4 := 0;
        signal d1_bit    : std_logic;
        signal d2_bit    : std_logic;
        signal q_ddr     : std_logic;

    begin

        -- Seleccion de datos por canal
        tmds_load <= tmds_b     when i = 0 else  -- Canal 0: Azul  (con syncs)
                     tmds_g     when i = 1 else  -- Canal 1: Verde
                     tmds_r     when i = 2 else  -- Canal 2: Rojo
                     "1111100000";               -- Canal 3: Reloj TMDS (patron fijo)

        -- [FIX-VS1] Serializador con contador mod-5 puro
        process(serial_clk)
        begin
            if rising_edge(serial_clk) then
                if reset_n = '0' then
                    mod5_cnt <= 0;
                    shift_reg <= (others => '0');
                else
                    if mod5_cnt = 4 then
                        -- Fin de bloque de 10 bits: cargar siguiente palabra
                        mod5_cnt  <= 0;
                        shift_reg <= tmds_load;
                    else
                        -- Desplazar 2 bits a la derecha (LSB sale primero)
                        mod5_cnt  <= mod5_cnt + 1;
                        shift_reg <= "00" & shift_reg(9 downto 2);
                    end if;
                end if;
            end if;
        end process;

        -- Bits a enviar en este ciclo serial (LSB primero)
        d1_bit <= shift_reg(0); -- Enviado en flanco de subida de serial_clk
        d2_bit <= shift_reg(1); -- Enviado en flanco de bajada de serial_clk

        -- Primitiva ODDR de Xilinx: serializa 2 bits por ciclo de reloj
        ODDR_inst : ODDR
        generic map(
            DDR_CLK_EDGE => "SAME_EDGE",
            INIT         => '0',
            SRTYPE       => "ASYNC"
        )
        port map(
            Q  => q_ddr,
            C  => serial_clk,
            CE => '1',
            D1 => d1_bit,
            D2 => d2_bit,
            R  => '0',
            S  => '0'
        );

        -- Buffer diferencial de salida (par TMDS)
        OBUFDS_inst : OBUFDS
        port map(
            I  => q_ddr,
            O  => hdmi_tx_p(i),
            OB => hdmi_tx_n(i)
        );

    end generate gen_channels;

end Behavioral;
