library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity chipset_stub is
    port (
        clk          : in  std_logic;
        reset_n      : in  std_logic;
        -- Bus desde la CPU (offset $DFFxxx)
        cpu_addr     : in  std_logic_vector(11 downto 0);
        cpu_data_in  : in  std_logic_vector(15 downto 0);
        cpu_data_out : out std_logic_vector(15 downto 0);
        cpu_we       : in  std_logic;    -- pulso de escritura (1 ciclo)
        cpu_re       : in  std_logic;    -- lectura activa
        -- Niveles de interrupcion 1..6 hacia la CPU
        irq_levels   : out std_logic_vector(1 to 6)
    );
end chipset_stub;

architecture rtl of chipset_stub is

    -- Contadores de posición (timing PAL simplificado)
    constant H_MAX   : integer := 227;
    constant V_MAX   : integer := 311;
    -- PAL: 228 posiciones H x 312 lineas x 14 ciclos = 995.904 ciclos
    -- a 50 MHz -> 19.92 ms por frame (~50.2 Hz)
    constant DIV_MAX : integer := 13;

    signal h_pos   : unsigned(8 downto 0) := (others => '0');
    signal v_pos   : unsigned(8 downto 0) := (others => '0');
    signal div_cnt : integer range 0 to DIV_MAX := 0;
    signal lof     : std_logic := '0';

    -- Registros
    signal intena  : std_logic_vector(14 downto 0) := (others => '0');
    signal intreq  : std_logic_vector(14 downto 0) := (others => '0');
    signal dmaconr : std_logic_vector(15 downto 0) := (others => '0');
    signal adkconr : std_logic_vector(15 downto 0) := (others => '0');
    signal potgor  : std_logic_vector(15 downto 0) := x"FF00";

    signal write_committed : std_logic := '0';
    signal vblank_pulse    : std_logic := '0';

begin

    -- ─────────────────────────────────────────────────────
    -- Contador de posición H/V (PAL simplificado)
    -- ─────────────────────────────────────────────────────
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            h_pos   <= (others => '0');
            v_pos   <= (others => '0');
            div_cnt <= 0;
            lof     <= '0';
            vblank_pulse <= '0';
        elsif rising_edge(clk) then
            vblank_pulse <= '0';
            if div_cnt = DIV_MAX then
                div_cnt <= 0;
                if h_pos = H_MAX then
                    h_pos <= (others => '0');
                    if v_pos = V_MAX then
                        v_pos <= (others => '0');
                        lof   <= not lof;
                        vblank_pulse <= '1';   -- pulso de 1 ciclo al final del frame
                    else
                        v_pos <= v_pos + 1;
                    end if;
                else
                    h_pos <= h_pos + 1;
                end if;
            else
                div_cnt <= div_cnt + 1;
            end if;
        end if;
    end process;

    -- ─────────────────────────────────────────────────────
    -- Registros INTENA / INTREQ / VBLANK
    -- ─────────────────────────────────────────────────────
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            intena  <= (others => '0');
            intreq  <= (others => '0');
            write_committed <= '0';
        elsif rising_edge(clk) then
            -- Nuevo ciclo de bus: resetear el flag
            if cpu_we = '0' then
                write_committed <= '0';
            end if;

            -- Pulso de VBLANK: activar bit 5 de INTREQ
            if vblank_pulse = '1' then
                intreq(5) <= '1';
            end if;

            -- Escritura del CPU (una sola vez por ciclo)
            if cpu_we = '1' and write_committed = '0' then
                write_committed <= '1';
                case cpu_addr(8 downto 1) is
                    when x"4D" =>  -- INTENA ($DFF09A)
                        if cpu_data_in(15) = '1' then
                            intena <= intena or cpu_data_in(14 downto 0);
                        else
                            intena <= intena and not cpu_data_in(14 downto 0);
                        end if;
                    when x"4E" =>  -- INTREQ ($DFF09C)
                        if cpu_data_in(15) = '1' then
                            intreq <= intreq or cpu_data_in(14 downto 0);
                        else
                            intreq <= intreq and not cpu_data_in(14 downto 0);
                        end if;
                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    -- ─────────────────────────────────────────────────────
    -- Niveles de interrupcion 1..6 (mapeo INTREQ -> IPL)
    -- Agrupacion estilo Amiga; cada bit se enmascara con su INTENA
    -- y con el master (bit 14). El nivel 7 (NMI) no se genera.
    -- ─────────────────────────────────────────────────────
    irq_levels(1) <= '1' when (intena(14) = '1' and
        ((intreq(0) = '1' and intena(0) = '1') or
         (intreq(1) = '1' and intena(1) = '1') or
         (intreq(2) = '1' and intena(2) = '1'))) else '0';

    irq_levels(2) <= '1' when (intena(14) = '1' and
        ((intreq(3) = '1'  and intena(3) = '1') or
         (intreq(12) = '1' and intena(12) = '1'))) else '0';

    irq_levels(3) <= '1' when (intena(14) = '1' and
        ((intreq(4) = '1' and intena(4) = '1') or
         (intreq(5) = '1' and intena(5) = '1') or
         (intreq(6) = '1' and intena(6) = '1'))) else '0';

    irq_levels(4) <= '1' when (intena(14) = '1' and
        ((intreq(7) = '1' and intena(7) = '1') or
         (intreq(8) = '1' and intena(8) = '1') or
         (intreq(9) = '1' and intena(9) = '1') or
         (intreq(10) = '1' and intena(10) = '1'))) else '0';

    irq_levels(5) <= '1' when (intena(14) = '1' and
        intreq(11) = '1' and intena(11) = '1') else '0';

    irq_levels(6) <= '1' when (intena(14) = '1' and
        intreq(13) = '1' and intena(13) = '1') else '0';

    -- ─────────────────────────────────────────────────────
    -- Lectura de registros
    -- ─────────────────────────────────────────────────────
    process(cpu_addr, cpu_re, h_pos, v_pos, lof, intena, intreq, dmaconr, adkconr, potgor)
    begin
        cpu_data_out <= (others => '0');
        if cpu_re = '1' then
            case cpu_addr(8 downto 1) is
                when x"01" =>  -- DMACONR ($DFF002)
                    cpu_data_out <= dmaconr;
                when x"02" =>  -- VPOSR ($DFF004)
                    cpu_data_out <= lof & "000000" &
                                    std_logic(v_pos(8)) &
                                    std_logic_vector(v_pos(7 downto 0));
                when x"03" =>  -- VHPOSR ($DFF006)
                    cpu_data_out <= std_logic_vector(v_pos(7 downto 0)) &
                                    std_logic_vector(h_pos(8 downto 1));
                when x"08" =>  -- ADKCONR ($DFF010)
                    cpu_data_out <= adkconr;
                when x"0B" =>  -- POTGOR ($DFF016)
                    cpu_data_out <= potgor;
                when x"0E" =>  -- INTENAR ($DFF01C)
                    cpu_data_out <= "0" & intena;
                when x"0F" =>  -- INTREQR ($DFF01E)
                    cpu_data_out <= "0" & intreq;
                when others =>
                    cpu_data_out <= (others => '0');
            end case;
        end if;
    end process;

end rtl;