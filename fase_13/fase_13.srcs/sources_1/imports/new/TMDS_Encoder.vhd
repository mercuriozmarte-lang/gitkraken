---------------------------------------------------
-- FICHERO: TMDS_Encoder.vhd
-- VERSION: 1.1 CORREGIDA
-- CORRECCIONES:
--   [FIX-T1] aRst añadido a los tres procesos registrados.
--            Antes estaba declarado en la entidad pero nunca
--            se usaba, dejando cnt_t_3 y el pipeline sin reset.
--   [FIX-T2] SerialClk mantenido en entidad por compatibilidad
--            pero no se usa internamente (la serialización DDR
--            se realiza en video_subsystem con ODDR).
---------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.DVI_Constants.ALL;

entity TMDS_Encoder is
    Port (
        PixelClk    : in  std_logic;
        SerialClk   : in  std_logic; -- No usado internamente
        aRst        : in  std_logic; -- Reset asincrono activo alto
        pDataOutRaw : out std_logic_vector(9 downto 0);
        pDataOut    : in  std_logic_vector(7 downto 0);
        pC0         : in  std_logic;
        pC1         : in  std_logic;
        pVde        : in  std_logic
    );
end TMDS_Encoder;

architecture Behavioral of TMDS_Encoder is

    signal pDataOut_1                        : std_logic_vector(7 downto 0);
    signal q_m_1, q_m_xor_1, q_m_xnor_1, q_m_2 : std_logic_vector(8 downto 0);
    signal control_token_2, q_out_2          : std_logic_vector(9 downto 0);
    signal n1d_1, n1q_m_2, n0q_m_2, n1q_m_1 : unsigned(3 downto 0);
    signal dc_bias_2, cnt_t_3, cnt_t_2       : signed(4 downto 0) := "00000";
    signal pC0_1, pC1_1, pVde_1              : std_logic;
    signal pC0_2, pC1_2, pVde_2              : std_logic;
    signal cond_not_balanced_2, cond_balanced_2 : std_logic;

    function sum_bits(u : std_logic_vector) return unsigned is
        variable sum : unsigned(3 downto 0) := "0000";
    begin
        for i in u'range loop
            if u(i) = '1' then sum := sum + 1; end if;
        end loop;
        return sum;
    end sum_bits;

