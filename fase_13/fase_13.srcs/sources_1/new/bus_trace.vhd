--------------------------------------------------------------------------------
-- bus_trace.vhd
--
-- Captura los accesos del 68000 al chipset ($DFF000-$DFF1FF) y los vuelca por
-- UART en TEXTO, una linea por acceso, en el formato canonico del comparador:
--
--   pc=00FC0118 op=0000 rw=w addr=00DFF09A data=7FFF
--
-- Es auto-sincronizante (saltos de linea), se inspecciona con "head" y no
-- necesita conversor.
--
-- El volcado se repite en bucle (captura -> volcado -> captura) para no
-- depender del instante en que el PC empieza a escuchar.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity bus_trace is
    generic (
        CLK_HZ : integer := 28_375_000;
        BAUD   : integer := 1_000_000;
        DEPTH  : integer := 16384;
        CYCLES : integer := 28_000_000;       -- ~1 s de captura
        SKIP   : integer := 48_000_000;       -- ~1.7 s de espera antes
        SELFTEST : boolean := false;          -- true = graba un patron conocido
        LOADRAM  : boolean := false;          -- true = vuelca RAM en vez de capturar bus
        LOAD_BASE : integer := 16#4000#;      -- direccion de palabra inicial
        LOAD_WORDS : integer := 8192          -- palabras a volcar
    );
    port (
        clk       : in  std_logic;
        reset_n   : in  std_logic;
        addr      : in  std_logic_vector(23 downto 0);
        data_out  : in  std_logic_vector(15 downto 0);
        data_in   : in  std_logic_vector(15 downto 0);
        n_as      : in  std_logic;
        rw        : in  std_logic;
        fc        : in  std_logic_vector(2 downto 0);
        bus_state : in  integer range 0 to 3;
        tx        : out std_logic;
        active    : out std_logic;
        dbg_cnt   : out std_logic_vector(15 downto 0);
        dbg_rd    : out std_logic_vector(15 downto 0);
        dbg_state : out std_logic_vector(1 downto 0);
        ram_addr_o : out std_logic_vector(17 downto 0);
        ld_active  : out std_logic;
        ram_data_i : in  std_logic_vector(15 downto 0)
    );
end bus_trace;

