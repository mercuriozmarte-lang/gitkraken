---------------------------------------------------
-- FICHERO COMPLETO: Amiga_CIA.vhd
-- VERSION: 1.5
--
-- HISTORICO DE CORRECCIONES:
--   [FIX-C1] (obsoleto, reemplazado por C6)
--   [FIX-C2] ICR clear-on-read borra los 7 bits (no solo [4:0])
--   [FIX-C3] irq_out e IR-bit usan icr_data[6:0]
--   [FIX-C4] Documentacion completa del mapa de registros
--   [FIX-C5] TOD writes implementados con stop/start atomico
--   [FIX-C6] TOD como contador binario 24-bit (no BCD) - estilo 8520
--   [FIX-C7] Read-freeze al leer TOD HI: hasta leer LO devuelve latch
--   [FIX-C8] Multi-driver de tod_counter resuelto
--   [FIX-C9] TAHI/TBHI arrancan timer en oneshot
--   [FIX-KBD] (v1.4) Captura de scancode independiente del ciclo de bus.
--             Antes solo se latchaba si el CPU leia CIA-A en el mismo
--             ciclo que kbd_valid, lo que practicamente nunca ocurria.
--   [FIX-DSK] (v1.5) CIA-A PRA toma el estado real de DF0 (dsk_status):
--             /RDY, /TRK0, /WPRO y /CHNG. Antes era un valor fijo que no
--             reproducia el sondeo de presencia de unidad de Kickstart.
---------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- =========================================================================
-- AMIGA CIA 8520 - VERSION OCS v1.4
--
-- MAPA DE REGISTROS (addr bits [11:8]):
--   x"0" PRA       - Port A data register
--   x"1" PRB       - Port B data register
--   x"2" DDRA      - Port A data direction (0=input, 1=output)
--   x"3" DDRB      - Port B data direction
--   x"4" TALO      - Timer A low byte
--   x"5" TAHI      - Timer A high byte
--   x"6" TBLO      - Timer B low byte
--   x"7" TBHI      - Timer B high byte
--   x"8" TOD LO    - TOD bits 0..7   (8520: binario, no BCD)
--   x"9" TOD MID   - TOD bits 8..15
--   x"A" TOD HI    - TOD bits 16..23
--   x"B" -         - sin uso en 8520 (devuelve 0)
--   x"C" SDR       - Serial data register (teclado)
--   x"D" ICR       - Interrupt control register
--   x"E" CRA       - Control register A (Timer A)
--   x"F" CRB       - Control register B (Timer B)
-- =========================================================================

entity Amiga_CIA is
    generic (
        -- Frecuencia del reloj del sistema (28.375 MHz en fase_12)
        CLK_HZ    : integer := 50_000_000;
        -- false: TOD a 50 Hz (VSync, CIA-A)
        -- true : TOD a 15,625 kHz (HSync, CIA-B)
        TOD_HSYNC : boolean := false
    );
    Port (
        clk         : in  STD_LOGIC;
        reset_n     : in  STD_LOGIC;

        addr        : in  STD_LOGIC_VECTOR(11 downto 0);
        data_in     : in  STD_LOGIC_VECTOR(7 downto 0);
        data_out    : out STD_LOGIC_VECTOR(7 downto 0);

        cs          : in  STD_LOGIC;
        rw          : in  STD_LOGIC;

        is_cia_a    : in  STD_LOGIC;
        irq_out     : out STD_LOGIC;

        -- Estado de la disquetera DF0 (solo se usa en CIA-A).
        -- Orden: (3)=/RDY, (2)=/TRK0, (1)=/WPRO, (0)=/CHNG.
        -- 1 = linea alta/inactiva, 0 = activa (ver modelo en phase12_top).
        dsk_status  : in  STD_LOGIC_VECTOR(3 downto 0);
        -- Salida del puerto B: en CIA-B son las lineas de control de la
        -- disquetera (/SEL0, /MTR, /STEP, /DIR...). El top las usa para
        -- calcular dsk_status.
        prb_out     : out STD_LOGIC_VECTOR(7 downto 0);

        -- Diagnostico
        dbg_tod     : out STD_LOGIC_VECTOR(7 downto 0);
        dbg_timer_running : out STD_LOGIC_VECTOR(1 downto 0);

        -- Teclado (nuevo)
        kbd_scancode : in  STD_LOGIC_VECTOR(7 downto 0);
        kbd_valid    : in  STD_LOGIC
    );