begin

    -- ========================================================
    -- ETAPA 1: Registro de entrada
    -- [FIX-T1] Reset asincrono añadido
    -- ========================================================
    process(PixelClk, aRst)
    begin
        if aRst = '1' then
            pVde_1     <= '0';
            n1d_1      <= (others => '0');
            pDataOut_1 <= (others => '0');
            pC0_1      <= '0';
            pC1_1      <= '0';
        elsif rising_edge(PixelClk) then
            pVde_1     <= pVde;
            n1d_1      <= sum_bits(pDataOut);
            pDataOut_1 <= pDataOut;
            pC0_1      <= pC0;
            pC1_1      <= pC1;
        end if;
    end process;

    -- ========================================================
    -- CODIFICACION XOR/XNOR (combinacional)
    -- ========================================================
    q_m_xor_1(0) <= pDataOut_1(0);
    gen_xor: for i in 1 to 7 generate
        q_m_xor_1(i) <= q_m_xor_1(i-1) xor pDataOut_1(i);
    end generate;
    q_m_xor_1(8) <= '1';

    q_m_xnor_1(0) <= pDataOut_1(0);
    gen_xnor: for i in 1 to 7 generate
        q_m_xnor_1(i) <= q_m_xnor_1(i-1) xnor pDataOut_1(i);
    end generate;
    q_m_xnor_1(8) <= '0';

    q_m_1   <= q_m_xnor_1 when (n1d_1 > 4) or (n1d_1 = 4 and pDataOut_1(0) = '0')
                           else q_m_xor_1;
    n1q_m_1 <= sum_bits(q_m_1(7 downto 0));

    -- ========================================================
    -- ETAPA 2: Pipeline de balance DC
    -- [FIX-T1] Reset asincrono añadido
    -- ========================================================
    process(PixelClk, aRst)
    begin
        if aRst = '1' then
            n1q_m_2 <= (others => '0');
            n0q_m_2 <= (others => '0');
            q_m_2   <= (others => '0');
            pC0_2   <= '0';
            pC1_2   <= '0';
            pVde_2  <= '0';
        elsif rising_edge(PixelClk) then
            n1q_m_2 <= n1q_m_1;
            n0q_m_2 <= 8 - n1q_m_1;
            q_m_2   <= q_m_1;
            pC0_2   <= pC0_1;
            pC1_2   <= pC1_1;
            pVde_2  <= pVde_1;
        end if;
    end process;

    cond_balanced_2     <= '1' when (cnt_t_3 = 0) or (n1q_m_2 = 4) else '0';
    cond_not_balanced_2 <= '1' when (cnt_t_3 > 0 and n1q_m_2 > 4) or
                                    (cnt_t_3 < 0 and n1q_m_2 < 4)
                           else '0';

    -- Tokens de control: syncs van en canal Azul (pC0=Hsync, pC1=Vsync)
    control_token_2 <= kCtlTkn0 when pC1_2 = '0' and pC0_2 = '0' else
                       kCtlTkn1 when pC1_2 = '0' and pC0_2 = '1' else
                       kCtlTkn2 when pC1_2 = '1' and pC0_2 = '0' else
                       kCtlTkn3;

    -- ========================================================
    -- LOGICA DE SALIDA TMDS 10 bits (combinacional)
    -- ========================================================
    process(pVde_2, control_token_2, q_m_2, cond_balanced_2, cond_not_balanced_2)
    begin
        if pVde_2 = '0' then
            q_out_2 <= control_token_2;
        elsif cond_balanced_2 = '1' then
            q_out_2(9) <= not q_m_2(8);
            q_out_2(8) <= q_m_2(8);
            if q_m_2(8) = '0' then
                q_out_2(7 downto 0) <= not q_m_2(7 downto 0);
            else
                q_out_2(7 downto 0) <= q_m_2(7 downto 0);
            end if;
        elsif cond_not_balanced_2 = '1' then
            q_out_2(9)          <= '1';
            q_out_2(8)          <= q_m_2(8);
            q_out_2(7 downto 0) <= not q_m_2(7 downto 0);
        else
            q_out_2(9)          <= '0';
            q_out_2(8)          <= q_m_2(8);
            q_out_2(7 downto 0) <= q_m_2(7 downto 0);
        end if;
    end process;

    dc_bias_2 <= signed('0' & n0q_m_2) - signed('0' & n1q_m_2);

    -- ========================================================
    -- CALCULO DEL NUEVO CONTADOR DE BIAS DC (combinacional)
    -- ========================================================
    process(pVde_2, cond_balanced_2, q_m_2, cnt_t_3, dc_bias_2, cond_not_balanced_2)
    begin
        if pVde_2 = '0' then
            cnt_t_2 <= to_signed(0, 5);
        elsif cond_balanced_2 = '1' then
            if q_m_2(8) = '0' then
                cnt_t_2 <= cnt_t_3 + dc_bias_2;
            else
                cnt_t_2 <= cnt_t_3 - dc_bias_2;
            end if;
        elsif cond_not_balanced_2 = '1' then
            if q_m_2(8) = '1' then
                cnt_t_2 <= cnt_t_3 + 2 + dc_bias_2;
            else
                cnt_t_2 <= cnt_t_3 + dc_bias_2;
            end if;
        else
            if q_m_2(8) = '0' then
                cnt_t_2 <= cnt_t_3 - 2 - dc_bias_2;
            else
                cnt_t_2 <= cnt_t_3 - dc_bias_2;
            end if;
        end if;
    end process;

    -- ========================================================
    -- ETAPA 3: Registro de salida final
    -- [FIX-T1] Reset asincrono añadido
    -- ========================================================
    process(PixelClk, aRst)
    begin
        if aRst = '1' then
            cnt_t_3     <= (others => '0');
            pDataOutRaw <= (others => '0');
        elsif rising_edge(PixelClk) then
            cnt_t_3     <= cnt_t_2;
            pDataOutRaw <= q_out_2;
        end if;
    end process;