architecture rtl of bus_trace is

    constant BAUD_DIV : integer := CLK_HZ / BAUD;

    type ram_t is array (0 to DEPTH - 1) of std_logic_vector(103 downto 0);
    signal ram : ram_t;
    -- Forzar el uso de Block RAM: sin esto Vivado lo mapea a RAM distribuida
    -- (LUTs) y la sintesis falla por sobreutilizacion.
    attribute ram_style : string;
    attribute ram_style of ram : signal is "block";

    type state_t is (ST_CAPTURE, ST_LOADRAM, ST_DUMP);
    signal state : state_t := ST_CAPTURE;

    signal window_cnt : integer range 0 to SKIP + CYCLES := 0;
    signal wr_idx     : integer range 0 to DEPTH := 0;
    signal rd_idx     : integer range 0 to DEPTH := 0;
    signal cck        : unsigned(31 downto 0) := (others => '0');
    signal last_pc    : std_logic_vector(23 downto 0) := (others => '0');
    signal prev_bs    : integer range 0 to 3 := 0;
    signal cur_addr   : std_logic_vector(23 downto 0) := (others => '0');
    signal cur_rw     : std_logic := '1';
    signal ld_idx     : integer range 0 to 524287 := 0;
    signal wr_en      : std_logic := '0';
    signal wr_addr    : integer range 0 to DEPTH - 1 := 0;
    signal wr_data    : std_logic_vector(103 downto 0) := (others => '0');
    signal ld_ph      : integer range 0 to 6 := 0;

    signal tx_start  : std_logic := '0';
    signal tx_byte   : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_phase  : integer range 0 to 2 := 0;
    signal chr_idx   : integer range 0 to 44 := 0;
    signal chr_max   : integer range 0 to 44 := 44;
    signal rd_lat    : integer range 0 to 2 := 0;
    signal ram_dout  : std_logic_vector(103 downto 0) := (others => '0');

    signal tx_shreg  : std_logic_vector(9 downto 0) := (others => '1');
    signal tx_busy   : std_logic := '0';
    signal baud_cnt  : integer range 0 to BAUD_DIV - 1 := 0;
    signal bit_cnt   : integer range 0 to 9 := 0;

    function hexa (n : std_logic_vector(3 downto 0)) return std_logic_vector is
        variable v : integer range 0 to 15;
    begin
        v := to_integer(unsigned(n));
        if v < 10 then
            return std_logic_vector(to_unsigned(16#30# + v, 8));
        else
            return std_logic_vector(to_unsigned(16#41# + v - 10, 8));
        end if;
    end function;

    function char_of (r : std_logic_vector(103 downto 0); i : integer)
        return std_logic_vector is
        variable pc24 : std_logic_vector(23 downto 0);
        variable a24  : std_logic_vector(23 downto 0);
        variable d16  : std_logic_vector(15 downto 0);
        variable d    : integer;
    begin
        pc24 := r(71 downto 48);
        a24  := r(47 downto 24);
        d16  := r(23 downto 8);

        if i = 0 then return x"70";        -- p
        elsif i = 1 then return x"63";     -- c
        elsif i = 2 then return x"3D";     -- =
        elsif i <= 8 then
            d := i - 3;
            return hexa(pc24(23 - 4 * d downto 20 - 4 * d));
        elsif i = 9 then return x"20";     -- espacio
        elsif i = 10 then return x"6F";    -- o
        elsif i = 11 then return x"70";    -- p
        elsif i = 12 then return x"3D";    -- =
        elsif i <= 16 then return x"30";   -- 0000
        elsif i = 17 then return x"20";    -- espacio
        elsif i = 18 then return x"72";    -- r
        elsif i = 19 then return x"77";    -- w
        elsif i = 20 then return x"3D";    -- =
        elsif i = 21 then
            if r(0) = '1' then return x"72"; else return x"77"; end if;
        elsif i = 22 then return x"20";    -- espacio
        elsif i = 23 then return x"61";    -- a
        elsif i = 24 then return x"64";    -- d
        elsif i = 25 then return x"64";    -- d
        elsif i = 26 then return x"72";    -- r
        elsif i = 27 then return x"3D";    -- =
        elsif i <= 33 then
            d := i - 28;
            return hexa(a24(23 - 4 * d downto 20 - 4 * d));
        elsif i = 34 then return x"20";    -- espacio
        elsif i = 35 then return x"64";    -- d
        elsif i = 36 then return x"61";    -- a
        elsif i = 37 then return x"74";    -- t
        elsif i = 38 then return x"61";    -- a
        elsif i = 39 then return x"3D";    -- =
        elsif i <= 43 then
            d := i - 40;
            return hexa(d16(15 - 4 * d downto 12 - 4 * d));
        else
            return x"0A";                  -- LF
        end if;
    end function;

    -- Imprime el registro completo en crudo: 26 digitos hex + LF (autoprueba)
    function raw_char (r : std_logic_vector(103 downto 0); i : integer)
        return std_logic_vector is
    begin
        if i < 26 then
            return hexa(r(103 - 4 * i downto 100 - 4 * i));
        else
            return x"0A";
        end if;
    end function;

begin

    active <= '1' when state = ST_DUMP or state = ST_LOADRAM else '0';
    chr_max <= 26 when SELFTEST else 44;
    ld_active <= '1' when state = ST_LOADRAM else '0';
    dbg_cnt   <= std_logic_vector(to_unsigned(wr_idx, 16));
    dbg_rd    <= std_logic_vector(to_unsigned(rd_idx, 16));
    dbg_state <= "00" when state = ST_CAPTURE else "01";

    process (clk, reset_n)
        variable rec : std_logic_vector(103 downto 0);
    begin
        if reset_n = '0' then
            if LOADRAM then
                state <= ST_LOADRAM;
            else
                state <= ST_CAPTURE;
            end if;
            ld_idx     <= 0;
            ld_ph      <= 0;
            wr_en      <= '0';
            window_cnt <= 0;
            wr_idx     <= 0;
            rd_idx     <= 0;
            cck        <= (others => '0');
            last_pc    <= (others => '0');
            prev_bs    <= 0;
            tx_start   <= '0';
            tx_phase   <= 0;
            chr_idx    <= 0;
            rd_lat     <= 0;
        elsif rising_edge(clk) then
            cck <= cck + 1;
            wr_en <= '0';

            if state = ST_LOADRAM then
                -- Volcado BINARIO de RAM: 2 bytes por palabra, en bucle.
                if window_cnt < SKIP then
                    window_cnt <= window_cnt + 1;
                elsif ld_ph = 0 then
                    ram_addr_o <= std_logic_vector(
                        to_unsigned(LOAD_BASE + ld_idx, 18));
                    ld_ph <= 1;
                elsif ld_ph = 1 then
                    ld_ph <= 2;
                elsif ld_ph = 2 then
                    tx_byte  <= ram_data_i(15 downto 8);
                    tx_start <= '1';
                    ld_ph    <= 3;
                elsif ld_ph = 3 then
                    tx_start <= '0';
                    if tx_busy = '1' then ld_ph <= 4; end if;
                elsif ld_ph = 4 then
                    if tx_busy = '0' then
                        tx_byte  <= ram_data_i(7 downto 0);
                        tx_start <= '1';
                        ld_ph    <= 5;
                    end if;
                elsif ld_ph = 5 then
                    tx_start <= '0';
                    if tx_busy = '1' then ld_ph <= 6; end if;
                else
                    if tx_busy = '0' then
                        if ld_idx = LOAD_WORDS - 1 then
                            ld_idx     <= 0;
                            window_cnt <= 0;      -- repetir tras la espera
                        else
                            ld_idx <= ld_idx + 1;
                        end if;
                        ld_ph <= 0;
                    end if;
                end if;

            elsif state = ST_CAPTURE then
                prev_bs <= bus_state;

                -- Direccion y sentido del acceso al EMPEZAR el ciclo: asi se
                -- emparejan con el dato del final y no se cruzan en las
                -- escrituras de varias palabras.
                if bus_state /= 0 and prev_bs = 0 then
                    cur_addr <= addr;
                    cur_rw   <= rw;
                end if;

                if window_cnt < SKIP + CYCLES then
                    window_cnt <= window_cnt + 1;
                else
                    state    <= ST_DUMP;
                    rd_idx   <= 0;
                    rd_lat   <= 0;
                    chr_idx  <= 0;
                    tx_phase <= 0;
                end if;

                if bus_state = 3 and fc = "110" then
                    last_pc <= addr;
                end if;

                if SELFTEST then
                    -- patron conocido: debe salir
                    --   pc=FC0118 op=0000 rw=w addr=DFF09A data=7FFF
                    if window_cnt < 100 and wr_idx < DEPTH then
                        wr_en   <= '1';
                        wr_addr <= wr_idx;
                        wr_data <= x"11223344" & x"FC0118" & x"DFF09A" &
                                   x"7FFF" & "0000000" & '0';
                        wr_idx <= wr_idx + 1;
                    end if;
                elsif window_cnt >= SKIP and bus_state = 3 and prev_bs /= 3 and
                      (cur_addr(23 downto 16) = x"DF" or cur_addr(23 downto 16) = x"BF" or
                       (cur_addr(23 downto 16) = x"00" and cur_rw = '0'))
                   and wr_idx < DEPTH then
                    rec := std_logic_vector(cck) & last_pc & cur_addr & data_out &
                           "0000000" & cur_rw;
                    if cur_rw = '1' then
                        rec(23 downto 8) := data_in;
                    end if;
                    wr_en   <= '1';
                    wr_addr <= wr_idx;
                    wr_data <= rec;
                    wr_idx <= wr_idx + 1;
                end if;

            elsif wr_idx /= 0 then
                case tx_phase is
                    when 0 =>
                        if rd_lat < 2 then
                            rd_lat <= rd_lat + 1;
                        else
                            if SELFTEST then
                                tx_byte <= raw_char(ram_dout, chr_idx);
                            else
                                tx_byte <= char_of(ram_dout, chr_idx);
                            end if;
                            tx_start <= '1';
                            tx_phase <= 1;
                        end if;
                    when 1 =>
                        tx_start <= '0';
                        if tx_busy = '1' then
                            tx_phase <= 2;
                        end if;
                    when others =>
                        if tx_busy = '0' then
                            tx_phase <= 0;
                            if chr_idx = chr_max then
                                chr_idx <= 0;
                                rd_lat  <= 0;
                                if rd_idx + 1 >= wr_idx then
                                    state      <= ST_CAPTURE;
                                    window_cnt <= 0;
                                    wr_idx     <= 0;
                                    rd_idx     <= 0;
                                else
                                    rd_idx <= rd_idx + 1;
                                end if;
                            else
                                chr_idx <= chr_idx + 1;
                            end if;
                        end if;
                end case;
            else
                state      <= ST_CAPTURE;
                window_cnt <= 0;
            end if;


        end if;
    end process;

    -- ------------------------------------------------------------------
    -- Buffer en Block RAM: plantilla canonica (escritura con enable y
    -- lectura registrada en el mismo proceso). Necesario para que Vivado
    -- lo mapee a BRAM y no a RAM distribuida.
    -- ------------------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            if wr_en = '1' then
                ram(wr_addr) <= wr_data;
            end if;
            ram_dout <= ram(rd_idx);
        end if;
    end process;

    process (clk, reset_n)
    begin
        if reset_n = '0' then
            tx       <= '1';
            tx_busy  <= '0';
            tx_shreg <= (others => '1');
            baud_cnt <= 0;
            bit_cnt  <= 0;
        elsif rising_edge(clk) then
            if tx_busy = '0' then
                if tx_start = '1' then
                    tx_shreg <= '1' & tx_byte & '0';
                    tx       <= '0';
                    baud_cnt <= 0;
                    bit_cnt  <= 0;
                    tx_busy  <= '1';
                end if;
            else
                if baud_cnt = BAUD_DIV - 1 then
                    baud_cnt <= 0;
                    if bit_cnt = 9 then
                        tx      <= '1';
                        tx_busy <= '0';
                    else
                        tx_shreg <= '1' & tx_shreg(9 downto 1);
                        tx       <= tx_shreg(1);
                        bit_cnt  <= bit_cnt + 1;
                    end if;
                else
                    baud_cnt <= baud_cnt + 1;
                end if;
            end if;
        end if;
    end process;

end rtl;