end Amiga_CIA;

architecture Behavioral of Amiga_CIA is

    -- Puertos y direccion
    signal pra  : std_logic_vector(7 downto 0) := (others => '1');
    signal prb  : std_logic_vector(7 downto 0) := (others => '1');
    signal ddra : std_logic_vector(7 downto 0) := (others => '0');
    signal ddrb : std_logic_vector(7 downto 0) := (others => '0');

    -- Registros de control
    signal cra  : std_logic_vector(7 downto 0) := (others => '0');
    signal crb  : std_logic_vector(7 downto 0) := (others => '0');

    -- Registros de interrupcion
    signal icr_mask : std_logic_vector(6 downto 0) := (others => '0');
    signal icr_data : std_logic_vector(6 downto 0) := (others => '0');

    -- Timers
    signal ta_latch   : unsigned(15 downto 0) := (others => '1');
    signal tb_latch   : unsigned(15 downto 0) := (others => '1');
    signal ta_counter : unsigned(15 downto 0) := (others => '1');
    signal tb_counter : unsigned(15 downto 0) := (others => '1');

    -- TOD del 8520: contador binario 24-bit
    signal tod_counter : unsigned(23 downto 0) := (others => '0');
    signal tod_wlatch  : unsigned(23 downto 0) := (others => '0');
    signal tod_stopped : std_logic := '0';
    signal tod_rlatch  : unsigned(23 downto 0) := (others => '0');
    signal tod_rfrozen : std_logic := '0';

    -- Generadores de tiempo base
    -- TOD: 50 Hz (VSYNC, CIA-A) o 15,625 kHz (HSYNC, CIA-B)
    function tod_max return integer is
    begin
        if TOD_HSYNC then
            return (CLK_HZ / 15625) - 1;
        else
            return (CLK_HZ / 50) - 1;
        end if;
    end function;
    constant TOD_PERIOD : integer := tod_max;
    constant E_DIV_MAX  : integer := ((CLK_HZ + 354689) / 709379) - 1;

    signal e_clock_div  : integer range 0 to E_DIV_MAX := 0;
    signal e_clock_tick : std_logic := '0';
    signal tod_div      : integer range 0 to TOD_PERIOD := 0;
    signal tod_tick     : std_logic := '0';

    -- Teclado
    signal sdr_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal kbd_flag  : std_logic := '0';
    signal rd_active : std_logic := '0';

begin

-- ==========================================================
-- [BLOQUE 3: GENERADORES DE TIEMPO BASE]
-- e_clock: 50 MHz / 70 = 714 kHz (E-clock del 68000; objetivo 709,379 kHz)
-- tod_tick: 50 Hz (VSYNC, CIA-A) o 15,625 kHz (HSYNC, CIA-B)
-- ==========================================================
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            e_clock_div  <= 0;
            e_clock_tick <= '0';
            tod_div      <= 0;
            tod_tick     <= '0';

        elsif rising_edge(clk) then
            e_clock_tick <= '0';
            if e_clock_div = E_DIV_MAX then
                e_clock_div  <= 0;
                e_clock_tick <= '1';
            else
                e_clock_div <= e_clock_div + 1;
            end if;

            tod_tick <= '0';
            if tod_div = TOD_PERIOD then
                tod_div  <= 0;
                tod_tick <= '1';
            else
                tod_div <= tod_div + 1;
            end if;
        end if;
    end process;