end Behavioral;---------------------------------------------------
-- FICHERO: TMDS_Encoder.vhd
-- VERSION: 1.1 CORREGIDA
-- CORRECCIONES:
--   [FIX-T1] aRst añadido a los tres procesos registrados.
--            Antes estaba declarado en la entidad pero nunca
--            se usaba, dejando cnt_t_3 y el pipeline sin reset.
--   [FIX-T2] SerialClk mantenido en entidad por compatibilidad
--            pero no se usa internamente (la serialización DDR
--            se realiza en video_subsystem con ODDR).
---------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.DVI_Constants.ALL;

entity TMDS_Encoder is
    Port (
        PixelClk    : in  std_logic;
        SerialClk   : in  std_logic; -- No usado internamente
        aRst        : in  std_logic; -- Reset asincrono activo alto
        pDataOutRaw : out std_logic_vector(9 downto 0);
        pDataOut    : in  std_logic_vector(7 downto 0);
        pC0         : in  std_logic;
        pC1         : in  std_logic;
        pVde        : in  std_logic
    );
end TMDS_Encoder;

architecture Behavioral of TMDS_Encoder is

    signal pDataOut_1                        : std_logic_vector(7 downto 0);
    signal q_m_1, q_m_xor_1, q_m_xnor_1, q_m_2 : std_logic_vector(8 downto 0);
    signal control_token_2, q_out_2          : std_logic_vector(9 downto 0);
    signal n1d_1, n1q_m_2, n0q_m_2, n1q_m_1 : unsigned(3 downto 0);
    signal dc_bias_2, cnt_t_3, cnt_t_2       : signed(4 downto 0) := "00000";
    signal pC0_1, pC1_1, pVde_1              : std_logic;
    signal pC0_2, pC1_2, pVde_2              : std_logic;
    signal cond_not_balanced_2, cond_balanced_2 : std_logic;

    function sum_bits(u : std_logic_vector) return unsigned is
        variable sum : unsigned(3 downto 0) := "0000";
    begin
        for i in u'range loop
            if u(i) = '1' then sum := sum + 1; end if;
        end loop;
        return sum;
    end sum_bits;

begin

    -- ========================================================
    -- ETAPA 1: Registro de entrada
    -- [FIX-T1] Reset asincrono añadido
    -- ========================================================
    process(PixelClk, aRst)
    begin
        if aRst = '1' then
            pVde_1     <= '0';
            n1d_1      <= (others => '0');
            pDataOut_1 <= (others => '0');
            pC0_1      <= '0';
            pC1_1      <= '0';
        elsif rising_edge(PixelClk) then
            pVde_1     <= pVde;
            n1d_1      <= sum_bits(pDataOut);
            pDataOut_1 <= pDataOut;
            pC0_1      <= pC0;
            pC1_1      <= pC1;
        end if;
    end process;

    -- ========================================================
    -- CODIFICACION XOR/XNOR (combinacional)
    -- ========================================================
    q_m_xor_1(0) <= pDataOut_1(0);
    gen_xor: for i in 1 to 7 generate
        q_m_xor_1(i) <= q_m_xor_1(i-1) xor pDataOut_1(i);
    end generate;
    q_m_xor_1(8) <= '1';

    q_m_xnor_1(0) <= pDataOut_1(0);
    gen_xnor: for i in 1 to 7 generate
        q_m_xnor_1(i) <= q_m_xnor_1(i-1) xnor pDataOut_1(i);
    end generate;
    q_m_xnor_1(8) <= '0';

    q_m_1   <= q_m_xnor_1 when (n1d_1 > 4) or (n1d_1 = 4 and pDataOut_1(0) = '0')
                           else q_m_xor_1;
    n1q_m_1 <= sum_bits(q_m_1(7 downto 0));

    -- ========================================================
    -- ETAPA 2: Pipeline de balance DC
    -- [FIX-T1] Reset asincrono añadido
    -- ========================================================
    process(PixelClk, aRst)
    begin
        if aRst = '1' then
            n1q_m_2 <= (others => '0');
            n0q_m_2 <= (others => '0');
            q_m_2   <= (others => '0');
            pC0_2   <= '0';
            pC1_2   <= '0';
            pVde_2  <= '0';
        elsif rising_edge(PixelClk) then
            n1q_m_2 <= n1q_m_1;
            n0q_m_2 <= 8 - n1q_m_1;
            q_m_2   <= q_m_1;
            pC0_2   <= pC0_1;
            pC1_2   <= pC1_1;
            pVde_2  <= pVde_1;
        end if;
    end process;

    cond_balanced_2     <= '1' when (cnt_t_3 = 0) or (n1q_m_2 = 4) else '0';
    cond_not_balanced_2 <= '1' when (cnt_t_3 > 0 and n1q_m_2 > 4) or
                                    (cnt_t_3 < 0 and n1q_m_2 < 4)
                           else '0';

    -- Tokens de control: syncs van en canal Azul (pC0=Hsync, pC1=Vsync)
    control_token_2 <= kCtlTkn0 when pC1_2 = '0' and pC0_2 = '0' else
                       kCtlTkn1 when pC1_2 = '0' and pC0_2 = '1' else
                       kCtlTkn2 when pC1_2 = '1' and pC0_2 = '0' else
                       kCtlTkn3;

    -- ========================================================
    -- LOGICA DE SALIDA TMDS 10 bits (combinacional)
    -- ========================================================
    process(pVde_2, control_token_2, q_m_2, cond_balanced_2, cond_not_balanced_2)
    begin
        if pVde_2 = '0' then
            q_out_2 <= control_token_2;
        elsif cond_balanced_2 = '1' then
            q_out_2(9) <= not q_m_2(8);
            q_out_2(8) <= q_m_2(8);
            if q_m_2(8) = '0' then
                q_out_2(7 downto 0) <= not q_m_2(7 downto 0);
            else
                q_out_2(7 downto 0) <= q_m_2(7 downto 0);
            end if;
        elsif cond_not_balanced_2 = '1' then
            q_out_2(9)          <= '1';
            q_out_2(8)          <= q_m_2(8);
            q_out_2(7 downto 0) <= not q_m_2(7 downto 0);
        else
            q_out_2(9)          <= '0';
            q_out_2(8)          <= q_m_2(8);
            q_out_2(7 downto 0) <= q_m_2(7 downto 0);
        end if;
    end process;

    dc_bias_2 <= signed('0' & n0q_m_2) - signed('0' & n1q_m_2);

    -- ========================================================
    -- CALCULO DEL NUEVO CONTADOR DE BIAS DC (combinacional)
    -- ========================================================
    process(pVde_2, cond_balanced_2, q_m_2, cnt_t_3, dc_bias_2, cond_not_balanced_2)
    begin
        if pVde_2 = '0' then
            cnt_t_2 <= to_signed(0, 5);
        elsif cond_balanced_2 = '1' then
            if q_m_2(8) = '0' then
                cnt_t_2 <= cnt_t_3 + dc_bias_2;
            else
                cnt_t_2 <= cnt_t_3 - dc_bias_2;
            end if;
        elsif cond_not_balanced_2 = '1' then
            if q_m_2(8) = '1' then
                cnt_t_2 <= cnt_t_3 + 2 + dc_bias_2;
            else
                cnt_t_2 <= cnt_t_3 + dc_bias_2;
            end if;
        else
            if q_m_2(8) = '0' then
                cnt_t_2 <= cnt_t_3 - 2 - dc_bias_2;
            else
                cnt_t_2 <= cnt_t_3 - dc_bias_2;
            end if;
        end if;
    end process;

    -- ========================================================
    -- ETAPA 3: Registro de salida final
    -- [FIX-T1] Reset asincrono añadido
    -- ========================================================
    process(PixelClk, aRst)
    begin
        if aRst = '1' then
            cnt_t_3     <= (others => '0');
            pDataOutRaw <= (others => '0');
        elsif rising_edge(PixelClk) then
            cnt_t_3     <= cnt_t_2;
            pDataOutRaw <= q_out_2;
        end if;
    end process;

end Behavioral;