-- ==========================================================
-- [BLOQUE 5: TIMERS, TOD, TECLADO Y LOGICA DE REGISTROS]
-- ==========================================================
    process(clk, reset_n)
        variable ta_underflow : std_logic;
        variable tb_underflow : std_logic;
    begin
        if reset_n = '0' then
            pra         <= (others => '1');
            prb         <= (others => '1');
            ddra        <= (others => '0');
            ddrb        <= (others => '0');
            cra         <= (others => '0');
            crb         <= (others => '0');
            icr_mask    <= (others => '0');
            icr_data    <= (others => '0');
            ta_latch    <= (others => '1');
            tb_latch    <= (others => '1');
            ta_counter  <= (others => '1');
            tb_counter  <= (others => '1');
            data_out    <= (others => '1');
            tod_counter <= (others => '0');
            tod_wlatch  <= (others => '0');
            tod_rlatch  <= (others => '0');
            tod_stopped <= '0';
            tod_rfrozen <= '0';
            sdr_reg     <= (others => '0');
            kbd_flag    <= '0';

        elsif rising_edge(clk) then

            ta_underflow := '0';
            tb_underflow := '0';

            ------------------------------------------------------
            -- [FIX-KBD v1.4] Captura del scancode del teclado.
            -- Se ejecuta SIEMPRE, independientemente de cs/rw.
            -- Antes estaba anidado dentro de "if cs='1' and rw='1'"
            -- lo que hacia que el pulso de 1 ciclo de kbd_valid
            -- casi nunca coincidiera con una lectura de CIA-A.
            ------------------------------------------------------
            if kbd_valid = '1' then
                sdr_reg     <= kbd_scancode;
                kbd_flag    <= '1';
                icr_data(3) <= '1';   -- ICR bit 3 = SDR (teclado)
            end if;

            ------------------------------------------------
            -- TIMER A
            ------------------------------------------------
            if e_clock_tick = '1' then
                if cra(0) = '1' then
                    if ta_counter = 0 then
                        ta_counter   <= ta_latch;
                        ta_underflow := '1';
                        icr_data(0)  <= '1';
                        if cra(3) = '1' then
                            cra(0) <= '0';
                        end if;
                    else
                        ta_counter <= ta_counter - 1;
                    end if;
                end if;

                -- TIMER B
                if crb(0) = '1' then
                    if (crb(6 downto 5) = "00") or
                       (crb(6 downto 5) = "10" and ta_underflow = '1') then
                        if tb_counter = 0 then
                            tb_counter   <= tb_latch;
                            tb_underflow := '1';
                            icr_data(1)  <= '1';
                            if crb(3) = '1' then
                                crb(0) <= '0';
                            end if;
                        else
                            tb_counter <= tb_counter - 1;
                        end if;
                    end if;
                end if;
            end if;

            ------------------------------------------------
            -- TOD increment
            ------------------------------------------------
            if tod_tick = '1' and tod_stopped = '0' then
                tod_counter <= tod_counter + 1;
            end if;

            ------------------------------------------------
            -- BUS: lectura y escritura de registros
            ------------------------------------------------
            if cs = '1' then
                if rw = '1' then
                    -- LECTURA: se captura una sola vez por ciclo. Si no, los
                    -- registros con side-effect (ICR, TOD, SDR) se sobrescriben
                    -- en los ciclos siguientes y el CPU lee un valor erroneo.
                    if rd_active = '0' then
                        rd_active <= '1';
                        case addr(11 downto 8) is
                        when x"0" =>
                            if is_cia_a = '1' then
                                -- PRA: bits 7-6 = botones (1 = no pulsados).
                                -- Bits 5-2 = estado de DF0, calculado en el top:
                                --   bit5 /RDY  = 0 unidad lista
                                --   bit4 /TRK0 = 0 cabeza en pista 0
                                --   bit3 /WPRO = 1 sin proteccion
                                --   bit2 /CHNG = 0 disco cambiado (sin disco)
                                -- Antes se forzaba "111110": con /RDY=1 y /TRK0=1
                                -- trackdisk no veia la pista 0 ni el estado real
                                -- de una unidad vacia, y el arranque tomaba otro
                                -- camino que la referencia. Ahora se modela DF0
                                -- vacia (ver dsk_stat en phase12_top.vhd).
                                data_out <= "11" & dsk_status & pra(1 downto 0);
                            else
                                data_out <= pra;
                            end if;
                        when x"1" => data_out <= prb;
                        when x"2" => data_out <= ddra;
                        when x"3" => data_out <= ddrb;
                        when x"4" => data_out <= std_logic_vector(ta_counter(7 downto 0));
                        when x"5" => data_out <= std_logic_vector(ta_counter(15 downto 8));
                        when x"6" => data_out <= std_logic_vector(tb_counter(7 downto 0));
                        when x"7" => data_out <= std_logic_vector(tb_counter(15 downto 8));

                        when x"8" =>
                            if tod_rfrozen = '1' then
                                data_out    <= std_logic_vector(tod_rlatch(7 downto 0));
                                tod_rfrozen <= '0';
                            else
                                data_out <= std_logic_vector(tod_counter(7 downto 0));
                            end if;
                        when x"9" =>
                            if tod_rfrozen = '1' then
                                data_out <= std_logic_vector(tod_rlatch(15 downto 8));
                            else
                                data_out <= std_logic_vector(tod_counter(15 downto 8));
                            end if;
                        when x"A" =>
                            data_out    <= std_logic_vector(tod_counter(23 downto 16));
                            tod_rlatch  <= tod_counter;
                            tod_rfrozen <= '1';
                        when x"B" =>
                            data_out <= x"00";

                        when x"C" =>
                            data_out <= sdr_reg;
                            kbd_flag <= '0';

                        when x"D" =>
                            if (icr_data and icr_mask) /= "0000000" then
                                data_out <= '1' & icr_data;
                            else
                                data_out <= '0' & icr_data;
                            end if;
                            icr_data <= (others => '0');
                            if ta_underflow = '1' then icr_data(0) <= '1'; end if;
                            if tb_underflow = '1' then icr_data(1) <= '1'; end if;

                        when x"E" => data_out <= cra;
                        when x"F" => data_out <= crb;
                        when others => data_out <= x"FF";
                    end case;
                    end if;

                else
                    rd_active <= '0';
                    -- ESCRITURA
                    case addr(11 downto 8) is
                        when x"0" => pra  <= data_in;
                        when x"1" => prb  <= data_in;
                        when x"2" => ddra <= data_in;
                        when x"3" => ddrb <= data_in;

                        when x"4" =>
                            ta_latch(7 downto 0) <= unsigned(data_in);
                        when x"5" =>
                            ta_latch(15 downto 8) <= unsigned(data_in);
                            if cra(0) = '0' then
                                ta_counter(15 downto 8) <= unsigned(data_in);
                                ta_counter(7 downto 0)  <= ta_latch(7 downto 0);
                                if cra(3) = '1' then
                                    cra(0) <= '1';
                                end if;
                            end if;

                        when x"6" =>
                            tb_latch(7 downto 0) <= unsigned(data_in);
                        when x"7" =>
                            tb_latch(15 downto 8) <= unsigned(data_in);
                            if crb(0) = '0' then
                                tb_counter(15 downto 8) <= unsigned(data_in);
                                tb_counter(7 downto 0)  <= tb_latch(7 downto 0);
                                if crb(3) = '1' then
                                    crb(0) <= '1';
                                end if;
                            end if;

                        when x"8" =>
                            if crb(7) = '0' then
                                tod_wlatch(7 downto 0) <= unsigned(data_in);
                                -- Arranca la cuenta (secuencia LO, MID, HI, LO)
                                tod_stopped <= '0';
                            end if;
                        when x"9" =>
                            if crb(7) = '0' then
                                tod_wlatch(15 downto 8) <= unsigned(data_in);
                            end if;
                        when x"A" =>
                            if crb(7) = '0' then
                                tod_wlatch(23 downto 16) <= unsigned(data_in);
                                -- Carga los 24 bits ya latcheados y detiene
                                tod_counter <= unsigned(data_in) &
                                               tod_wlatch(15 downto 0);
                                tod_stopped <= '1';
                            end if;
                        when x"B" =>
                            null;

                        -- SDR: el teclado escribe 0 para liberar el buffer
                        -- (GetKey hace "sf.b $bfec01" tras leer el scancode)
                        when x"C" =>
                            sdr_reg     <= (others => '0');
                            icr_data(3) <= '0';

                        when x"D" =>
                            if data_in(7) = '1' then
                                icr_mask <= icr_mask or  data_in(6 downto 0);
                            else
                                icr_mask <= icr_mask and not data_in(6 downto 0);
                            end if;

                        when x"E" =>
                            cra <= data_in;
                            if data_in(4) = '1' then
                                ta_counter <= ta_latch;
                            end if;

                        when x"F" =>
                            crb <= data_in;
                            if data_in(4) = '1' then
                                tb_counter <= tb_latch;
                            end if;

                        when others => null;
                    end case;
                end if;

            else
                rd_active <= '0';
                data_out <= (others => '1');
            end if;

        end if;
    end process;

-- ==========================================================
-- IRQ combinacional
-- ==========================================================
    irq_out <= '1' when (icr_data and icr_mask) /= "0000000" else '0';
    dbg_tod <= std_logic_vector(tod_counter(7 downto 0));
    dbg_timer_running <= crb(0) & cra(0);
    prb_out <= prb;

end Behavioral;